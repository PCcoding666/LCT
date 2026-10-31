namespace LiveCaptionsTranslator;

/// <summary>Every on-disk location the app uses, all under %LOCALAPPDATA%\LCT.</summary>
public static class AppPaths
{
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LCT");
    public static readonly string SettingsFile = Path.Combine(Root, "settings.json");
    public static readonly string SetupCompleteMarker = Path.Combine(Root, "setup-complete");
    public static readonly string LogsDirectory = Path.Combine(Root, "logs");
    public static readonly string LogFile = Path.Combine(LogsDirectory, "lct.log");
    public static readonly string OllamaServeLog = Path.Combine(LogsDirectory, "ollama-serve.log");
    public static readonly string HistoryDatabase = Path.Combine(Root, "history.db");
    public static readonly string ModelsDirectory = Path.Combine(Root, "models");
    public static readonly string WhisperModelsDirectory = Path.Combine(ModelsDirectory, "whisper");
    public static readonly string PortableOllamaDirectory = Path.Combine(Root, "ollama");
    public static readonly string DownloadsDirectory = Path.Combine(Root, "downloads");

    public static void EnsureDirectories()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(LogsDirectory);
        Directory.CreateDirectory(WhisperModelsDirectory);
        Directory.CreateDirectory(DownloadsDirectory);
    }
}
