using System.Net.Http;
using System.Collections.ObjectModel;
using System.Diagnostics;
using LCT.Core.Models;
using LCT.Core.Speech;
using LCT.Core.Translation;
using LiveCaptionsTranslator.Services.Audio;
using LiveCaptionsTranslator.Services.Ollama;
using LiveCaptionsTranslator.Services.Platform;
using LiveCaptionsTranslator.Services.Speech;
using Serilog;

namespace LiveCaptionsTranslator.ViewModels;

public enum SetupStep
{
    Welcome,
    Devices,
    CheckingOllama,
    OllamaNotInstalled,
    RemoteOllama,
    ModelMissing,
    DownloadingModel,
    SpeechModel,
    Complete,
}

/// <summary>First-run wizard: welcome → devices → Ollama check → (install | remote | model) → speech model → done.</summary>
public sealed class WelcomeViewModel : ObservableObject
{
    private readonly OllamaGuardian _guardian;
    private readonly OllamaClient _client;
    private readonly WhisperModelStore _whisperStore;
    private readonly IpexOllamaInstaller _ipex = new();
    private SetupStep _step = SetupStep.Welcome;
    private string _statusMessage = "";
    private string? _errorMessage;
    private string _remoteHost = "";
    private int _remotePort = 11434;
    private string _remoteModel;
    private bool _isBusy;
    private double _progress;
    private string _progressText = "";
    private string _selectedModelName;
    private string? _readyModelName;
    private CancellationTokenSource? _cts;

    public AppSettings Settings { get; }
    public HardwareProfile Hardware { get; } = HardwareInfo.Current;
    public ModelRecommendation Recommendation { get; }
    public WhisperModelInfo WhisperRecommendation { get; }
    public OllamaModelManager ModelManager { get; }
    public ObservableCollection<DeviceOption> InputDevices { get; } = new();
    public IReadOnlyList<TranslationModelInfo> ModelChoices { get; }
    public IReadOnlyList<LanguageOption> SourceLanguages { get; } = LanguageInfo.AllSources.Select(l => new LanguageOption(l, l.DisplayName())).ToList();
    public IReadOnlyList<TargetOption> TargetLanguages { get; } = LanguageInfo.AllTargets.Select(l => new TargetOption(l, $"{l.DisplayName()} ({l.NativeName()})")).ToList();

    public event Action? Completed;

    public WelcomeViewModel(AppSettings settings, OllamaGuardian guardian, OllamaClient client, OllamaModelManager modelManager, WhisperModelStore whisperStore)
    {
        Settings = settings;
        _guardian = guardian;
        _client = client;
        ModelManager = modelManager;
        _whisperStore = whisperStore;
        Recommendation = ModelRecommender.Recommend(Hardware);
        WhisperRecommendation = WhisperModelCatalog.Recommend(Hardware);
        ModelChoices = new[] { Recommendation.Recommended }.Concat(Recommendation.Alternatives).ToList();
        _selectedModelName = Recommendation.Recommended.Name;
        _remoteModel = Recommendation.Recommended.Name;
        Settings.OllamaModel = Recommendation.Recommended.Name;
        Settings.WhisperModel = WhisperRecommendation.Name;

        var devices = AudioDevices.ListInputDevices();
        InputDevices.Add(new DeviceOption(null, $"System Default ({devices.FirstOrDefault(d => d.IsDefault)?.Name ?? "unavailable"})"));
        foreach (var d in devices) InputDevices.Add(new DeviceOption(d.Id, d.IsVirtual ? d.Name + " (virtual)" : d.Name));

        NextCommand = new AsyncRelayCommand(NextAsync, () => !IsBusy);
        BackCommand = new RelayCommand(Back, () => !IsBusy && Step is not (SetupStep.Welcome or SetupStep.CheckingOllama or SetupStep.DownloadingModel));
        CheckAgainCommand = new AsyncRelayCommand(CheckOllamaAsync, () => !IsBusy);
        OpenDownloadPageCommand = new RelayCommand(() => Open(OllamaGuardian.DownloadPage.ToString()));
        UseRemoteCommand = new RelayCommand(() => Step = SetupStep.RemoteOllama);
        SaveRemoteCommand = new AsyncRelayCommand(SaveRemoteAsync, () => !IsBusy);
        InstallIpexCommand = new AsyncRelayCommand(InstallIpexAsync, () => !IsBusy);
        DownloadModelCommand = new AsyncRelayCommand(DownloadModelAsync, () => !IsBusy);
        CancelCommand = new RelayCommand(() => { _cts?.Cancel(); ModelManager.CancelPull(); });
        FinishCommand = new RelayCommand(Finish);
        OpenMicrophonePrivacyCommand = new RelayCommand(() => Open("ms-settings:privacy-microphone"));
    }

    public SetupStep Step
    {
        get => _step;
        private set
        {
            if (Set(ref _step, value))
            {
                ErrorMessage = null;
                OnPropertyChanged(nameof(StepIndex));
                OnPropertyChanged(nameof(StepTitle));
                OnPropertyChanged(nameof(IsWelcome));
                OnPropertyChanged(nameof(IsDevices));
                OnPropertyChanged(nameof(IsCheckingOllama));
                OnPropertyChanged(nameof(IsOllamaNotInstalled));
                OnPropertyChanged(nameof(IsRemoteOllama));
                OnPropertyChanged(nameof(IsModelMissing));
                OnPropertyChanged(nameof(IsDownloadingModel));
                OnPropertyChanged(nameof(IsSpeechModel));
                OnPropertyChanged(nameof(IsComplete));
                OnPropertyChanged(nameof(NextText));
                OnPropertyChanged(nameof(ShowNext));
                BackCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public int StepIndex => Step switch
    {
        SetupStep.Welcome => 0,
        SetupStep.Devices => 1,
        SetupStep.SpeechModel => 3,
        SetupStep.Complete => 4,
        _ => 2,
    };
    public string StepTitle => Step switch
    {
        SetupStep.Welcome => "Welcome to LCT",
        SetupStep.Devices => "Audio & Languages",
        SetupStep.CheckingOllama => "Setting up…",
        SetupStep.OllamaNotInstalled => "Ollama Required",
        SetupStep.RemoteOllama => "Remote Ollama Server",
        SetupStep.ModelMissing => "Translation Model Required",
        SetupStep.DownloadingModel => "Downloading Model",
        SetupStep.SpeechModel => "Speech Model",
        _ => "Ready",
    };
    public bool IsWelcome => Step == SetupStep.Welcome;
    public bool IsDevices => Step == SetupStep.Devices;
    public bool IsCheckingOllama => Step == SetupStep.CheckingOllama;
    public bool IsOllamaNotInstalled => Step == SetupStep.OllamaNotInstalled;
    public bool IsRemoteOllama => Step == SetupStep.RemoteOllama;
    public bool IsModelMissing => Step == SetupStep.ModelMissing;
    public bool IsDownloadingModel => Step == SetupStep.DownloadingModel;
    public bool IsSpeechModel => Step == SetupStep.SpeechModel;
    public bool IsComplete => Step == SetupStep.Complete;
    public bool ShowNext => Step is SetupStep.Welcome or SetupStep.Devices or SetupStep.SpeechModel;
    public string NextText => Step switch
    {
        SetupStep.Welcome => "Get Started",
        SetupStep.Devices => "Continue",
        SetupStep.SpeechModel => WhisperDownloaded ? "Continue" : "Download & Continue",
        _ => "Next",
    };

    public string StatusMessage { get => _statusMessage; private set => Set(ref _statusMessage, value); }
    public string? ErrorMessage { get => _errorMessage; private set { if (Set(ref _errorMessage, value)) OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => ErrorMessage != null;
    public bool IsBusy { get => _isBusy; private set { if (Set(ref _isBusy, value)) { NextCommand.RaiseCanExecuteChanged(); BackCommand.RaiseCanExecuteChanged(); CheckAgainCommand.RaiseCanExecuteChanged(); DownloadModelCommand.RaiseCanExecuteChanged(); SaveRemoteCommand.RaiseCanExecuteChanged(); InstallIpexCommand.RaiseCanExecuteChanged(); } } }
    public double Progress { get => _progress; private set => Set(ref _progress, value); }
    public string ProgressText { get => _progressText; private set => Set(ref _progressText, value); }
    public string RemoteHost { get => _remoteHost; set => Set(ref _remoteHost, value); }
    public int RemotePort { get => _remotePort; set => Set(ref _remotePort, value); }
    public string RemoteModel { get => _remoteModel; set => Set(ref _remoteModel, value); }
    public string? ReadyModelName { get => _readyModelName; private set => Set(ref _readyModelName, value); }
    public bool ShowIpexOption => Hardware.HasIntelGpu && !Hardware.IsArm64;
    public string HardwareText => $"{Hardware.Summary}";
    public string RecommendationReason => Recommendation.Reason;
    public string WhisperText => $"LCT recognizes speech on this PC with whisper.cpp. The recommended model for this PC is '{WhisperRecommendation.Name}' ({WhisperRecommendation.FormattedDownloadSize}); it downloads once to {AppPaths.WhisperModelsDirectory}.";
    public bool WhisperDownloaded => _whisperStore.IsDownloaded(Settings.WhisperModel);

    public string SelectedModelName
    {
        get => _selectedModelName;
        set
        {
            if (Set(ref _selectedModelName, value))
            {
                OnPropertyChanged(nameof(SelectedModelSize));
                OnPropertyChanged(nameof(PullCommandText));
            }
        }
    }
    public TranslationModelInfo? SelectedModel
    {
        get => ModelChoices.FirstOrDefault(m => m.Name == SelectedModelName);
        set { if (value != null) SelectedModelName = value.Name; }
    }
    public string SelectedModelSize => SelectedModel?.FormattedDownloadSize ?? "";
    public string PullCommandText => $"ollama pull {SelectedModelName}";

    public DeviceOption MicrophoneDevice
    {
        get => InputDevices.FirstOrDefault(d => d.Id == Settings.MicrophoneDeviceId) ?? InputDevices[0];
        set { Settings.MicrophoneDeviceId = value?.Id; OnPropertyChanged(); }
    }
    public SourceLanguage SourceLanguage { get => Settings.SourceLanguage; set { Settings.SourceLanguage = value; OnPropertyChanged(); } }
    public TargetLanguage TargetLanguage { get => Settings.TargetLanguage; set { Settings.TargetLanguage = value; OnPropertyChanged(); } }
    public bool CaptureSystemAudio { get => Settings.CaptureSystemAudio; set { Settings.CaptureSystemAudio = value; OnPropertyChanged(); } }
    public bool CaptureMicrophone { get => Settings.CaptureMicrophone; set { Settings.CaptureMicrophone = value; OnPropertyChanged(); } }

    public AsyncRelayCommand NextCommand { get; }
    public RelayCommand BackCommand { get; }
    public AsyncRelayCommand CheckAgainCommand { get; }
    public RelayCommand OpenDownloadPageCommand { get; }
    public RelayCommand UseRemoteCommand { get; }
    public AsyncRelayCommand SaveRemoteCommand { get; }
    public AsyncRelayCommand InstallIpexCommand { get; }
    public AsyncRelayCommand DownloadModelCommand { get; }
    public RelayCommand CancelCommand { get; }
    public RelayCommand FinishCommand { get; }
    public RelayCommand OpenMicrophonePrivacyCommand { get; }

    private async Task NextAsync()
    {
        switch (Step)
        {
            case SetupStep.Welcome:
                Step = SetupStep.Devices;
                break;
            case SetupStep.Devices:
                await CheckOllamaAsync();
                break;
            case SetupStep.SpeechModel:
                if (WhisperDownloaded)
                {
                    Step = SetupStep.Complete;
                }
                else
                {
                    await DownloadWhisperAsync();
                }
                break;
        }
    }

    private void Back()
    {
        Step = Step switch
        {
            SetupStep.Devices => SetupStep.Welcome,
            SetupStep.RemoteOllama => SetupStep.OllamaNotInstalled,
            SetupStep.SpeechModel => SetupStep.Devices,
            _ => SetupStep.Devices,
        };
    }

    private async Task CheckOllamaAsync()
    {
        Step = SetupStep.CheckingOllama;
        IsBusy = true;
        StatusMessage = "Checking Ollama and preparing translation model";
        try
        {
            ApplyLocalEndpoint();
            await _guardian.RefreshStatusAsync();
            if (_guardian.Status != OllamaStatus.Running)
            {
                if (_guardian.Status == OllamaStatus.NotInstalled)
                {
                    Step = SetupStep.OllamaNotInstalled;
                    return;
                }
                StatusMessage = "Starting Ollama…";
                await _guardian.EnsureRunningAsync();
            }
            var installed = (await _client.GetInstalledModelsAsync()).Select(m => m.Name).ToList();
            var compatible = ModelCatalog.All.Select(m => m.Name).Concat(installed.Where(n => n.Contains("qwen", StringComparison.OrdinalIgnoreCase) || n.Contains("gemma", StringComparison.OrdinalIgnoreCase)));
            var preferred = new[] { Recommendation.Recommended.Name }.Concat(Recommendation.Alternatives.Select(a => a.Name)).FirstOrDefault(n => OllamaClient.IsModelInstalled(n, installed));
            if (preferred != null)
            {
                Settings.OllamaModel = preferred;
                ReadyModelName = preferred;
                Step = SetupStep.SpeechModel;
            }
            else if (installed.Count > 0 && compatible.Any(installed.Contains))
            {
                Settings.OllamaModel = installed.First();
                ReadyModelName = Settings.OllamaModel;
                Step = SetupStep.SpeechModel;
            }
            else
            {
                Step = SetupStep.ModelMissing;
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Welcome] Ollama check failed");
            Step = _guardian.Status == OllamaStatus.NotInstalled ? SetupStep.OllamaNotInstalled : SetupStep.OllamaNotInstalled;
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private void ApplyLocalEndpoint()
    {
        Settings.OllamaHost = "localhost";
        Settings.OllamaPort = 11434;
        Settings.RemoteOllamaOptIn = false;
        _client.Configure(OllamaClientOptions.From(Settings));
        _guardian.UseEndpoint(OllamaEndpoint.Local);
    }

    private async Task SaveRemoteAsync()
    {
        IsBusy = true;
        ErrorMessage = null;
        try
        {
            if (!OllamaEndpoint.TryValidate(RemoteHost, RemotePort, true, out var endpoint, out var error))
            {
                ErrorMessage = error;
                return;
            }
            var probe = new AppSettings { OllamaHost = endpoint!.Host, OllamaPort = endpoint.Port, RemoteOllamaOptIn = true, OllamaModel = RemoteModel };
            var client = new OllamaClient(new HttpClient(), OllamaClientOptions.From(probe));
            var installed = (await client.GetInstalledModelsAsync()).Select(m => m.Name).ToList();
            if (!OllamaClient.IsModelInstalled(RemoteModel, installed))
            {
                ErrorMessage = $"'{RemoteModel}' is not installed on that server. Installed: {(installed.Count == 0 ? "none" : string.Join(", ", installed.Take(6)))}";
                return;
            }
            Settings.OllamaHost = endpoint.Host;
            Settings.OllamaPort = endpoint.Port;
            Settings.RemoteOllamaOptIn = true;
            Settings.OllamaModel = RemoteModel;
            _client.Configure(OllamaClientOptions.From(Settings));
            _guardian.UseEndpoint(endpoint);
            ReadyModelName = RemoteModel;
            Step = SetupStep.SpeechModel;
        }
        catch (Exception ex)
        {
            ErrorMessage = "Could not reach that server over HTTPS: " + ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task InstallIpexAsync()
    {
        IsBusy = true;
        ErrorMessage = null;
        _cts = new CancellationTokenSource();
        Progress = 0;
        ProgressText = "Downloading the Intel GPU build of Ollama…";
        Step = SetupStep.DownloadingModel;
        try
        {
            var progress = new Progress<(string Status, double Fraction)>(p => { Progress = p.Fraction; ProgressText = p.Status; });
            await _ipex.InstallAsync(Settings.IpexOllamaUrl, progress, _cts.Token);
            IsBusy = false;
            await CheckOllamaAsync();
        }
        catch (OperationCanceledException)
        {
            Step = SetupStep.OllamaNotInstalled;
        }
        catch (Exception ex)
        {
            Step = SetupStep.OllamaNotInstalled;
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
            _cts = null;
        }
    }

    private async Task DownloadModelAsync()
    {
        var model = SelectedModel ?? Recommendation.Recommended;
        IsBusy = true;
        ErrorMessage = null;
        Step = SetupStep.DownloadingModel;
        ProgressText = $"Downloading {model.DisplayName}…";
        try
        {
            _client.Configure(OllamaClientOptions.From(Settings));
            await ModelManager.PullAsync(model.Name);
            Settings.OllamaModel = model.Name;
            ReadyModelName = model.Name;
            Step = SetupStep.SpeechModel;
        }
        catch (OperationCanceledException)
        {
            Step = SetupStep.ModelMissing;
        }
        catch (Exception ex)
        {
            Step = SetupStep.ModelMissing;
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task DownloadWhisperAsync()
    {
        var model = WhisperModelCatalog.Entry(Settings.WhisperModel) ?? WhisperRecommendation;
        IsBusy = true;
        ErrorMessage = null;
        _cts = new CancellationTokenSource();
        Progress = 0;
        ProgressText = $"Downloading speech model '{model.Name}'…";
        try
        {
            var progress = new Progress<DownloadProgress>(p =>
            {
                Progress = p.Fraction;
                ProgressText = $"{(int)(p.Fraction * 100)}% · {ByteFormat.Format(p.CompletedBytes)} / {ByteFormat.Format(p.TotalBytes)}";
            });
            await _whisperStore.DownloadAsync(model, progress, _cts.Token);
            OnPropertyChanged(nameof(WhisperDownloaded));
            Step = SetupStep.Complete;
        }
        catch (OperationCanceledException)
        {
            ProgressText = "Cancelled";
        }
        catch (Exception ex)
        {
            ErrorMessage = "Speech model download failed: " + ex.Message;
        }
        finally
        {
            IsBusy = false;
            _cts = null;
            OnPropertyChanged(nameof(NextText));
        }
    }

    private void Finish()
    {
        try
        {
            Settings.Save(AppPaths.SettingsFile);
            File.WriteAllText(AppPaths.SetupCompleteMarker, DateTime.UtcNow.ToString("O"));
        }
        catch (Exception ex)
        {
            Log.Error(ex, "[Welcome] could not persist setup");
        }
        Completed?.Invoke();
    }

    private static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception ex) { Log.Warning(ex, "open failed"); }
    }
}
