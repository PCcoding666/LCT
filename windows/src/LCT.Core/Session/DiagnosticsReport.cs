using System.Globalization;

namespace LCT.Core.Session;

/// <summary>Metadata-only diagnostics export: no log lines, no transcripts, no translations.</summary>
public static class DiagnosticsReport
{
    public sealed record Input(
        string AppVersion,
        string OsVersion,
        string Hardware,
        string MicrophoneAccess,
        string OllamaUrl,
        bool OllamaIsLocal,
        string ModelName,
        string ModelType,
        string WhisperModel,
        bool WhisperModelPresent,
        string SourceLanguage,
        string MicrophoneLanguage,
        string TargetLanguage,
        bool CaptureSystemAudio,
        bool CaptureMicrophone,
        string OllamaStatus,
        string OllamaVersion,
        IReadOnlyList<string> InstalledModels,
        bool HistoryEnabled,
        int HistoryEntryCount,
        int NumCtx,
        string KeepAlive);

    public static string Build(Input input, DateTime? now = null)
    {
        var generated = (now ?? DateTime.UtcNow).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        var historyLine = input.HistoryEnabled
            ? $"History: enabled ({input.HistoryEntryCount} entries)"
            : $"History: disabled ({input.HistoryEntryCount} entries retained)";
        var lines = new[]
        {
            "LCT Diagnostics Report (metadata only)",
            $"Generated: {generated}",
            "This report contains settings and status metadata only.",
            "It never includes transcripts, translations, or log content.",
            "",
            "== App ==",
            $"Version: {input.AppVersion}",
            $"Windows: {input.OsVersion}",
            $"Hardware: {input.Hardware}",
            "",
            "== Permissions ==",
            $"Microphone: {input.MicrophoneAccess}",
            "System audio: WASAPI loopback (no permission required)",
            "",
            "== Configuration ==",
            $"Ollama: {input.OllamaUrl} ({(input.OllamaIsLocal ? "local" : "remote")})",
            $"Model: {input.ModelName} [{input.ModelType}] num_ctx={input.NumCtx} keep_alive={input.KeepAlive}",
            $"Speech model: whisper {input.WhisperModel} ({(input.WhisperModelPresent ? "downloaded" : "missing")})",
            $"Languages: SYS {input.SourceLanguage} · MIC {input.MicrophoneLanguage} → {input.TargetLanguage}",
            $"Capture: systemAudio={input.CaptureSystemAudio} microphone={input.CaptureMicrophone}",
            historyLine,
            "",
            "== Ollama ==",
            $"Status: {input.OllamaStatus}",
            $"Version: {input.OllamaVersion}",
            $"Installed models: {(input.InstalledModels.Count == 0 ? "(none / unreachable)" : string.Join(", ", input.InstalledModels))}",
        };
        return string.Join("\n", lines);
    }
}
