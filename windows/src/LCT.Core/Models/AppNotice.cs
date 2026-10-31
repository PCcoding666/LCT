namespace LCT.Core.Models;

public enum NoticeSeverity
{
    Info,
    Warning,
    Error,
}

/// <summary>A remediation the user can take from a notice. Data, not closures, so notices compare by value.</summary>
public enum NoticeAction
{
    OpenMicrophoneSettings,
    OpenSoundSettings,
    StartOllama,
    OpenAppSettings,
    RetryCapture,
    DownloadModel,
    DownloadWhisperModel,
    OpenOllamaDownloadPage,
}

public static class NoticeActionExtensions
{
    public static string Label(this NoticeAction action) => action switch
    {
        NoticeAction.OpenMicrophoneSettings => "Open Privacy Settings",
        NoticeAction.OpenSoundSettings => "Open Sound Settings",
        NoticeAction.StartOllama => "Start Ollama",
        NoticeAction.OpenAppSettings => "Settings",
        NoticeAction.RetryCapture => "Retry",
        NoticeAction.DownloadModel => "Download",
        NoticeAction.DownloadWhisperModel => "Download speech model",
        NoticeAction.OpenOllamaDownloadPage => "Get Ollama",
        _ => action.ToString(),
    };
}

/// <summary>A structured, user-facing notice shown in the banner under the HUD bar.</summary>
public sealed record AppNotice(
    NoticeSeverity Severity,
    string Message,
    IReadOnlyList<NoticeAction> Actions,
    bool AutoDismiss)
{
    public Guid Id { get; } = Guid.NewGuid();

    public static AppNotice Info(string message, bool autoDismiss = true)
        => new(NoticeSeverity.Info, message, Array.Empty<NoticeAction>(), autoDismiss);

    public static AppNotice Warning(string message, bool autoDismiss = true, params NoticeAction[] actions)
        => new(NoticeSeverity.Warning, message, actions, autoDismiss);

    public static AppNotice Error(string message, params NoticeAction[] actions)
        => new(NoticeSeverity.Error, message, actions, false);
}
