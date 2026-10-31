using System.Net.Http;
using System.Collections.ObjectModel;
using System.Diagnostics;
using LCT.Core.Models;
using LCT.Core.Session;
using LCT.Core.Speech;
using LCT.Core.Translation;
using LiveCaptionsTranslator.Services.Audio;
using LiveCaptionsTranslator.Services.Ollama;
using LiveCaptionsTranslator.Services.Platform;
using LiveCaptionsTranslator.Services.Speech;
using Serilog;

namespace LiveCaptionsTranslator.ViewModels;

public sealed record LanguageOption(SourceLanguage? Value, string Label);
public sealed record TargetOption(TargetLanguage Value, string Label);
public sealed record KeepAliveOption(ModelKeepAlive Value, string Label);
public sealed record ModelTypeOption(TranslationModelType Value, string Label);
public sealed record DeviceOption(string? Id, string Label);

public sealed class WhisperModelOption : ObservableObject
{
    private bool _isDownloaded;
    public WhisperModelInfo Info { get; }
    public string Name => Info.Name;
    public bool IsDownloaded { get => _isDownloaded; set { if (Set(ref _isDownloaded, value)) OnPropertyChanged(nameof(Label)); } }
    public string Label => $"{Info.Name} · {Info.FormattedDownloadSize} · {Info.Summary}" + (IsDownloaded ? "  ✓" : "");
    public WhisperModelOption(WhisperModelInfo info, bool isDownloaded) { Info = info; _isDownloaded = isDownloaded; }
}

/// <summary>Edits a copy of the settings; Save applies it through the main view model.</summary>
public sealed class SettingsViewModel : ObservableObject
{
    private readonly TranscriptionViewModel _vm;
    private AppSettings _local;
    private string? _modelListError;
    private bool _isLoadingModels;
    private string? _modelDownloadError;
    private string? _diagnosticsMessage;
    private bool _isDownloadingWhisper;
    private double _whisperProgress;
    private string _whisperProgressText = "";
    private CancellationTokenSource? _whisperCts;

    public HardwareProfile Hardware { get; } = HardwareInfo.Current;
    public ModelRecommendation Recommendation { get; }
    public WhisperModelInfo WhisperRecommendation { get; }
    public OllamaModelManager ModelManager => _vm.ModelManager;

    public ObservableCollection<string> InstalledModels { get; } = new();
    public ObservableCollection<string> ModelOptions { get; } = new();
    public ObservableCollection<DeviceOption> InputDevices { get; } = new();
    public ObservableCollection<WhisperModelOption> WhisperModels { get; } = new();

    public IReadOnlyList<LanguageOption> SourceLanguages { get; } = LanguageInfo.AllSources.Select(l => new LanguageOption(l, l.DisplayName())).ToList();
    public IReadOnlyList<LanguageOption> MicrophoneLanguages { get; }
    public IReadOnlyList<TargetOption> TargetLanguages { get; } = LanguageInfo.AllTargets.Select(l => new TargetOption(l, $"{l.DisplayName()} ({l.NativeName()})")).ToList();
    public IReadOnlyList<KeepAliveOption> KeepAliveOptions { get; } = LanguageInfo.AllKeepAlive.Select(k => new KeepAliveOption(k, k.DisplayName())).ToList();
    public IReadOnlyList<ModelTypeOption> ModelTypes { get; } = Enum.GetValues<TranslationModelType>().Select(t => new ModelTypeOption(t, t.DisplayName())).ToList();

    public event Action? Saved;

    public SettingsViewModel(TranscriptionViewModel vm)
    {
        _vm = vm;
        _local = vm.Settings.Clone();
        Recommendation = ModelRecommender.Recommend(Hardware);
        WhisperRecommendation = WhisperModelCatalog.Recommend(Hardware);
        MicrophoneLanguages = new[] { new LanguageOption(null, "Same as System Audio") }.Concat(SourceLanguages).ToList();
        RefreshInputDevices();
        RefreshWhisperModels();
        RebuildModelOptions();

        SaveCommand = new AsyncRelayCommand(SaveAsync, () => Local.OllamaEndpointError == null);
        ResetCommand = new RelayCommand(Reset);
        RefreshModelsCommand = new AsyncRelayCommand(RefreshInstalledModelsAsync);
        DownloadModelCommand = new AsyncRelayCommand(DownloadModelAsync, () => !ModelManager.IsPulling);
        CancelPullCommand = new RelayCommand(() => ModelManager.CancelPull());
        DownloadWhisperCommand = new AsyncRelayCommand(DownloadWhisperAsync, () => !IsDownloadingWhisper);
        CancelWhisperCommand = new RelayCommand(() => _whisperCts?.Cancel());
        ShowLogFileCommand = new RelayCommand(ShowLogFile);
        ResetPromptCommand = new RelayCommand(() => CustomPrompt = "");
        PreviewDefaultPromptCommand = new RelayCommand(() => CustomPrompt = PromptTemplate.Default);
        ModelManager.PropertyChanged += (_, _) => { OnPropertyChanged(nameof(ShowDownloadRow)); DownloadModelCommand.RaiseCanExecuteChanged(); };
    }

    public AppSettings Local
    {
        get => _local;
        private set
        {
            _local = value;
            OnPropertyChanged();
            RaiseAllDerived();
        }
    }

    // Wrapped keys whose change drives other UI.
    public string OllamaHost { get => Local.OllamaHost; set { Local.OllamaHost = value; OnPropertyChanged(); RaiseEndpoint(); } }
    public int OllamaPort { get => Local.OllamaPort; set { Local.OllamaPort = value; OnPropertyChanged(); RaiseEndpoint(); } }
    public bool RemoteOllamaOptIn { get => Local.RemoteOllamaOptIn; set { Local.RemoteOllamaOptIn = value; OnPropertyChanged(); RaiseEndpoint(); } }
    public string OllamaModel { get => Local.OllamaModel; set { Local.OllamaModel = value ?? ""; OnPropertyChanged(); OnPropertyChanged(nameof(ShowDownloadRow)); OnPropertyChanged(nameof(SelectedModelMissingText)); } }
    public string WhisperModel { get => Local.WhisperModel; set { Local.WhisperModel = value ?? "small"; OnPropertyChanged(); OnPropertyChanged(nameof(SelectedWhisperOption)); OnPropertyChanged(nameof(ShowWhisperDownload)); } }
    public bool ContextAware { get => Local.ContextAware; set { Local.ContextAware = value; OnPropertyChanged(); } }
    public bool HistoryEnabled { get => Local.HistoryEnabled; set { Local.HistoryEnabled = value; OnPropertyChanged(); } }
    public string CustomPrompt { get => Local.CustomPrompt; set { Local.CustomPrompt = value ?? ""; OnPropertyChanged(); OnPropertyChanged(nameof(PromptButtonText)); OnPropertyChanged(nameof(PromptPreview)); } }
    public SourceLanguage SourceLanguage { get => Local.SourceLanguage; set { Local.SourceLanguage = value; OnPropertyChanged(); } }
    public LanguageOption MicrophoneLanguage
    {
        get => MicrophoneLanguages.First(o => o.Value == Local.MicrophoneSourceLanguage);
        set { Local.MicrophoneSourceLanguage = value?.Value; OnPropertyChanged(); }
    }
    public DeviceOption MicrophoneDevice
    {
        get => InputDevices.FirstOrDefault(d => d.Id == Local.MicrophoneDeviceId) ?? InputDevices.First();
        set { Local.MicrophoneDeviceId = value?.Id; OnPropertyChanged(); }
    }

    public string PromptButtonText => string.IsNullOrWhiteSpace(CustomPrompt) ? "Use Default" : "Customized";
    public string PromptPreview => PromptTemplate.Render(CustomPrompt, Local.TargetLanguage);
    public string? EndpointError => Local.OllamaEndpointError;
    public bool HasEndpointError => EndpointError != null;
    public string RecommendationText => $"Recommended for this PC ({Hardware.Summary}): {Recommendation.Recommended.DisplayName} — {Recommendation.Reason}";
    public string WhisperRecommendationText => $"Recommended speech model: {WhisperRecommendation.Name} ({WhisperRecommendation.FormattedDownloadSize}). Models are stored in {AppPaths.WhisperModelsDirectory}.";
    public string? ModelListError { get => _modelListError; private set { Set(ref _modelListError, value); OnPropertyChanged(nameof(ModelCountText)); } }
    public bool IsLoadingModels { get => _isLoadingModels; private set => Set(ref _isLoadingModels, value); }
    public string ModelCountText => IsLoadingModels ? "Checking installed models…" : ModelListError ?? $"{InstalledModels.Count} model(s) installed";
    public string? ModelDownloadError { get => _modelDownloadError; private set => Set(ref _modelDownloadError, value); }
    public string? DiagnosticsMessage { get => _diagnosticsMessage; private set => Set(ref _diagnosticsMessage, value); }
    public bool IsSelectedModelInstalled => OllamaClient.IsModelInstalled(OllamaModel, InstalledModels);
    public bool ShowDownloadRow => !ModelManager.IsPulling && !IsSelectedModelInstalled && OllamaModel.Length > 0 && Local.ValidatedOllamaEndpoint != null;
    public string SelectedModelMissingText => $"'{OllamaModel}' is not installed.";
    public WhisperModelOption? SelectedWhisperOption
    {
        get => WhisperModels.FirstOrDefault(m => m.Name == WhisperModel);
        set { if (value != null) WhisperModel = value.Name; }
    }
    public bool ShowWhisperDownload => !IsDownloadingWhisper && SelectedWhisperOption is { IsDownloaded: false };
    public bool IsDownloadingWhisper { get => _isDownloadingWhisper; private set { if (Set(ref _isDownloadingWhisper, value)) { OnPropertyChanged(nameof(ShowWhisperDownload)); DownloadWhisperCommand.RaiseCanExecuteChanged(); } } }
    public double WhisperProgress { get => _whisperProgress; private set => Set(ref _whisperProgress, value); }
    public string WhisperProgressText { get => _whisperProgressText; private set => Set(ref _whisperProgressText, value); }
    public string HotkeyText => $"{GlobalHotKeys.Describe(HotKeyAction.ToggleCapture)} start/stop · {GlobalHotKeys.Describe(HotKeyAction.TogglePause)} pause · {GlobalHotKeys.Describe(HotKeyAction.ToggleOverlay)} overlay";

    public AsyncRelayCommand SaveCommand { get; }
    public RelayCommand ResetCommand { get; }
    public AsyncRelayCommand RefreshModelsCommand { get; }
    public AsyncRelayCommand DownloadModelCommand { get; }
    public RelayCommand CancelPullCommand { get; }
    public AsyncRelayCommand DownloadWhisperCommand { get; }
    public RelayCommand CancelWhisperCommand { get; }
    public RelayCommand ShowLogFileCommand { get; }
    public RelayCommand ResetPromptCommand { get; }
    public RelayCommand PreviewDefaultPromptCommand { get; }

    private void RaiseEndpoint()
    {
        OnPropertyChanged(nameof(EndpointError));
        OnPropertyChanged(nameof(HasEndpointError));
        OnPropertyChanged(nameof(ShowDownloadRow));
        SaveCommand.RaiseCanExecuteChanged();
    }

    private void RaiseAllDerived()
    {
        foreach (var name in new[] { nameof(OllamaHost), nameof(OllamaPort), nameof(RemoteOllamaOptIn), nameof(OllamaModel), nameof(WhisperModel), nameof(ContextAware), nameof(HistoryEnabled), nameof(CustomPrompt), nameof(SourceLanguage), nameof(MicrophoneLanguage), nameof(MicrophoneDevice), nameof(SelectedWhisperOption), nameof(PromptButtonText), nameof(PromptPreview), nameof(ShowWhisperDownload) })
        {
            OnPropertyChanged(name);
        }
        RaiseEndpoint();
    }

    private async Task SaveAsync()
    {
        await _vm.UpdateSettingsAsync(Local.Clone());
        Saved?.Invoke();
    }

    private void Reset()
    {
        var fresh = new AppSettings
        {
            MainWindowBounds = Local.MainWindowBounds,
            OverlayPositionX = Local.OverlayPositionX,
            OverlayPositionY = Local.OverlayPositionY,
        };
        Local = fresh;
    }

    public void RefreshInputDevices()
    {
        InputDevices.Clear();
        var devices = AudioDevices.ListInputDevices();
        var defaultName = devices.FirstOrDefault(d => d.IsDefault)?.Name ?? "unavailable";
        InputDevices.Add(new DeviceOption(null, $"System Default ({defaultName})"));
        foreach (var device in devices)
        {
            InputDevices.Add(new DeviceOption(device.Id, device.IsVirtual ? $"{device.Name} (virtual)" : device.Name));
        }
        OnPropertyChanged(nameof(MicrophoneDevice));
    }

    private void RefreshWhisperModels()
    {
        WhisperModels.Clear();
        foreach (var model in WhisperModelCatalog.All)
        {
            WhisperModels.Add(new WhisperModelOption(model, _vm.WhisperStore.IsDownloaded(model)));
        }
        OnPropertyChanged(nameof(SelectedWhisperOption));
        OnPropertyChanged(nameof(ShowWhisperDownload));
    }

    private void RebuildModelOptions()
    {
        var options = new List<string>(InstalledModels);
        if (!options.Contains(Recommendation.Recommended.Name)) options.Add(Recommendation.Recommended.Name);
        foreach (var alt in Recommendation.Alternatives.Where(a => !options.Contains(a.Name))) options.Add(alt.Name);
        if (!options.Contains(OllamaModel)) options.Add(OllamaModel);
        ModelOptions.Clear();
        foreach (var o in options) ModelOptions.Add(o);
        OnPropertyChanged(nameof(OllamaModel));
        OnPropertyChanged(nameof(ShowDownloadRow));
    }

    public async Task RefreshInstalledModelsAsync()
    {
        IsLoadingModels = true;
        ModelListError = null;
        try
        {
            if (Local.ValidatedOllamaEndpoint == null)
            {
                ModelListError = Local.OllamaEndpointError ?? "Invalid Ollama address";
                InstalledModels.Clear();
                return;
            }
            var probe = new OllamaClient(new HttpClient(), OllamaClientOptions.From(Local));
            var models = await probe.GetInstalledModelsAsync();
            InstalledModels.Clear();
            foreach (var m in models) InstalledModels.Add(m.Name);
            if (InstalledModels.Count == 0)
            {
                ModelListError = $"No models installed — download {Recommendation.Recommended.Name} below";
            }
        }
        catch (Exception ex)
        {
            InstalledModels.Clear();
            ModelListError = "Cannot reach Ollama — start it or check Advanced › Ollama Connection (" + ex.Message + ")";
        }
        finally
        {
            IsLoadingModels = false;
            OnPropertyChanged(nameof(ModelCountText));
            RebuildModelOptions();
        }
    }

    private async Task DownloadModelAsync()
    {
        ModelDownloadError = null;
        var model = OllamaModel;
        try
        {
            _vm.Ollama.Configure(OllamaClientOptions.From(Local));
            await ModelManager.PullAsync(model);
            await RefreshInstalledModelsAsync();
        }
        catch (OperationCanceledException)
        {
            // state already reset by the manager
        }
        catch (Exception ex)
        {
            ModelDownloadError = ex.Message;
        }
        finally
        {
            _vm.Ollama.Configure(OllamaClientOptions.From(_vm.Settings));
        }
    }

    private async Task DownloadWhisperAsync()
    {
        var option = SelectedWhisperOption;
        if (option == null)
        {
            return;
        }
        _whisperCts = new CancellationTokenSource();
        IsDownloadingWhisper = true;
        WhisperProgress = 0;
        WhisperProgressText = "Starting…";
        var progress = new Progress<DownloadProgress>(p =>
        {
            WhisperProgress = p.Fraction;
            WhisperProgressText = $"{(int)(p.Fraction * 100)}% · {ByteFormat.Format(p.CompletedBytes)} / {ByteFormat.Format(p.TotalBytes)}";
        });
        try
        {
            await _vm.WhisperStore.DownloadAsync(option.Info, progress, _whisperCts.Token);
            option.IsDownloaded = true;
            WhisperProgressText = "Downloaded";
        }
        catch (OperationCanceledException)
        {
            WhisperProgressText = "Cancelled";
        }
        catch (Exception ex)
        {
            WhisperProgressText = "Failed: " + ex.Message;
        }
        finally
        {
            IsDownloadingWhisper = false;
            _whisperCts.Dispose();
            _whisperCts = null;
            RefreshWhisperModels();
        }
    }

    private void ShowLogFile()
    {
        try
        {
            var path = Directory.Exists(AppPaths.LogsDirectory) ? AppPaths.LogsDirectory : AppPaths.Root;
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            DiagnosticsMessage = "Could not open the log folder: " + ex.Message;
        }
    }

    public string BuildDiagnostics()
    {
        int historyCount = 0;
        try { historyCount = _vm.HistoryStoreOrNull?.Count() ?? 0; } catch (Exception) { }
        var input = new DiagnosticsReport.Input(
            AppInfo.Version,
            Environment.OSVersion.VersionString,
            Hardware.Summary,
            "not determined by LCT (WASAPI reports failures at start)",
            Local.OllamaUrl,
            Local.IsLocalOllama,
            Local.OllamaModel,
            Local.TranslationModelType.DisplayName(),
            Local.WhisperModel,
            _vm.WhisperStore.IsDownloaded(Local.WhisperModel),
            Local.SourceLanguage.DisplayName(),
            (Local.MicrophoneSourceLanguage ?? Local.SourceLanguage).DisplayName(),
            Local.TargetLanguage.DisplayName(),
            Local.CaptureSystemAudio,
            Local.CaptureMicrophone,
            _vm.Guardian.Status.DisplayText(),
            _vm.Guardian.Version ?? "unknown",
            InstalledModels.ToList(),
            Local.HistoryEnabled,
            historyCount,
            Local.OllamaNumCtx,
            Local.ModelKeepAlive.OllamaValue());
        return DiagnosticsReport.Build(input);
    }

    public void ReportDiagnostics(string message) => DiagnosticsMessage = message;
}
