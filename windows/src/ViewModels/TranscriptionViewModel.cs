using System.Collections.ObjectModel;
using System.Diagnostics;
using LCT.Core.Audio;
using LCT.Core.History;
using LCT.Core.Models;
using LCT.Core.Session;
using LCT.Core.Speech;
using LCT.Core.Translation;
using LiveCaptionsTranslator.Services.Audio;
using LiveCaptionsTranslator.Services.Ollama;
using LiveCaptionsTranslator.Services.Speech;
using Serilog;

namespace LiveCaptionsTranslator.ViewModels;

public enum CaptureState
{
    Idle,
    Starting,
    Capturing,
    Stopping,
}

public enum ModelState
{
    Unknown,
    Loading,
    Loaded,
    NotLoaded,
    Failed,
}

/// <summary>
/// The app's single capture session: owns the audio channels, the Whisper
/// recognizers, the translation queue, the on-screen segments, the session
/// transcript, the detectors and the Ollama patrol. Created on the UI thread;
/// every worker-thread event is posted back to that thread before it touches
/// state, so the bound views never see a cross-thread change.
/// </summary>
public sealed class TranscriptionViewModel : ObservableObject, IDisposable
{
    private sealed class Lane
    {
        public required WasapiChannel Channel;
        public required UtteranceChunker Chunker;
        public required WhisperRecognizer Recognizer;
        public required SourceLanguage Language;
        public string Draft = "";
        public string DraftTranslation = "";
        public Guid DraftSegmentId = Guid.NewGuid();
        public SilenceDetector? Silence;
        public float PeakLevel;
        public float PeakRms;
    }

    public AppSettings Settings { get; private set; }
    public OllamaClient Ollama { get; }
    public OllamaGuardian Guardian { get; }
    public OllamaModelManager ModelManager { get; }
    public WhisperModelStore WhisperStore { get; }
    public SessionTranscript Transcript { get; } = new();
    public ObservableCollection<SegmentItem> Segments { get; } = new();

    private readonly SynchronizationContext _ui;
    private readonly TranslationQueue _queue;
    private readonly Dictionary<AudioSource, Lane> _lanes = new();
    private readonly Dictionary<Guid, SegmentItem> _segmentsById = new();
    private readonly List<SegmentItem> _pendingWhilePaused = new();
    private readonly List<TranslationEntry> _context = new();
    private readonly RecognitionStallDetector _stall = new();
    private readonly HashSet<AudioSource> _stallNoticeLanes = new();
    private HistoryStore? _history;
    private int _historyWrites;
    private Timer? _levelTimer;
    private Timer? _clockTimer;
    private Timer? _patrolTimer;
    private Timer? _noticeTimer;
    private OllamaRecoveryController _recovery = new();
    private bool _patrolBusy;
    private DateTime _lastModelReload = DateTime.MinValue;
    private CancellationTokenSource? _downloadCts;
    private bool _disposed;

    // ---- Bindable state ----
    private CaptureState _captureState;
    private bool _isPaused;
    private DateTime? _captureStartedAt;
    private string _elapsedText = "idle";
    private ModelState _modelState;
    private string _modelStateDetail = "Translation model";
    private bool _isTranslating;
    private int _lastLatencyMs;
    private bool _isOllamaConnected;
    private float _systemLevel;
    private float _micLevel;
    private string _liveSourceText = "";
    private string _liveTranslation = "";
    private AppNotice? _notice;
    private string? _microphoneDeviceName;
    private bool _microphoneDeviceIsVirtual;
    private IReadOnlyList<AudioSource> _captureSources = Array.Empty<AudioSource>();

    public CaptureState CaptureState
    {
        get => _captureState;
        private set
        {
            if (Set(ref _captureState, value))
            {
                OnPropertyChanged(nameof(IsCapturing));
                OnPropertyChanged(nameof(IsIdle));
                OnPropertyChanged(nameof(IsBusy));
                OnPropertyChanged(nameof(CaptureButtonText));
                OnPropertyChanged(nameof(HintText));
                UpdateElapsedText();
            }
        }
    }

    public bool IsCapturing => CaptureState == CaptureState.Capturing;
    public bool IsIdle => CaptureState == CaptureState.Idle;
    public bool IsBusy => CaptureState is CaptureState.Starting or CaptureState.Stopping;
    public string CaptureButtonText => CaptureState switch
    {
        CaptureState.Idle => "start",
        CaptureState.Starting => "starting…",
        CaptureState.Capturing => "stop",
        _ => "stopping…",
    };

    public bool IsPaused
    {
        get => _isPaused;
        private set
        {
            if (Set(ref _isPaused, value))
            {
                OnPropertyChanged(nameof(MetersActive));
                UpdateElapsedText();
            }
        }
    }

    public DateTime? CaptureStartedAt { get => _captureStartedAt; private set => Set(ref _captureStartedAt, value); }
    public string ElapsedText { get => _elapsedText; private set => Set(ref _elapsedText, value); }
    public ModelState ModelState { get => _modelState; private set { if (Set(ref _modelState, value)) OnPropertyChanged(nameof(ModelIsLoading)); } }
    public bool ModelIsLoading => ModelState == ModelState.Loading;
    public string ModelStateDetail { get => _modelStateDetail; private set => Set(ref _modelStateDetail, value); }
    public bool IsTranslating { get => _isTranslating; private set => Set(ref _isTranslating, value); }
    public int LastLatencyMs { get => _lastLatencyMs; private set { if (Set(ref _lastLatencyMs, value)) OnPropertyChanged(nameof(LatencyText)); } }
    public string LatencyText => LastLatencyMs > 0 && Settings.ShowLatency ? $"· {LastLatencyMs} ms" : "";
    public bool IsOllamaConnected { get => _isOllamaConnected; private set => Set(ref _isOllamaConnected, value); }
    public float SystemLevel { get => _systemLevel; private set => Set(ref _systemLevel, value); }
    public float MicLevel { get => _micLevel; private set => Set(ref _micLevel, value); }
    public bool MetersActive => IsCapturing && !IsPaused;
    public string LiveSourceText { get => _liveSourceText; private set { if (Set(ref _liveSourceText, value)) { OnPropertyChanged(nameof(HasLiveDraft)); OnPropertyChanged(nameof(ShowEmptyState)); } } }
    public bool ShowEmptyState => Segments.Count == 0 && LiveSourceText.Length == 0;
    public SegmentItem? LastSegment => Segments.Count > 0 ? Segments[^1] : null;
    public bool HasLastSegment => Segments.Count > 0;
    public string LiveTranslation { get => _liveTranslation; private set { if (Set(ref _liveTranslation, value)) OnPropertyChanged(nameof(HasLiveTranslation)); } }
    public bool HasLiveDraft => LiveSourceText.Length > 0;
    public bool HasLiveTranslation => LiveTranslation.Length > 0;
    public AppNotice? Notice { get => _notice; private set { if (Set(ref _notice, value)) OnPropertyChanged(nameof(HasNotice)); } }
    public bool HasNotice => Notice != null;
    public string? MicrophoneDeviceName { get => _microphoneDeviceName; private set => Set(ref _microphoneDeviceName, value); }
    public bool MicrophoneDeviceIsVirtual { get => _microphoneDeviceIsVirtual; private set => Set(ref _microphoneDeviceIsVirtual, value); }
    public IReadOnlyList<AudioSource> CaptureSources
    {
        get => _captureSources;
        private set
        {
            if (Set(ref _captureSources, value))
            {
                OnPropertyChanged(nameof(ShowMicMeter));
                OnPropertyChanged(nameof(ListeningText));
            }
        }
    }
    public bool ShowMicMeter => CaptureSources.Contains(AudioSource.Microphone) || (CaptureSources.Count == 0 && Settings.CaptureMicrophone);
    public bool HasTranscript => Transcript.Entries.Count > 0;
    public string ModelName => Settings.OllamaModel;
    public string LanguageLabelText => LanguageLabel.Format(Settings.SourceLanguage, Settings.MicrophoneSourceLanguage, Settings.TargetLanguage, Settings.CaptureMicrophone);
    public string ListeningText => LanguageLabel.Listening(Settings.SourceLanguage, Settings.MicrophoneSourceLanguage, CaptureSources.Contains(AudioSource.Microphone));
    public string HintText => IsCapturing
        ? "Ctrl+Alt+S stop · Ctrl+Alt+P pause · Ctrl+Alt+O overlay"
        : "Ctrl+Alt+S start · Ctrl+Alt+P pause · Ctrl+Alt+O overlay";
    public OllamaStatus OllamaStatus => Guardian.Status;
    public bool OllamaChecking => Guardian.IsChecking;
    public string OllamaStatusText
    {
        get
        {
            if (Guardian.IsChecking) return "checking…";
            return Guardian.Status switch
            {
                OllamaStatus.Running => "ollama up",
                OllamaStatus.Starting => "starting…",
                OllamaStatus.NotInstalled => "ollama not installed",
                OllamaStatus.Error => "error: " + (Guardian.StatusDetail ?? "unknown"),
                _ => "ollama stopped",
            };
        }
    }
    public bool OllamaUp => IsOllamaConnected || Guardian.Status == OllamaStatus.Running;

    /// <summary>Raised when settings changed through the view model (overlay, hotkeys and the settings page observe it).</summary>
    public event Action<AppSettings>? SettingsChanged;
    /// <summary>A notice asked to open the settings window.</summary>
    public event Action? OpenSettingsRequested;

    public TranscriptionViewModel(AppSettings settings, OllamaClient ollama, OllamaGuardian guardian, OllamaModelManager modelManager, WhisperModelStore whisperStore)
    {
        _ui = SynchronizationContext.Current ?? throw new InvalidOperationException("TranscriptionViewModel must be created on the UI thread");
        Settings = settings;
        Ollama = ollama;
        Guardian = guardian;
        ModelManager = modelManager;
        WhisperStore = whisperStore;
        _queue = new TranslationQueue(ollama);
        Segments.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(ShowEmptyState));
            OnPropertyChanged(nameof(LastSegment));
            OnPropertyChanged(nameof(HasLastSegment));
        };
        _queue.StreamingUpdated += (id, text, isFinal) => Ui(() => OnStreaming(id, text, isFinal));
        _queue.TranslationCompleted += result => Ui(() => OnTranslationCompleted(result));
        Guardian.Changed += () => Ui(() =>
        {
            OnPropertyChanged(nameof(OllamaStatus));
            OnPropertyChanged(nameof(OllamaStatusText));
            OnPropertyChanged(nameof(OllamaChecking));
            OnPropertyChanged(nameof(OllamaUp));
        });
        ApplyEndpoint();
        if (Settings.HistoryEnabled)
        {
            OpenHistory();
        }
    }

    private void Ui(Action action)
    {
        if (_disposed)
        {
            return;
        }
        _ui.Post(_ => { if (!_disposed) action(); }, null);
    }

    // ---- Launch ----

    /// <summary>Warm the translation model once at launch so the first start finds it in memory.</summary>
    public async Task PrepareModelOnLaunchAsync()
    {
        await Guardian.RefreshStatusAsync();
        if (Guardian.Status != OllamaStatus.Running)
        {
            try
            {
                await Guardian.EnsureRunningAsync();
            }
            catch (Exception ex)
            {
                Log.Information("[VM] Ollama not available at launch: {Message}", ex.Message);
                ModelState = ModelState.NotLoaded;
                ModelStateDetail = "Model not loaded — Ollama is not running";
                return;
            }
        }
        IsOllamaConnected = await Ollama.CheckHealthAsync();
        await RefreshModelStateAsync();
        if (ModelState == ModelState.NotLoaded)
        {
            await LoadModelAsync();
        }
    }

    private async Task RefreshModelStateAsync()
    {
        try
        {
            var loaded = await Ollama.GetLoadedModelsAsync();
            var isLoaded = OllamaClient.IsModelInstalled(Settings.OllamaModel, loaded);
            ModelState = isLoaded ? ModelState.Loaded : ModelState.NotLoaded;
            ModelStateDetail = isLoaded ? "Model loaded in memory" : "Model not loaded — it will load when you start";
        }
        catch (Exception ex)
        {
            ModelState = ModelState.Unknown;
            ModelStateDetail = "Translation model (" + ex.Message + ")";
        }
    }

    private async Task LoadModelAsync()
    {
        if (ModelState == ModelState.Loading)
        {
            return;
        }
        ModelState = ModelState.Loading;
        ModelStateDetail = "Model is loading into memory…";
        try
        {
            var ms = await Ollama.PrewarmAsync();
            ModelState = ModelState.Loaded;
            ModelStateDetail = $"Model loaded in memory ({ms} ms)";
            IsOllamaConnected = true;
        }
        catch (OllamaException ex) when (ex.Kind == OllamaErrorKind.ModelNotFound)
        {
            ModelState = ModelState.Failed;
            ModelStateDetail = "Model not installed";
            Notice = AppNotice.Error($"'{Settings.OllamaModel}' is not installed in Ollama.", NoticeAction.DownloadModel, NoticeAction.OpenAppSettings);
        }
        catch (Exception ex)
        {
            ModelState = ModelState.Failed;
            ModelStateDetail = "Model not loaded — " + ex.Message;
        }
    }

    // ---- Start / stop ----

    public Task ToggleCaptureAsync() => CaptureState switch
    {
        CaptureState.Idle => StartAsync(),
        CaptureState.Capturing => StopAsync(),
        _ => Task.CompletedTask,
    };

    public async Task StartAsync()
    {
        if (CaptureState != CaptureState.Idle)
        {
            return;
        }
        if (!Settings.CaptureSystemAudio && !Settings.CaptureMicrophone)
        {
            Notice = AppNotice.Error("Enable system audio or the microphone in Settings before starting.", NoticeAction.OpenAppSettings);
            return;
        }
        var whisperModel = WhisperModelCatalog.Entry(Settings.WhisperModel) ?? WhisperModelCatalog.Small;
        if (!WhisperStore.IsDownloaded(whisperModel))
        {
            Notice = AppNotice.Error($"The speech model '{whisperModel.Name}' ({whisperModel.FormattedDownloadSize}) is not downloaded yet.", NoticeAction.DownloadWhisperModel, NoticeAction.OpenAppSettings);
            return;
        }

        CaptureState = CaptureState.Starting;
        Notice = null;

        // Ollama: start it if needed, but captions do not wait for translation.
        try
        {
            await Guardian.EnsureRunningAsync();
            IsOllamaConnected = await Ollama.CheckHealthAsync();
            var installed = await Ollama.GetInstalledModelsAsync();
            if (!OllamaClient.IsModelInstalled(Settings.OllamaModel, installed.Select(m => m.Name)))
            {
                Notice = AppNotice.Error($"'{Settings.OllamaModel}' is not installed in Ollama — captions will show without translation.", NoticeAction.DownloadModel, NoticeAction.OpenAppSettings);
            }
        }
        catch (Exception ex)
        {
            IsOllamaConnected = false;
            var actions = Guardian.Status == OllamaStatus.NotInstalled
                ? new[] { NoticeAction.OpenOllamaDownloadPage, NoticeAction.OpenAppSettings }
                : new[] { NoticeAction.StartOllama, NoticeAction.OpenAppSettings };
            Notice = AppNotice.Error(ex.Message + " Captions will show without translation.", actions);
        }

        var started = new List<AudioSource>();
        var failures = new List<string>();
        foreach (var source in new[] { AudioSource.System, AudioSource.Microphone })
        {
            var enabled = source == AudioSource.System ? Settings.CaptureSystemAudio : Settings.CaptureMicrophone;
            if (!enabled)
            {
                continue;
            }
            try
            {
                StartLane(source, WhisperStore.PathFor(whisperModel));
                started.Add(source);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "[VM] Could not start {Source} lane", source);
                failures.Add(source == AudioSource.System ? "system audio: " + ex.Message : "microphone: " + ex.Message);
            }
        }

        if (started.Count == 0)
        {
            CaptureState = CaptureState.Idle;
            var actions = Settings.CaptureMicrophone ? new[] { NoticeAction.OpenMicrophoneSettings, NoticeAction.RetryCapture } : new[] { NoticeAction.OpenSoundSettings, NoticeAction.RetryCapture };
            Notice = AppNotice.Error("Could not start audio capture (" + string.Join("; ", failures) + ").", actions);
            return;
        }
        if (failures.Count > 0)
        {
            Notice = AppNotice.Warning("Capturing without " + string.Join("; ", failures), autoDismiss: false, NoticeAction.OpenMicrophoneSettings);
        }

        CaptureSources = started;
        if (Transcript.StartedAt == null)
        {
            Transcript.Begin(DateTime.Now);
        }
        _stall.Reset();
        _stallNoticeLanes.Clear();
        IsPaused = false;
        CaptureStartedAt = DateTime.Now;
        CaptureState = CaptureState.Capturing;
        _levelTimer = new Timer(_ => Ui(TickLevels), null, 60, 60);
        _clockTimer = new Timer(_ => Ui(UpdateElapsedText), null, 1000, 1000);
        StartOllamaPatrol();
        if (IsOllamaConnected && ModelState != ModelState.Loaded)
        {
            _ = LoadModelAsync();
        }
        Log.Information("[VM] Capture started: {Sources}", string.Join(",", started));
    }

    private void StartLane(AudioSource source, string modelPath)
    {
        var language = Settings.LanguageFor(source);
        var channel = new WasapiChannel(source, source == AudioSource.Microphone ? Settings.MicrophoneDeviceId : null);
        var recognizer = new WhisperRecognizer(modelPath, language, source);
        var lane = new Lane
        {
            Channel = channel,
            Chunker = new UtteranceChunker(),
            Recognizer = recognizer,
            Language = language,
            Silence = source == AudioSource.Microphone ? new SilenceDetector() : null,
        };
        channel.Frames += (src, samples, rms) => OnFrames(lane, samples, rms);
        channel.Stopped += (src, error) => Ui(() => OnChannelStopped(src, error));
        recognizer.Result += ev => Ui(() => OnRecognition(ev));
        recognizer.Failed += (src, ex) => Ui(() => Notice = AppNotice.Error($"Speech recognition failed on {src.Label()}: {ex.Message}", NoticeAction.RetryCapture));
        try
        {
            channel.Start();
        }
        catch
        {
            recognizer.Dispose();
            channel.Dispose();
            throw;
        }
        _lanes[source] = lane;
        if (source == AudioSource.Microphone)
        {
            MicrophoneDeviceName = channel.DeviceName;
            MicrophoneDeviceIsVirtual = channel.DeviceName != null && new AudioInputDevice("", channel.DeviceName, false).IsVirtual;
        }
    }

    /// <summary>Capture thread: level, VAD/chunking, silence watchdog.</summary>
    private void OnFrames(Lane lane, float[] samples, float rms)
    {
        var level = LevelMeter.Normalized(rms);
        if (level > lane.PeakLevel) lane.PeakLevel = level;
        if (rms > lane.PeakRms) lane.PeakRms = rms;

        foreach (var request in lane.Chunker.Process(samples))
        {
            lane.Recognizer.Submit(request);
        }

        if (lane.Silence != null)
        {
            var silenceEvent = lane.Silence.Process(rms, DateTime.UtcNow);
            if (silenceEvent == SilenceEvent.SilenceDetected)
            {
                Ui(() => Notice = AppNotice.Warning(
                    $"The microphone '{lane.Channel.DeviceName}' has been completely silent for 6 seconds. Check that it is the right device and not muted.",
                    autoDismiss: false, NoticeAction.OpenSoundSettings, NoticeAction.OpenAppSettings));
            }
            else if (silenceEvent == SilenceEvent.AudioResumed)
            {
                Ui(() => { if (Notice?.Message.Contains("completely silent") == true) Notice = null; });
            }
        }
    }

    private void TickLevels()
    {
        var now = DateTime.UtcNow;
        foreach (var (source, lane) in _lanes)
        {
            var level = lane.PeakLevel;
            lane.PeakLevel = 0;
            lane.PeakRms = 0;
            if (source == AudioSource.System) SystemLevel = level; else MicLevel = level;
            if (IsCapturing && !IsPaused && _stall.Process(level, source, now))
            {
                OnRecognitionStall(source, lane);
            }
        }
    }

    private void OnRecognitionStall(AudioSource source, Lane lane)
    {
        _stallNoticeLanes.Add(source);
        Notice = AppNotice.Warning(
            $"{source.Label()} is receiving audio but nothing is being recognized. Is the recognition language right? It is set to {lane.Language.DisplayName()}.",
            autoDismiss: false, NoticeAction.OpenAppSettings);
    }

    private void OnChannelStopped(AudioSource source, Exception? error)
    {
        if (!IsCapturing || !_lanes.ContainsKey(source))
        {
            return;
        }
        Notice = AppNotice.Error($"{source.Label()} capture stopped" + (error != null ? ": " + error.Message : " (device removed?)"), NoticeAction.RetryCapture, NoticeAction.OpenSoundSettings);
        StopLane(source, flush: true);
        CaptureSources = _lanes.Keys.ToList();
        if (_lanes.Count == 0)
        {
            _ = StopAsync();
        }
    }

    public async Task StopAsync()
    {
        if (CaptureState != CaptureState.Capturing)
        {
            return;
        }
        CaptureState = CaptureState.Stopping;
        StopOllamaPatrol();
        _levelTimer?.Dispose();
        _levelTimer = null;
        _clockTimer?.Dispose();
        _clockTimer = null;
        foreach (var source in _lanes.Keys.ToList())
        {
            StopLane(source, flush: true);
        }
        SystemLevel = 0;
        MicLevel = 0;
        _queue.CancelPendingDebounce();
        IsPaused = false;
        CaptureState = CaptureState.Idle;
        CaptureStartedAt = null;
        await Task.CompletedTask;
        Log.Information("[VM] Capture stopped");
    }

    /// <summary>Stop a lane. The flushed final decodes in the background; the recognizer is released once it had time to finish.</summary>
    private void StopLane(AudioSource source, bool flush)
    {
        if (!_lanes.Remove(source, out var lane))
        {
            return;
        }
        lane.Channel.Stop();
        lane.Channel.Dispose();
        var flushed = flush ? lane.Chunker.Flush() : null;
        if (flushed != null)
        {
            lane.Recognizer.Submit(flushed);
            var recognizer = lane.Recognizer;
            _ = Task.Delay(4000).ContinueWith(_ => recognizer.Dispose(), TaskScheduler.Default);
        }
        else
        {
            lane.Recognizer.Dispose();
        }
        if (lane.Draft.Length > 0 && flushed == null)
        {
            FinalizeDraftAsSegment(lane, source);
        }
        lane.Draft = "";
        lane.DraftTranslation = "";
        RefreshLiveText();
        if (source == AudioSource.System) SystemLevel = 0; else MicLevel = 0;
    }

    // ---- Pause ----

    public void TogglePause()
    {
        if (!IsCapturing)
        {
            return;
        }
        IsPaused = !IsPaused;
        foreach (var (source, lane) in _lanes)
        {
            lane.Channel.Muted = IsPaused;
            if (IsPaused)
            {
                // Finalize what is in flight so nothing said before the pause is lost.
                var flushed = lane.Chunker.Flush();
                if (flushed != null)
                {
                    lane.Recognizer.Submit(flushed);
                }
            }
        }
        if (IsPaused)
        {
            _queue.CancelAll();
            foreach (var segment in Segments.Where(s => s.State == TranslationState.Translating))
            {
                segment.State = TranslationState.Pending;
                if (!_pendingWhilePaused.Contains(segment))
                {
                    _pendingWhilePaused.Add(segment);
                }
            }
            foreach (var lane in _lanes.Values)
            {
                lane.DraftTranslation = "";
            }
            RefreshLiveText();
        }
        else
        {
            foreach (var segment in _pendingWhilePaused.Where(s => s.State == TranslationState.Pending).ToList())
            {
                segment.State = TranslationState.Translating;
                _queue.Enqueue(segment.Id, segment.SourceText, _context.ToList(), TranslationPriority.High, isFinal: true);
            }
            _pendingWhilePaused.Clear();
        }
        Log.Information("[VM] {State}", IsPaused ? "Paused" : "Resumed");
    }

    // ---- Recognition → segments ----

    private void OnRecognition(RecognitionEvent ev)
    {
        if (!_lanes.TryGetValue(ev.Source, out var lane))
        {
            // Lane already stopped (flush tail): still a valid caption.
            if (ev.IsFinal && TextUtils.HasSpeechContent(ev.Text))
            {
                AppendSegment(ev.Source, ev.Text);
            }
            return;
        }
        _stall.RegisterResult(ev.Source);
        if (_stallNoticeLanes.Remove(ev.Source) && Notice?.Message.Contains("nothing is being recognized") == true)
        {
            Notice = null;
        }

        if (!ev.IsFinal)
        {
            lane.Draft = ev.Text;
            RefreshLiveText();
            if (Settings.LiveDraftTranslation && !IsPaused && TextUtils.HasSpeechContent(ev.Text))
            {
                _queue.Enqueue(lane.DraftSegmentId, ev.Text, _context.ToList(), TranslationPriority.Normal, isFinal: false);
            }
            return;
        }

        _queue.Cancel(new[] { lane.DraftSegmentId });
        lane.DraftSegmentId = Guid.NewGuid();
        lane.Draft = "";
        lane.DraftTranslation = "";
        RefreshLiveText();
        if (TextUtils.HasSpeechContent(ev.Text))
        {
            AppendSegment(ev.Source, ev.Text);
        }
    }

    private void FinalizeDraftAsSegment(Lane lane, AudioSource source)
    {
        if (TextUtils.HasSpeechContent(lane.Draft))
        {
            AppendSegment(source, lane.Draft);
        }
        _queue.Cancel(new[] { lane.DraftSegmentId });
        lane.DraftSegmentId = Guid.NewGuid();
    }

    private void AppendSegment(AudioSource source, string text)
    {
        var now = DateTime.Now;
        var state = IsPaused ? TranslationState.Pending : TranslationState.Translating;
        var segment = new SegmentItem(Guid.NewGuid(), source, text, now, state);
        Segments.Add(segment);
        _segmentsById[segment.Id] = segment;
        Transcript.Append(segment.Id, source, text, now);
        OnPropertyChanged(nameof(HasTranscript));
        TrimSegments();
        if (IsPaused)
        {
            _pendingWhilePaused.Add(segment);
        }
        else
        {
            _queue.Enqueue(segment.Id, text, _context.ToList(), TranslationPriority.High, isFinal: true);
        }
    }

    private void TrimSegments()
    {
        var max = Math.Max(1, Settings.MaxDisplayCards);
        while (Segments.Count > max)
        {
            // Keep the id map for in-flight translations; they still complete into the transcript.
            Segments.RemoveAt(0);
        }
    }

    private void RefreshLiveText()
    {
        LiveSourceText = Combine(l => l.Draft);
        LiveTranslation = Combine(l => l.DraftTranslation);
    }

    private string Combine(Func<Lane, string> pick)
    {
        var parts = new List<string>();
        foreach (var source in new[] { AudioSource.System, AudioSource.Microphone })
        {
            if (_lanes.TryGetValue(source, out var lane) && pick(lane).Length > 0)
            {
                parts.Add(_lanes.Count > 1 ? $"[{source.Label()}] {pick(lane)}" : pick(lane));
            }
        }
        return string.Join("\n", parts);
    }

    // ---- Translation results ----

    private void OnStreaming(Guid segmentId, string text, bool isFinal)
    {
        IsTranslating = true;
        if (isFinal)
        {
            if (_segmentsById.TryGetValue(segmentId, out var segment) && segment.State == TranslationState.Translating)
            {
                segment.TranslatedText = text;
            }
            return;
        }
        var lane = _lanes.Values.FirstOrDefault(l => l.DraftSegmentId == segmentId);
        if (lane != null && lane.Draft.Length > 0)
        {
            lane.DraftTranslation = text;
            RefreshLiveText();
        }
    }

    private void OnTranslationCompleted(TranslationQueueResult result)
    {
        IsTranslating = _queue.IsProcessing;
        if (!result.IsFinal)
        {
            var lane = _lanes.Values.FirstOrDefault(l => l.DraftSegmentId == result.SegmentId);
            if (lane != null && result.Success && lane.Draft.Length > 0)
            {
                lane.DraftTranslation = TextUtils.CleanTranslationOutput(result.TranslatedText);
                RefreshLiveText();
            }
            return;
        }
        if (!_segmentsById.TryGetValue(result.SegmentId, out var segment))
        {
            return;
        }
        if (!result.Success)
        {
            segment.State = TranslationState.Failed;
            segment.TranslatedText = result.TranslatedText;
            segment.LatencyMs = result.LatencyMs;
            return;
        }
        var translation = TextUtils.CleanTranslationOutput(result.TranslatedText);
        segment.TranslatedText = translation;
        segment.State = TranslationState.Translated;
        segment.LatencyMs = result.LatencyMs;
        LastLatencyMs = result.LatencyMs;
        IsOllamaConnected = true;
        Transcript.UpdateTranslation(segment.Id, translation);

        var entry = new TranslationEntry(segment.Id, segment.SourceText, translation, Settings.TargetLanguage.DisplayName(), segment.Timestamp, result.LatencyMs, segment.Source);
        _context.Add(entry);
        while (_context.Count > Math.Max(Settings.MaxContextEntries, 1) * 2)
        {
            _context.RemoveAt(0);
        }
        if (Settings.HistoryEnabled && _history != null)
        {
            var store = _history;
            var prune = ++_historyWrites % 50 == 0;
            var (days, max) = (Settings.HistoryRetentionDays, Settings.HistoryMaxEntries);
            _ = Task.Run(() =>
            {
                try
                {
                    store.Log(entry);
                    if (prune) store.Prune(days, max);
                }
                catch (Exception ex)
                {
                    Log.Warning(ex, "[History] write failed");
                }
            });
        }
    }

    // ---- Clear / copy / export ----

    public void Clear()
    {
        if (IsCapturing)
        {
            return;
        }
        _queue.CancelAll();
        Segments.Clear();
        _segmentsById.Clear();
        _pendingWhilePaused.Clear();
        _context.Clear();
        Transcript.Clear();
        LiveSourceText = "";
        LiveTranslation = "";
        LastLatencyMs = 0;
        Notice = null;
        OnPropertyChanged(nameof(HasTranscript));
    }

    /// <summary>Latest translation (overlay copy) or the whole visible transcript.</summary>
    public string LatestTranslationText => Segments.LastOrDefault(s => s.HasTranslation)?.TranslatedText ?? LiveTranslation;

    public string TranscriptText => string.Join("\n\n", Transcript.Entries.Select(e =>
        e.TranslatedText.Length > 0 ? $"[{e.Source.Label()}] {e.SourceText}\n{e.TranslatedText}" : $"[{e.Source.Label()}] {e.SourceText}"));

    public (string Content, string FileName)? BuildExport(ExportFormat format)
    {
        if (Transcript.Entries.Count == 0)
        {
            return null;
        }
        var sources = Settings.CaptureMicrophone && Settings.MicrophoneSourceLanguage is { } mic && mic.IsoCode() != Settings.SourceLanguage.IsoCode()
            ? $"{Settings.SourceLanguage.IsoCode().ToUpperInvariant()}+{mic.IsoCode().ToUpperInvariant()}"
            : Settings.SourceLanguage.IsoCode().ToUpperInvariant();
        var content = SessionExporter.Export(Transcript, format, sources, Settings.TargetLanguage.IsoCode().ToUpperInvariant());
        var name = SessionExporter.SuggestedFileName(format, Transcript.StartedAt ?? DateTime.Now);
        return (content, name);
    }

    public void ShowInfo(string message) => Notice = AppNotice.Info(message);

    // ---- Settings & language switching ----

    /// <summary>Change one channel's recognition language live; only that channel restarts.</summary>
    public async Task SetSourceLanguageAsync(SourceLanguage? language, AudioSource source)
    {
        var updated = Settings.Clone();
        if (source == AudioSource.System)
        {
            if (language == null) return;
            updated.SourceLanguage = language.Value;
        }
        else
        {
            updated.MicrophoneSourceLanguage = language;
        }
        await UpdateSettingsAsync(updated);
    }

    public Task SetTargetLanguageAsync(TargetLanguage language)
    {
        var updated = Settings.Clone();
        updated.TargetLanguage = language;
        return UpdateSettingsAsync(updated);
    }

    /// <summary>Apply new settings: reconfigure Ollama, restart only the channels whose inputs changed, persist.</summary>
    public async Task UpdateSettingsAsync(AppSettings updated)
    {
        var previous = Settings;
        Settings = updated;
        SaveSettings();
        ApplyEndpoint();

        if (updated.HistoryEnabled && _history == null)
        {
            OpenHistory();
        }
        if (updated.TargetLanguage != previous.TargetLanguage)
        {
            _context.Clear();
        }

        if (IsCapturing)
        {
            var whisperChanged = updated.WhisperModel != previous.WhisperModel;
            foreach (var source in new[] { AudioSource.System, AudioSource.Microphone })
            {
                var wasEnabled = source == AudioSource.System ? previous.CaptureSystemAudio : previous.CaptureMicrophone;
                var isEnabled = source == AudioSource.System ? updated.CaptureSystemAudio : updated.CaptureMicrophone;
                var languageChanged = updated.LanguageFor(source) != previous.LanguageFor(source);
                var deviceChanged = source == AudioSource.Microphone && updated.MicrophoneDeviceId != previous.MicrophoneDeviceId;
                var active = _lanes.ContainsKey(source);

                if (active && (!isEnabled || languageChanged || deviceChanged || whisperChanged))
                {
                    if (_lanes.TryGetValue(source, out var lane) && lane.Draft.Length > 0)
                    {
                        FinalizeDraftAsSegment(lane, source);
                        lane.Draft = "";
                    }
                    StopLane(source, flush: true);
                    _stall.ResetLane(source);
                }
                if (isEnabled && !_lanes.ContainsKey(source) && (languageChanged || deviceChanged || whisperChanged || !wasEnabled || active))
                {
                    var model = WhisperModelCatalog.Entry(updated.WhisperModel) ?? WhisperModelCatalog.Small;
                    if (WhisperStore.IsDownloaded(model))
                    {
                        try
                        {
                            StartLane(source, WhisperStore.PathFor(model));
                        }
                        catch (Exception ex)
                        {
                            Notice = AppNotice.Error($"Could not restart {source.Label()}: {ex.Message}", NoticeAction.RetryCapture);
                        }
                    }
                    else
                    {
                        Notice = AppNotice.Error($"The speech model '{model.Name}' is not downloaded yet.", NoticeAction.DownloadWhisperModel);
                    }
                }
            }
            CaptureSources = _lanes.Keys.OrderBy(s => s).ToList();
            RefreshLiveText();
        }

        if (updated.OllamaModel != previous.OllamaModel || updated.OllamaUrl != previous.OllamaUrl)
        {
            ModelState = ModelState.Unknown;
            await RefreshModelStateAsync();
        }

        OnPropertyChanged(nameof(Settings));
        OnPropertyChanged(nameof(LanguageLabelText));
        OnPropertyChanged(nameof(ListeningText));
        OnPropertyChanged(nameof(ModelName));
        OnPropertyChanged(nameof(LatencyText));
        OnPropertyChanged(nameof(ShowMicMeter));
        SettingsChanged?.Invoke(updated);
    }

    private void ApplyEndpoint()
    {
        Ollama.Configure(OllamaClientOptions.From(Settings));
        if (Settings.ValidatedOllamaEndpoint is { } endpoint)
        {
            Guardian.UseEndpoint(endpoint);
        }
    }

    public void SaveSettings()
    {
        try
        {
            Settings.Save(AppPaths.SettingsFile);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "[Settings] save failed");
            Notice = AppNotice.Error("Settings could not be saved: " + ex.Message);
        }
    }

    private void OpenHistory()
    {
        try
        {
            _history = new HistoryStore(AppPaths.HistoryDatabase);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "[History] open failed");
            Notice = AppNotice.Error("History database could not be opened: " + ex.Message);
        }
    }

    public HistoryStore? HistoryStoreOrNull => _history ??= File.Exists(AppPaths.HistoryDatabase) || Settings.HistoryEnabled ? TryOpenHistory() : null;

    private HistoryStore? TryOpenHistory()
    {
        try { return new HistoryStore(AppPaths.HistoryDatabase); } catch (Exception) { return null; }
    }

    // ---- Notices ----

    public void DismissNotice() => Notice = null;

    private void ScheduleAutoDismiss(AppNotice notice)
    {
        _noticeTimer?.Dispose();
        _noticeTimer = new Timer(_ => Ui(() => { if (Notice?.Id == notice.Id) Notice = null; }), null, 8000, Timeout.Infinite);
    }

    protected override void OnPropertyChanged(string? name = null)
    {
        base.OnPropertyChanged(name);
        if (name == nameof(Notice) && Notice is { AutoDismiss: true } notice)
        {
            ScheduleAutoDismiss(notice);
        }
    }

    public async Task PerformAsync(NoticeAction action)
    {
        switch (action)
        {
            case NoticeAction.OpenMicrophoneSettings:
                OpenUrl("ms-settings:privacy-microphone");
                break;
            case NoticeAction.OpenSoundSettings:
                OpenUrl("ms-settings:sound");
                break;
            case NoticeAction.OpenOllamaDownloadPage:
                OpenUrl(OllamaGuardian.DownloadPage.ToString());
                break;
            case NoticeAction.OpenAppSettings:
                Notice = null;
                OpenSettingsRequested?.Invoke();
                break;
            case NoticeAction.RetryCapture:
                Notice = null;
                if (IsCapturing) await StopAsync();
                await StartAsync();
                break;
            case NoticeAction.StartOllama:
                await StartOllamaFromIndicatorAsync();
                break;
            case NoticeAction.DownloadModel:
                await DownloadTranslationModelAsync(Settings.OllamaModel);
                break;
            case NoticeAction.DownloadWhisperModel:
                await DownloadWhisperModelAsync(Settings.WhisperModel);
                break;
        }
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[VM] Could not open {Url}", url);
        }
    }

    public async Task StartOllamaFromIndicatorAsync()
    {
        Notice = AppNotice.Info("Starting Ollama…", autoDismiss: false);
        try
        {
            await Guardian.EnsureRunningAsync();
            IsOllamaConnected = await Ollama.CheckHealthAsync();
            Notice = AppNotice.Info("Ollama is running.");
            await LoadModelAsync();
        }
        catch (Exception ex)
        {
            var actions = Guardian.Status == OllamaStatus.NotInstalled
                ? new[] { NoticeAction.OpenOllamaDownloadPage, NoticeAction.OpenAppSettings }
                : new[] { NoticeAction.StartOllama, NoticeAction.OpenAppSettings };
            Notice = AppNotice.Error(ex.Message, actions);
        }
    }

    public async Task DownloadTranslationModelAsync(string modelName)
    {
        if (ModelManager.IsPulling)
        {
            return;
        }
        Notice = AppNotice.Info($"Downloading {modelName}… (see Settings for progress)", autoDismiss: false);
        try
        {
            await ModelManager.PullAsync(modelName);
            Notice = AppNotice.Info($"{modelName} is ready.");
            await LoadModelAsync();
        }
        catch (OperationCanceledException)
        {
            Notice = AppNotice.Info("Download cancelled.");
        }
        catch (Exception ex)
        {
            Notice = AppNotice.Error("Download failed: " + ex.Message, NoticeAction.DownloadModel, NoticeAction.OpenAppSettings);
        }
    }

    public bool IsDownloadingWhisper => _downloadCts != null;

    public async Task DownloadWhisperModelAsync(string modelName)
    {
        var model = WhisperModelCatalog.Entry(modelName) ?? WhisperModelCatalog.Small;
        if (_downloadCts != null)
        {
            return;
        }
        _downloadCts = new CancellationTokenSource();
        OnPropertyChanged(nameof(IsDownloadingWhisper));
        var lastPercent = -1;
        var progress = new Progress<DownloadProgress>(p => Ui(() =>
        {
            var percent = (int)(p.Fraction * 100);
            if (percent != lastPercent)
            {
                lastPercent = percent;
                Notice = new AppNotice(NoticeSeverity.Info, $"Downloading speech model '{model.Name}' — {percent}% ({ByteFormat.Format(p.CompletedBytes)} / {ByteFormat.Format(p.TotalBytes)})", Array.Empty<NoticeAction>(), false);
            }
        }));
        try
        {
            await WhisperStore.DownloadAsync(model, progress, _downloadCts.Token);
            Notice = AppNotice.Info($"Speech model '{model.Name}' is ready. Press start to begin.");
        }
        catch (OperationCanceledException)
        {
            Notice = AppNotice.Info("Download cancelled.");
        }
        catch (Exception ex)
        {
            Notice = AppNotice.Error("Speech model download failed: " + ex.Message, NoticeAction.DownloadWhisperModel);
        }
        finally
        {
            _downloadCts.Dispose();
            _downloadCts = null;
            OnPropertyChanged(nameof(IsDownloadingWhisper));
        }
    }

    public void CancelWhisperDownload() => _downloadCts?.Cancel();

    // ---- Ollama patrol ----

    public void StartOllamaPatrol(int intervalSeconds = 10)
    {
        StopOllamaPatrol();
        _recovery = new OllamaRecoveryController();
        _patrolTimer = new Timer(_ => _ = PatrolAsync(), null, TimeSpan.FromSeconds(intervalSeconds), TimeSpan.FromSeconds(intervalSeconds));
    }

    public void StopOllamaPatrol()
    {
        _patrolTimer?.Dispose();
        _patrolTimer = null;
    }

    private async Task PatrolAsync()
    {
        if (_patrolBusy || _disposed)
        {
            return;
        }
        _patrolBusy = true;
        try
        {
            var outcome = await ProbeAsync();
            var step = _recovery.Next(outcome);
            Ui(() => IsOllamaConnected = outcome != OllamaRecoveryController.ProbeOutcome.ServiceUnreachable);
            switch (step.Kind)
            {
                case OllamaRecoveryController.StepKind.RestartService:
                    Log.Warning("[Patrol] Ollama unreachable — restart attempt {Attempt} in {Delay}s", step.Attempt, step.Delay.TotalSeconds);
                    Ui(() => Notice = AppNotice.Warning($"Ollama stopped responding — restarting (attempt {step.Attempt}/{OllamaRecoveryController.MaxRestartAttempts}) in {step.Delay.TotalSeconds:0}s…", autoDismiss: false));
                    await Task.Delay(step.Delay);
                    if (_disposed || !IsCapturing) return;
                    try
                    {
                        await Guardian.StopServiceAsync();
                        await Guardian.EnsureRunningAsync();
                        await ReloadModelThrottledAsync(force: true);
                    }
                    catch (Exception ex)
                    {
                        Log.Warning("[Patrol] restart failed: {Message}", ex.Message);
                    }
                    break;
                case OllamaRecoveryController.StepKind.ReloadModel:
                    await ReloadModelThrottledAsync(force: false);
                    break;
                case OllamaRecoveryController.StepKind.AnnounceRecovered:
                    Ui(() => Notice = AppNotice.Info("Ollama is back — translation resumed."));
                    break;
                case OllamaRecoveryController.StepKind.GiveUp:
                    Ui(() => Notice = AppNotice.Error("Ollama could not be restarted after 3 attempts. Captions continue without translation.", NoticeAction.StartOllama, NoticeAction.OpenAppSettings));
                    break;
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Patrol] step failed");
        }
        finally
        {
            _patrolBusy = false;
        }
    }

    private async Task<OllamaRecoveryController.ProbeOutcome> ProbeAsync()
    {
        if (!await Ollama.CheckHealthAsync())
        {
            return OllamaRecoveryController.ProbeOutcome.ServiceUnreachable;
        }
        try
        {
            var loaded = await Ollama.GetLoadedModelsAsync();
            var isLoaded = OllamaClient.IsModelInstalled(Settings.OllamaModel, loaded);
            Ui(() =>
            {
                if (isLoaded && ModelState != ModelState.Loading) { ModelState = ModelState.Loaded; ModelStateDetail = "Model loaded in memory"; }
                else if (!isLoaded && ModelState == ModelState.Loaded) { ModelState = ModelState.NotLoaded; ModelStateDetail = "Model not loaded — reloading"; }
            });
            return isLoaded ? OllamaRecoveryController.ProbeOutcome.Healthy : OllamaRecoveryController.ProbeOutcome.ModelNotLoaded;
        }
        catch (Exception)
        {
            return OllamaRecoveryController.ProbeOutcome.Healthy; // /api/ps unsupported on old servers: treat as fine
        }
    }

    private async Task ReloadModelThrottledAsync(bool force)
    {
        if (!force && DateTime.UtcNow - _lastModelReload < TimeSpan.FromSeconds(30))
        {
            return;
        }
        _lastModelReload = DateTime.UtcNow;
        Ui(() => { ModelState = ModelState.Loading; ModelStateDetail = "Model is loading into memory…"; });
        try
        {
            await Ollama.LoadModelAsync(Settings.OllamaModel);
            Ui(() => { ModelState = ModelState.Loaded; ModelStateDetail = "Model loaded in memory"; });
        }
        catch (Exception ex)
        {
            Ui(() => { ModelState = ModelState.Failed; ModelStateDetail = "Model not loaded — " + ex.Message; });
        }
    }

    // ---- Misc ----

    private void UpdateElapsedText()
    {
        ElapsedText = CaptureState switch
        {
            CaptureState.Idle => "idle",
            CaptureState.Starting => "starting…",
            CaptureState.Stopping => "stopping…",
            _ => IsPaused ? "paused" : "rec " + LanguageLabel.Elapsed(DateTime.Now - (CaptureStartedAt ?? DateTime.Now)),
        };
    }

    /// <summary>App exit: stop capture, unload the model if asked, stop the Ollama LCT started.</summary>
    public async Task ShutdownAsync()
    {
        try
        {
            if (IsCapturing)
            {
                await StopAsync();
            }
            if (Settings.UnloadModelOnQuit && IsOllamaConnected)
            {
                try
                {
                    await Ollama.UnloadModelAsync(Settings.OllamaModel);
                }
                catch (Exception ex)
                {
                    Log.Information("[VM] Unload on quit skipped: {Message}", ex.Message);
                }
            }
            await Guardian.StopServiceAsync();
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[VM] shutdown error");
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopOllamaPatrol();
        _levelTimer?.Dispose();
        _clockTimer?.Dispose();
        _noticeTimer?.Dispose();
        foreach (var source in _lanes.Keys.ToList())
        {
            StopLane(source, flush: false);
        }
        _queue.Dispose();
    }
}
