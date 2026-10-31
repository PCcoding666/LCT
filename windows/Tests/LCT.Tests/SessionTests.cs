using LCT.Core.History;
using LCT.Core.Models;
using LCT.Core.Session;
using Xunit;

namespace LCT.Tests;

public class TextUtilsTests
{
    [Fact]
    public void testCjkDetection()
    {
        Assert.True(TextUtils.IsCjk('中'));
        Assert.True(TextUtils.IsCjk('カ'));
        Assert.True(TextUtils.IsCjk('한'));
        Assert.False(TextUtils.IsCjk('a'));
        Assert.True(TextUtils.IsPrimarilyCjk("你好世界 wo"));
        Assert.False(TextUtils.IsPrimarilyCjk("hello 你"));
    }

    [Fact]
    public void testEndPunctuationAndConcatenation()
    {
        Assert.Equal("Hello.", TextUtils.EnsureEndPunctuation("Hello"));
        Assert.Equal("你好。", TextUtils.EnsureEndPunctuation("你好"));
        Assert.Equal("Hello.", TextUtils.EnsureEndPunctuation("Hello."));
        Assert.Equal("One. Two", TextUtils.ConcatenateSentences(new[] { "One", "Two" }));
        Assert.Equal("One. Two", TextUtils.ConcatenateSentences(new[] { "One.", "Two" }));
        Assert.Equal("一。二", TextUtils.ConcatenateSentences(new[] { "一", "二" }));
        Assert.Equal("一。二", TextUtils.ConcatenateSentences(new[] { "一。", "二" }));
    }

    [Fact]
    public void testCleanTranslationOutput()
    {
        Assert.Equal("Hola", TextUtils.CleanTranslationOutput("Translation: 🔤Hola🔤 "));
        Assert.Equal("你好", TextUtils.CleanTranslationOutput("译文：你好"));
    }

    [Fact]
    public void testStripNonSpeechMarkers()
    {
        Assert.Equal("", TextUtils.StripNonSpeechMarkers("[BLANK_AUDIO]"));
        Assert.Equal("Hello there", TextUtils.StripNonSpeechMarkers(" Hello (music) there ♪♪"));
        Assert.False(TextUtils.HasSpeechContent("..."));
        Assert.True(TextUtils.HasSpeechContent("ok."));
    }
}

public class LanguageLabelTests
{
    [Fact]
    public void testFormat()
    {
        Assert.Equal("ZH → EN", LanguageLabel.Format(SourceLanguage.Chinese, null, TargetLanguage.English, true));
        Assert.Equal("ZH → EN", LanguageLabel.Format(SourceLanguage.Chinese, SourceLanguage.ChineseTW, TargetLanguage.English, true));
        Assert.Equal("SYS ZH · MIC EN → JA", LanguageLabel.Format(SourceLanguage.Chinese, SourceLanguage.English, TargetLanguage.Japanese, true));
        Assert.Equal("ZH → JA", LanguageLabel.Format(SourceLanguage.Chinese, SourceLanguage.English, TargetLanguage.Japanese, false));
        Assert.Equal("// listening (SYS ZH · MIC EN)…", LanguageLabel.Listening(SourceLanguage.Chinese, SourceLanguage.English, true));
        Assert.Equal("// listening (ZH)…", LanguageLabel.Listening(SourceLanguage.Chinese, null, true));
    }

    [Fact]
    public void testElapsed()
    {
        Assert.Equal("01:05", LanguageLabel.Elapsed(TimeSpan.FromSeconds(65)));
        Assert.Equal("01:00:00", LanguageLabel.Elapsed(TimeSpan.FromHours(1)));
    }
}

public class SessionExporterTests
{
    private static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;

    private static SessionTranscript Sample()
    {
        var start = new DateTime(2026, 10, 11, 14, 3, 0, DateTimeKind.Utc);
        var t = new SessionTranscript();
        t.Begin(start);
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        t.Append(a, AudioSource.System, "Hello there.", start.AddSeconds(3));
        t.UpdateTranslation(a, "你好。");
        t.Append(b, AudioSource.Microphone, "# not a heading\nsecond line", start.AddSeconds(65));
        return t;
    }

    [Fact]
    public void testMarkdown()
    {
        var md = SessionExporter.Export(Sample(), ExportFormat.Markdown, "EN", "ZH", Utc);
        var expected = string.Join("\n", new[]
        {
            "# LCT Session — 2026-10-11 14:03",
            "",
            "- Duration: 00:01:05",
            "- Languages: EN → ZH",
            "- Lines: 2",
            "",
            "**[00:00:03] SYS** Hello there.",
            "> 你好。",
            "",
            "**[00:01:05] MIC** \\# not a heading second line",
            "",
        });
        Assert.Equal(expected, md);
    }

    [Fact]
    public void testPlainText()
    {
        var txt = SessionExporter.Export(Sample(), ExportFormat.PlainText, "EN", "ZH", Utc);
        Assert.StartsWith("LCT Session — 2026-10-11 14:03 (EN → ZH)\n\n[00:00:03] [SYS] Hello there.\n                 你好。\n", txt);
    }

    [Fact]
    public void testSrt()
    {
        var srt = SessionExporter.Export(Sample(), ExportFormat.Srt, "EN", "ZH", Utc);
        var expected = "1\n00:00:02,000 --> 00:00:03,000\nHello there.\n你好。\n\n2\n00:01:03,110 --> 00:01:05,000\n# not a heading second line\n";
        Assert.Equal(expected, srt);
    }

    [Fact]
    public void testEmptyTranscript()
    {
        var t = new SessionTranscript();
        Assert.Equal("", SessionExporter.Export(t, ExportFormat.Srt, "EN", "ZH", Utc));
        Assert.Equal("# LCT Session\n\n- Duration: 00:00:00\n- Languages: EN → ZH\n- Lines: 0\n", SessionExporter.Export(t, ExportFormat.Markdown, "EN", "ZH", Utc));
    }

    [Fact]
    public void testSuggestedFileName()
    {
        Assert.Equal("LCT Session 2026-10-11 14.03.srt", SessionExporter.SuggestedFileName(ExportFormat.Srt, new DateTime(2026, 10, 11, 14, 3, 0, DateTimeKind.Utc), Utc));
    }

    [Fact]
    public void testTranscript_RemoveAndClear()
    {
        var t = Sample();
        var id = t.Entries[0].Id;
        t.Remove(new[] { id });
        Assert.Single(t.Entries);
        t.Clear();
        Assert.Null(t.StartedAt);
        Assert.Empty(t.Entries);
    }
}

public class DetectorTests
{
    [Fact]
    public void testStallDetector_FiresOncePerLaneAfterAudibleTime()
    {
        var d = new RecognitionStallDetector(0.25f, TimeSpan.FromSeconds(2));
        var t0 = DateTime.UtcNow;
        Assert.False(d.Process(0.5f, AudioSource.System, t0));
        Assert.False(d.Process(0.5f, AudioSource.System, t0.AddSeconds(1)));
        Assert.True(d.Process(0.5f, AudioSource.System, t0.AddSeconds(2)));
        Assert.False(d.Process(0.5f, AudioSource.System, t0.AddSeconds(3)));
        // Other lane independent
        Assert.False(d.Process(0.5f, AudioSource.Microphone, t0.AddSeconds(3)));
        // Quiet time does not count
        var d2 = new RecognitionStallDetector(0.25f, TimeSpan.FromSeconds(2));
        d2.Process(0.1f, AudioSource.System, t0);
        Assert.False(d2.Process(0.1f, AudioSource.System, t0.AddSeconds(5)));
    }

    [Fact]
    public void testStallDetector_ResultResetsAccumulation()
    {
        var d = new RecognitionStallDetector(0.25f, TimeSpan.FromSeconds(2));
        var t0 = DateTime.UtcNow;
        d.Process(0.5f, AudioSource.System, t0);
        d.Process(0.5f, AudioSource.System, t0.AddSeconds(1.5));
        d.RegisterResult(AudioSource.System);
        Assert.False(d.Process(0.5f, AudioSource.System, t0.AddSeconds(2)));
        Assert.False(d.Process(0.5f, AudioSource.System, t0.AddSeconds(3)));
        Assert.True(d.Process(0.5f, AudioSource.System, t0.AddSeconds(4)));
        d.ResetLane(AudioSource.System);
        d.Process(0.5f, AudioSource.System, t0.AddSeconds(10));
        Assert.True(d.Process(0.5f, AudioSource.System, t0.AddSeconds(12)));
    }

    [Fact]
    public void testSilenceDetector_FiresThenReportsRecovery()
    {
        var d = new SilenceDetector(1e-4f, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1));
        var t0 = DateTime.UtcNow;
        Assert.Equal(SilenceEvent.None, d.Process(0f, t0));
        Assert.Equal(SilenceEvent.None, d.Process(0f, t0.AddSeconds(1)));
        Assert.Equal(SilenceEvent.SilenceDetected, d.Process(0f, t0.AddSeconds(2)));
        Assert.Equal(SilenceEvent.None, d.Process(0f, t0.AddSeconds(5)));
        Assert.Equal(SilenceEvent.None, d.Process(0.1f, t0.AddSeconds(6)));
        Assert.Equal(SilenceEvent.AudioResumed, d.Process(0.1f, t0.AddSeconds(7)));
        Assert.Equal(SilenceEvent.None, d.Process(0.1f, t0.AddSeconds(8)));
    }

    [Fact]
    public void testSilenceDetector_AudibleBufferResetsStreak()
    {
        var d = new SilenceDetector(1e-4f, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1));
        var t0 = DateTime.UtcNow;
        d.Process(0f, t0);
        d.Process(0.01f, t0.AddSeconds(1.5));
        Assert.Equal(SilenceEvent.None, d.Process(0f, t0.AddSeconds(2.5)));
        Assert.Equal(SilenceEvent.None, d.Process(0f, t0.AddSeconds(3.5)));
        Assert.Equal(SilenceEvent.SilenceDetected, d.Process(0f, t0.AddSeconds(4.5)));
    }
}

public class DiagnosticsReportTests
{
    [Fact]
    public void testReport_ContainsMetadataButNoTranscriptLikeContent()
    {
        var input = new DiagnosticsReport.Input("2.0.0", "Windows 11", "CPU, 16 GB", "granted", "http://localhost:11434", true,
            "qwen3.5:4b", "Standard (Chat)", "small", true, "English (US)", "Chinese (Simplified)", "Chinese", true, false,
            "Running", "0.12.0", new[] { "qwen3.5:4b" }, false, 42, 4096, "30m");
        var report = DiagnosticsReport.Build(input, new DateTime(2026, 11, 1, 0, 0, 0, DateTimeKind.Utc));
        Assert.Contains("Generated: 2026-11-01T00:00:00Z", report);
        Assert.Contains("History: disabled (42 entries retained)", report);
        Assert.Contains("num_ctx=4096", report);
        Assert.Contains("SYS English (US) · MIC Chinese (Simplified) → Chinese", report);
        Assert.Contains("whisper small (downloaded)", report);
        Assert.DoesNotContain("transcript:", report.ToLowerInvariant().Replace("transcripts, translations", ""));
    }
}

public class HistoryStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "lct-tests", Guid.NewGuid().ToString("N"));
    private readonly HistoryStore _store;

    public HistoryStoreTests()
    {
        _store = new HistoryStore(Path.Combine(_dir, "history.db"));
    }

    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try { Directory.Delete(_dir, true); } catch (IOException) { }
    }

    private static TranslationEntry Entry(string src, string dst, DateTime at, AudioSource source = AudioSource.System)
        => new(Guid.NewGuid(), src, dst, "Chinese", at, 123, source);

    [Fact]
    public void testLogLoadSearchDelete()
    {
        var now = DateTime.UtcNow;
        var a = Entry("hello", "你好", now.AddMinutes(-2));
        var b = Entry("goodbye", "再见", now.AddMinutes(-1), AudioSource.Microphone);
        _store.Log(a);
        _store.Log(b);
        Assert.Equal(2, _store.Count());
        var recent = _store.LoadRecent();
        Assert.Equal("goodbye", recent[0].SourceText);
        Assert.Equal(AudioSource.Microphone, recent[0].Source);
        Assert.Equal(123, recent[0].LatencyMs);
        Assert.Single(_store.Search("你好"));
        Assert.Single(_store.Search("good"));
        Assert.Empty(_store.Search("zzz"));
        _store.Delete(a.Id);
        Assert.Equal(1, _store.Count());
        _store.Clear();
        Assert.Equal(0, _store.Count());
    }

    [Fact]
    public void testPrune_ByAgeAndCount()
    {
        var now = DateTime.UtcNow;
        _store.Log(Entry("old", "旧", now.AddDays(-40)));
        for (var i = 0; i < 5; i++)
        {
            _store.Log(Entry("new" + i, "新", now.AddMinutes(-i)));
        }
        var removed = _store.Prune(30, 3, now);
        Assert.Equal(3, removed);
        var remaining = _store.LoadRecent();
        Assert.Equal(3, remaining.Count);
        Assert.Equal("new0", remaining[0].SourceText);
    }

    [Fact]
    public void testExportCsv_EscapesQuotes()
    {
        _store.Log(Entry("say \"hi\"", "说“嗨”", DateTime.UtcNow));
        var csv = _store.ExportCsv();
        Assert.StartsWith("Timestamp,Source,SourceText,TranslatedText,TargetLanguage,LatencyMs\n", csv);
        Assert.Contains("\"say \"\"hi\"\"\"", csv);
    }
}
