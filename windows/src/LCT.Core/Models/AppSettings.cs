using System.Text.Json;
using System.Text.Json.Serialization;
using LCT.Core.Translation;

namespace LCT.Core.Models;

/// <summary>
/// Application settings. Keys mirror macos/LCTMac/Models/AppSettings.swift one
/// to one, plus the Windows-only keys at the end. Persisted as JSON; missing
/// keys take the defaults declared here, so files written by older versions
/// keep loading.
/// </summary>
public sealed class AppSettings
{
    // ---- Audio ----
    public bool CaptureSystemAudio { get; set; } = true;
    public bool CaptureMicrophone { get; set; } = true;
    /// <summary>WASAPI device id of the microphone; null follows the default input device.</summary>
    public string? MicrophoneDeviceId { get; set; }

    // ---- Speech recognition ----
    /// <summary>Recognition language of the system-audio channel (and the default for the mic channel).</summary>
    public SourceLanguage SourceLanguage { get; set; } = SourceLanguage.English;
    /// <summary>Recognition language of the microphone channel; null follows <see cref="SourceLanguage"/>.</summary>
    public SourceLanguage? MicrophoneSourceLanguage { get; set; }
    /// <summary>Whisper ggml model name (catalog key): tiny, base, small, medium, large-v3-turbo.</summary>
    public string WhisperModel { get; set; } = "small";

    // ---- Ollama ----
    public string OllamaHost { get; set; } = "localhost";
    public int OllamaPort { get; set; } = 11434;
    /// <summary>Explicit consent to connect to a non-loopback Ollama. Remote endpoints are HTTPS only.</summary>
    public bool RemoteOllamaOptIn { get; set; }
    public string OllamaModel { get; set; } = "qwen3.5:4b";
    public int OllamaTimeout { get; set; } = 30;
    public double OllamaTemperature { get; set; } = 0.3;
    public ModelKeepAlive ModelKeepAlive { get; set; } = ModelKeepAlive.Minutes30;
    public bool UnloadModelOnQuit { get; set; } = true;
    /// <summary>options.num_ctx for every chat request. Without it Ollama loads 4B models with a 32K context (7 GB+).</summary>
    public int OllamaNumCtx { get; set; } = 4096;
    /// <summary>Optional override for the IPEX-LLM portable Ollama archive (Intel GPU path).</summary>
    public string IpexOllamaUrl { get; set; } = "";

    // ---- Translation ----
    public TargetLanguage TargetLanguage { get; set; } = TargetLanguage.Chinese;
    public TranslationModelType TranslationModelType { get; set; } = TranslationModelType.Standard;
    public bool ContextAware { get; set; } = true;
    public int MaxContextEntries { get; set; } = 5;
    public string CustomPrompt { get; set; } = "";
    /// <summary>Translate the in-progress draft before a sentence finalizes. Drafts never enter history or context.</summary>
    public bool LiveDraftTranslation { get; set; } = true;

    // ---- History ----
    public bool HistoryEnabled { get; set; }
    public int HistoryRetentionDays { get; set; } = 30;
    public int HistoryMaxEntries { get; set; } = 5000;

    // ---- UI ----
    public double OverlayOpacity { get; set; } = 0.85;
    public double OverlayFontSize { get; set; } = 14.0;
    public bool ShowLatency { get; set; } = true;
    public int MaxDisplayCards { get; set; } = 5;

    // ---- Overlay ----
    public double OverlayPositionX { get; set; }
    public double OverlayPositionY { get; set; }
    public double OverlayWidth { get; set; } = 400.0;
    public double OverlayHeight { get; set; } = 200.0;
    public bool OverlayClickThrough { get; set; }
    public bool OverlayStayOnTop { get; set; } = true;

    // ---- Windows only ----
    /// <summary>Main window placement "left,top,width,height" in DIPs; empty uses the default.</summary>
    public string MainWindowBounds { get; set; } = "";
    public bool HotkeysEnabled { get; set; } = true;
    public bool MinimizeToTrayOnClose { get; set; } = true;

    // ---- Derived ----

    [JsonIgnore]
    public static string DefaultPrompt => PromptTemplate.Default;

    /// <summary>The effective recognition language of a channel.</summary>
    public SourceLanguage LanguageFor(AudioSource source) => source switch
    {
        AudioSource.Microphone => MicrophoneSourceLanguage ?? SourceLanguage,
        _ => SourceLanguage,
    };

    /// <summary>System prompt for the chat model, with the target language substituted.</summary>
    [JsonIgnore]
    public string TranslationPrompt => PromptTemplate.Render(CustomPrompt, TargetLanguage);

    /// <summary>The validated endpoint, or null when host/port/opt-in are invalid.</summary>
    [JsonIgnore]
    public OllamaEndpoint? ValidatedOllamaEndpoint
        => OllamaEndpoint.TryValidate(OllamaHost, OllamaPort, RemoteOllamaOptIn, out var endpoint, out _) ? endpoint : null;

    /// <summary>Why the endpoint configuration is invalid, or null when it is fine.</summary>
    [JsonIgnore]
    public string? OllamaEndpointError
        => OllamaEndpoint.TryValidate(OllamaHost, OllamaPort, RemoteOllamaOptIn, out _, out var error) ? null : error;

    [JsonIgnore]
    public string OllamaUrl => ValidatedOllamaEndpoint?.BaseUrl ?? "lct-invalid://endpoint-disabled";

    [JsonIgnore]
    public bool IsLocalOllama => ValidatedOllamaEndpoint?.IsLoopback ?? true;

    public AppSettings Clone() => (AppSettings)MemberwiseClone();

    // ---- Persistence ----

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters = { new SourceLanguageJsonConverter(), new TargetLanguageJsonConverter(), new JsonStringEnumConverter() },
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOptions);

    /// <summary>Parse settings JSON. Unknown keys are ignored, missing keys keep defaults; invalid JSON yields defaults.</summary>
    public static AppSettings FromJson(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<AppSettings>(json, JsonOptions) ?? new AppSettings();
        }
        catch (JsonException)
        {
            return new AppSettings();
        }
    }

    public static AppSettings Load(string path)
    {
        if (!File.Exists(path))
        {
            return new AppSettings();
        }
        try
        {
            return FromJson(File.ReadAllText(path));
        }
        catch (IOException)
        {
            return new AppSettings();
        }
    }

    /// <summary>Write atomically: serialize to a temp file next to the target, then replace.</summary>
    public void Save(string path)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        var temp = path + ".tmp";
        File.WriteAllText(temp, ToJson());
        File.Move(temp, path, overwrite: true);
    }
}
