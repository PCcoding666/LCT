using System.Globalization;
using System.Text;
using LCT.Core.Models;

namespace LCT.Core.Session;

public enum ExportFormat
{
    Markdown,
    PlainText,
    Srt,
}

public static class ExportFormatExtensions
{
    public static string FileExtension(this ExportFormat format) => format switch
    {
        ExportFormat.Markdown => "md",
        ExportFormat.PlainText => "txt",
        ExportFormat.Srt => "srt",
        _ => "txt",
    };

    public static string FilterName(this ExportFormat format) => format switch
    {
        ExportFormat.Markdown => "Markdown (*.md)|*.md",
        ExportFormat.PlainText => "Text (*.txt)|*.txt",
        ExportFormat.Srt => "SubRip subtitles (*.srt)|*.srt",
        _ => "All files (*.*)|*.*",
    };
}

/// <summary>
/// Renders a SessionTranscript into an exportable document. Pure functions;
/// wall-clock dates are formatted in an injected time zone so tests produce
/// identical strings on any machine.
/// </summary>
public static class SessionExporter
{
    public static string Export(SessionTranscript transcript, ExportFormat format, string sourceLanguages, string targetLanguage, TimeZoneInfo? timeZone = null)
    {
        timeZone ??= TimeZoneInfo.Local;
        return format switch
        {
            ExportFormat.Markdown => Markdown(transcript, sourceLanguages, targetLanguage, timeZone),
            ExportFormat.PlainText => PlainText(transcript, sourceLanguages, targetLanguage, timeZone),
            ExportFormat.Srt => Srt(transcript),
            _ => "",
        };
    }

    /// <summary>Default save name, e.g. "LCT Session 2026-10-11 14.03.md".</summary>
    public static string SuggestedFileName(ExportFormat format, DateTime sessionStart, TimeZoneInfo? timeZone = null)
    {
        var local = ToZone(sessionStart, timeZone ?? TimeZoneInfo.Local);
        return $"LCT Session {local.ToString("yyyy-MM-dd HH.mm", CultureInfo.InvariantCulture)}.{format.FileExtension()}";
    }

    private static string Markdown(SessionTranscript transcript, string sourceLanguages, string targetLanguage, TimeZoneInfo timeZone)
    {
        var sessionStart = SessionStart(transcript);
        var titleDate = sessionStart.HasValue ? $" — {HeaderDate(sessionStart.Value, timeZone)}" : "";
        var lines = new List<string>
        {
            $"# LCT Session{titleDate}",
            "",
            $"- Duration: {Clock(Duration(transcript, sessionStart))}",
            $"- Languages: {sourceLanguages} → {targetLanguage}",
            $"- Lines: {transcript.Entries.Count}",
        };
        if (sessionStart.HasValue && transcript.Entries.Count > 0)
        {
            foreach (var entry in transcript.Entries)
            {
                lines.Add("");
                lines.Add($"**[{Clock(Offset(entry, sessionStart.Value))}] {entry.Source.Label()}** {MarkdownEscape(SingleLine(entry.SourceText))}");
                var translation = SingleLine(entry.TranslatedText);
                if (translation.Length > 0)
                {
                    lines.Add($"> {MarkdownEscape(translation)}");
                }
            }
        }
        return string.Join("\n", lines) + "\n";
    }

    private static string MarkdownEscape(string text)
        => text.Length > 0 && "#>-*+".Contains(text[0]) ? "\\" + text : text;

    private static string PlainText(SessionTranscript transcript, string sourceLanguages, string targetLanguage, TimeZoneInfo timeZone)
    {
        var sessionStart = SessionStart(transcript);
        var titleDate = sessionStart.HasValue ? $" — {HeaderDate(sessionStart.Value, timeZone)}" : "";
        var lines = new List<string> { $"LCT Session{titleDate} ({sourceLanguages} → {targetLanguage})" };
        if (sessionStart.HasValue)
        {
            foreach (var entry in transcript.Entries)
            {
                lines.Add("");
                var prefix = $"[{Clock(Offset(entry, sessionStart.Value))}] [{entry.Source.Label()}] ";
                lines.Add(prefix + SingleLine(entry.SourceText));
                var translation = SingleLine(entry.TranslatedText);
                if (translation.Length > 0)
                {
                    lines.Add(new string(' ', prefix.Length) + translation);
                }
            }
        }
        return string.Join("\n", lines) + "\n";
    }

    private static string Srt(SessionTranscript transcript)
    {
        var sessionStart = SessionStart(transcript);
        if (!sessionStart.HasValue)
        {
            return "";
        }
        // Only the finalization time is known, so a cue ends there and starts an
        // estimated display duration earlier, never overlapping the previous cue
        // on the same channel. Channels may overlap each other.
        var cues = new List<(double Start, double End, int Index, string Text)>();
        var lastEndBySource = new Dictionary<AudioSource, double>();
        for (var index = 0; index < transcript.Entries.Count; index++)
        {
            var entry = transcript.Entries[index];
            var end = Offset(entry, sessionStart.Value);
            var estimated = Math.Min(Math.Max(entry.SourceText.Length * 0.07, 1.0), 7.0);
            lastEndBySource.TryGetValue(entry.Source, out var lastEnd);
            var start = Math.Max(Math.Max(end - estimated, lastEnd), 0);
            if (start >= end)
            {
                end = start + 0.5;
            }
            lastEndBySource[entry.Source] = end;
            var text = SingleLine(entry.SourceText);
            var translation = SingleLine(entry.TranslatedText);
            if (translation.Length > 0)
            {
                text += "\n" + translation;
            }
            cues.Add((start, end, index, text));
        }
        cues.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.Index.CompareTo(b.Index));

        var sb = new StringBuilder();
        for (var i = 0; i < cues.Count; i++)
        {
            if (i > 0)
            {
                sb.Append("\n\n");
            }
            sb.Append(i + 1).Append('\n').Append(SrtTimestamp(cues[i].Start)).Append(" --> ").Append(SrtTimestamp(cues[i].End)).Append('\n').Append(cues[i].Text);
        }
        return cues.Count == 0 ? "" : sb.Append('\n').ToString();
    }

    private static DateTime? SessionStart(SessionTranscript transcript)
        => transcript.StartedAt ?? (transcript.Entries.Count > 0 ? transcript.Entries[0].FinalizedAt : null);

    private static double Duration(SessionTranscript transcript, DateTime? sessionStart)
        => sessionStart.HasValue && transcript.Entries.Count > 0 ? Math.Max(0, (transcript.Entries[^1].FinalizedAt - sessionStart.Value).TotalSeconds) : 0;

    private static double Offset(SessionTranscript.Entry entry, DateTime sessionStart)
        => Math.Max(0, (entry.FinalizedAt - sessionStart).TotalSeconds);

    private static DateTime ToZone(DateTime date, TimeZoneInfo timeZone)
    {
        var utc = date.Kind == DateTimeKind.Utc ? date : date.ToUniversalTime();
        return TimeZoneInfo.ConvertTimeFromUtc(utc, timeZone);
    }

    private static string HeaderDate(DateTime date, TimeZoneInfo timeZone)
        => ToZone(date, timeZone).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);

    /// <summary>"HH:MM:SS" for whole-second offsets.</summary>
    public static string Clock(double seconds)
    {
        var total = Math.Max(0, (int)seconds);
        return $"{total / 3600:00}:{total % 3600 / 60:00}:{total % 60:00}";
    }

    /// <summary>"HH:MM:SS,mmm" per the SRT spec.</summary>
    public static string SrtTimestamp(double seconds)
    {
        var totalMs = Math.Max(0, (long)Math.Round(seconds * 1000));
        var ms = totalMs % 1000;
        var totalSeconds = totalMs / 1000;
        return $"{totalSeconds / 3600:00}:{totalSeconds / 60 % 60:00}:{totalSeconds % 60:00},{ms:000}";
    }

    private static string SingleLine(string text) => text.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ');
}
