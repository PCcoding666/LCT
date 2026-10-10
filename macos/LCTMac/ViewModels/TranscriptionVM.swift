import SwiftUI
import Combine

/// Coarse capture lifecycle. Drives the HUD status and the start/stop button,
/// and guards `start()`/`stop()` against re-entry while a transition is in
/// flight (cold model loads take seconds, during which every start request
/// must be ignored).
enum CaptureState: String, Equatable {
    case idle
    case starting
    case capturing
    case stopping
}

/// Whether the translation model is currently held in Ollama's memory.
/// Drives the HUD model indicator; kept in sync by prewarm, start/stop,
/// settings changes, and a slow poll while the app is idle.
enum ModelState: Equatable {
    case unknown
    case loading
    case loaded
    case notLoaded
    case failed(String)
}

/// Main transcription and translation view model
@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Published Properties

    /// All finalized and currently translating segments in the current session
    @Published var segments: [TranslationSegment] = []

    /// The current unfinalized live draft text from ASR
    @Published var liveSourceText: String = ""

    /// Streaming translation of the current draft (transient; not persisted)
    @Published var liveTranslation: String = ""

    /// Translation history for context
    @Published var translationHistory: [TranslationEntry] = []

    /// Capture lifecycle state; the single source of truth for start/stop UI.
    @Published var captureState: CaptureState = .idle

    /// Whether the translation model is held in Ollama's memory right now.
    @Published var modelState: ModelState = .unknown

    /// Is currently capturing audio (derived from `captureState`).
    var isCapturing: Bool { captureState == .capturing }

    /// Is currently translating
    @Published var isTranslating: Bool = false

    /// Is paused
    @Published var isPaused: Bool = false

    /// Audio level for visualization
    @Published var audioLevel: Float = 0

    /// Per-lane meter levels and which lanes are running (for the meter UI)
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var captureSources: [AudioSource] = []

    /// Microphone input device actually in use (nil when the mic lane is off)
    @Published var microphoneDeviceName: String?
    @Published var microphoneDeviceIsVirtual: Bool = false

    /// Current user-facing notice (info / warning / error with optional actions)
    @Published var notice: AppNotice?

    /// Last translation latency
    @Published var lastLatencyMs: Int = 0

    /// Ollama connection status
    @Published var isOllamaConnected: Bool = false

    /// When the current capture session started (nil when stopped)
    @Published var captureStartedAt: Date?

    /// Untrimmed record of the current session, the source for session
    /// exports. Independent of the trimmed on-screen cards and of the opt-in
    /// persistent history; survives stop() so a finished session stays
    /// exportable until the next start() or clear().
    @Published private(set) var sessionTranscript = SessionTranscript()

    // MARK: - Services

    private let audioCaptureService: AudioCaptureService
    private let ollamaService: OllamaService
    private let translationQueue: TranslationQueue
    private let speakerManager: SpeakerManager
    /// The selected speech recognition engine (SpeechAnalyzer on macOS 26+,
    /// legacy SFSpeechRecognizer below). Only touched through the protocol.
    private let speechEngine: any SpeechRecognitionEngine
    private let speechEngineKind: SpeechEngineKind
    private let caption: Caption
    /// One segmenter per capture lane — each lane's transcript evolves
    /// independently and must not be fed into a shared segmenter.
    private var captionSegmenters: [AudioSource: CaptionSegmenter] = [:]
    private let ollamaGuardian: OllamaGuardian
    private let historyService = HistoryService()
    /// Chip/memory of this Mac — decides whether the configured model can run
    /// locally at all (MLX builds need Apple Silicon).
    private let hardwareProfile: HardwareProfile
    /// Factory for the model downloader; tests substitute a stub-session manager.
    private let makeModelManager: (OllamaEndpoint) -> OllamaModelManager

    // MARK: - Settings

    @Published var settings: AppSettings

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    /// Active ASR task id per capture lane (mic / system each run their own task).
    private var activeTranscriptionTaskIds: [AudioSource: UUID] = [:]
    /// UI segment ids emitted for each lane's active ASR task, in emission order.
    /// Parallel to each lane's CaptionSegmenter committed segments so tail rollbacks align.
    private var activeTaskSegmentIds: [AudioSource: [UUID]] = [:]
    private var historyEntryIdsBySegmentId: [UUID: UUID] = [:]
    /// Stable per-lane ids for the volatile draft translation tasks, kept out of
    /// `segments` so their streaming/complete callbacks route to the live area.
    private var liveDraftSegmentIds: [AudioSource: UUID] = [:]
    /// Per-lane live draft text and draft translation, combined for display.
    private var liveDrafts: [AudioSource: String] = [:]
    private var liveTranslations: [AudioSource: String] = [:]
    /// Watchdog for lanes that hear audio but recognize nothing (typically a
    /// wrong recognition language); fed by `stallTimer` while capturing.
    private var stallDetector = RecognitionStallDetector()
    private var stallTimer: AnyCancellable?
    /// Slow poll that keeps `modelState` in sync with Ollama while idle.
    private var modelStateTimer: AnyCancellable?
    /// Identifies the mic-silence warning currently on screen so the recovery
    /// callback retracts exactly that notice and nothing else.
    private var micSilenceNoticeId: UUID?
    /// Identifies the on-device speech model download notice currently on
    /// screen, so the download-finished callback retracts exactly that one.
    private var modelDownloadNoticeId: UUID?
    /// The task pulling the translation model from the Download notice
    /// action; non-nil only while a download is in flight.
    private var modelDownloadTask: Task<Void, Never>?
    /// Capture-time Ollama patrol: restarts a dead service, re-warms an
    /// unloaded model. Runs only while capturing.
    private var ollamaPatrolTask: Task<Void, Never>?
    /// Identifies the patrol's "restarting…" warning so recovery retracts
    /// exactly that notice and nothing else.
    private var ollamaRecoveryNoticeId: UUID?
    /// Identifies the patrol's "could not be restarted" error so a later
    /// recovery retracts it.
    private var ollamaGaveUpNoticeId: UUID?
    /// Identifies the patrol's "reloading model…" info notice.
    private var modelReloadNoticeId: UUID?
    /// Identifies an error notice raised from `ollamaService.lastError`
    /// (e.g. "Ollama server is not running" from a failed translation). It
    /// describes the same outage the patrol handles, so the patrol may
    /// replace it with its restarting/recovered/gave-up notices.
    private var ollamaServiceErrorNoticeId: UUID?

    // MARK: - Initialization

    init(settings: AppSettings = .load(),
         ollamaService: OllamaService? = nil,
         ollamaGuardian: OllamaGuardian = .shared,
         hardwareProfile: HardwareProfile = .current(),
         makeModelManager: @escaping (OllamaEndpoint) -> OllamaModelManager = { OllamaModelManager(endpoint: $0) },
         audioCaptureService: AudioCaptureService? = nil,
         speechEngine: (any SpeechRecognitionEngine)? = nil) {
        let loadedSettings = settings
        self.settings = loadedSettings
        self.hardwareProfile = hardwareProfile
        self.makeModelManager = makeModelManager
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService(
            config: AudioCaptureConfig(
                captureSystemAudio: loadedSettings.captureSystemAudio,
                captureMicrophone: loadedSettings.captureMicrophone,
                microphoneDeviceUID: loadedSettings.microphoneDeviceUID
            )
        )
        self.ollamaService = ollamaService ?? OllamaService(settings: loadedSettings)
        self.ollamaGuardian = ollamaGuardian
        self.translationQueue = TranslationQueue(ollamaService: self.ollamaService)
        self.speakerManager = SpeakerManager()
        if let speechEngine {
            self.speechEngineKind = speechEngine.kind
            self.speechEngine = speechEngine
        } else {
            let engineKind = SpeechEngineSelection.engineKind(
                transcriberEngineAvailable: SpeechEngineAvailability.isTranscriberEngineAvailable
            )
            self.speechEngineKind = engineKind
            self.speechEngine = SpeechEngineFactory.makeEngine(kind: engineKind, language: loadedSettings.sourceLanguage)
        }
        appLog("[TranscriptionVM] Speech engine: \(speechEngineKind.rawValue)")
        self.caption = Caption.shared

        caption.maxContextEntries = loadedSettings.maxContextEntries

        setupBindings()

        if let persistenceError = AppSettings.consumeLastPersistenceError() {
            notice = .warning(persistenceError, autoDismiss: false)
        }

        // Probe Ollama on launch so the status indicator reflects reality
        // immediately, instead of showing the default "stopped" until first use.
        Task {
            await self.ollamaGuardian.checkStatus()
            isOllamaConnected = await self.ollamaService.checkHealth()
        }
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind audio level
        audioCaptureService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        // Bind per-lane meter levels + active lanes
        audioCaptureService.$systemLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$systemLevel)

        audioCaptureService.$micLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$micLevel)

        audioCaptureService.$activeSources
            .receive(on: DispatchQueue.main)
            .assign(to: &$captureSources)

        // Bind the mic input device actually in use (for the meter UI)
        audioCaptureService.$microphoneDeviceName
            .receive(on: DispatchQueue.main)
            .assign(to: &$microphoneDeviceName)

        audioCaptureService.$microphoneDeviceIsVirtual
            .receive(on: DispatchQueue.main)
            .assign(to: &$microphoneDeviceIsVirtual)

        // Bind translation queue state
        translationQueue.$isProcessing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTranslating)

        // Bind Ollama connection state
        ollamaService.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOllamaConnected)

        // Bind errors. These are runtime failures surfaced mid-session; offer a
        // retry since the user's intent was to keep capturing.
        audioCaptureService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.notice = .error(error, actions: [.retryCapture])
            }
            .store(in: &cancellables)

        ollamaService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                guard let self else { return }
                // While the patrol is restarting Ollama, its own notice already
                // explains the outage; failed translations must not replace it.
                if let id = self.ollamaRecoveryNoticeId, self.notice?.id == id {
                    appLog("[TranscriptionVM] Ollama error during recovery — keeping the restart notice")
                    return
                }
                let serviceErrorNotice = AppNotice.error(error, actions: [.retryCapture])
                self.ollamaServiceErrorNoticeId = serviceErrorNotice.id
                self.notice = serviceErrorNotice
            }
            .store(in: &cancellables)

        speechEngine.lastErrorPublisher
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.notice = .error(error, actions: [.retryCapture])
            }
            .store(in: &cancellables)

        // Handle speech recognition results
        speechEngine.onTranscription = { [weak self] result in
            self?.handleTranscriptionResult(result)
        }

        // The SpeechAnalyzer engine downloads on-device speech models on first
        // use; keep a non-auto-dismissing info notice up while that runs.
        speechEngine.onModelDownloadStatus = { [weak self] language in
            self?.handleModelDownloadStatus(language)
        }

        // Handle translation results
        translationQueue.onTranslationComplete = { [weak self] result in
            self?.handleTranslationResult(result)
        }

        translationQueue.onStreamingUpdate = { [weak self] segmentId, streamingText in
            guard let self = self else { return }

            if let lane = self.liveDraftSegmentIds.first(where: { $0.value == segmentId })?.key {
                self.liveTranslations[lane] = streamingText
                self.refreshLiveTranslation()
                return
            }

            if let idx = self.segments.firstIndex(where: { $0.id == segmentId }) {
                self.segments[idx].translatedText = streamingText
                self.segments[idx].state = .translating
            }
        }

        // Handle SCStream interruption (e.g., display disconnected, system error)
        audioCaptureService.onStreamInterrupted = { [weak self] error in
            guard let self = self else { return }
            appLog("[TranscriptionVM] ⚠️ Audio stream interrupted: \(error.localizedDescription)")
            // Stop speech recognition and translation queue since audio is gone
            Task { await self.speechEngine.stop() }
            self.translationQueue.cancelAll()
            self.captureState = .idle
            self.captureStartedAt = nil
            self.stopStallMonitoring()
            self.notice = .error("Audio capture interrupted: \(error.localizedDescription)", actions: [.retryCapture])
        }

        // Mic lane delivered only digital silence for a full session streak —
        // almost always the wrong input device (e.g. an idle virtual sound card).
        audioCaptureService.onMicrophoneSilenceDetected = { [weak self] in
            self?.handleMicrophoneSilence()
        }

        // Mic lane recovered after a silence warning — retract the warning.
        audioCaptureService.onMicrophoneAudioResumed = { [weak self] in
            self?.handleMicrophoneAudioResumed()
        }

        // The system-audio tap never delivered a callback — macOS withheld it
        // because LCT is not allowed to record system audio.
        audioCaptureService.onSystemAudioAuthorizationDenied = { [weak self] captureContinues in
            self?.handleSystemAudioAuthorizationDenied(captureContinues: captureContinues)
        }

        // While the app is foreground and idle, re-check whether the model is
        // still in memory — Ollama unloads it when keep_alive expires, and the
        // HUD indicator must keep up. During capture the translation requests
        // themselves keep the model loaded, so no polling is needed.
        modelStateTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.captureState == .idle, NSApp?.isActive == true else { return }
                Task { await self.refreshModelState() }
            }
    }

    // MARK: - Actions

    /// Warm the translation model right after launch so the first start()
    /// doesn't pay the cold-load cost. Local Ollama only, and only after
    /// onboarding completed. Failures are logged, never shown — start() has
    /// its own checks with actionable notices. Called from MainView's `.task`,
    /// not from init, so tests constructing view models never hit a real
    /// Ollama.
    func prepareModelOnLaunch() async {
        guard AppSettings.hasCompletedSetup else { return }
        guard settings.isLocalOllama, settings.validatedOllamaEndpoint != nil else { return }

        do {
            try await ollamaGuardian.ensureRunning()
            guard await ollamaService.checkHealth() else {
                modelState = .notLoaded
                appLog("[TranscriptionVM] prepareModelOnLaunch: Ollama not reachable")
                return
            }
            let availableModels = try await ollamaService.getAvailableModels()
            guard isModelInstalled(settings.ollamaModel, in: availableModels) else {
                modelState = .notLoaded
                appLog("[TranscriptionVM] prepareModelOnLaunch: model not installed")
                return
            }
            modelState = .loading
            let latencyMs = try await ollamaService.prewarmModel()
            modelState = .loaded
            appLog("[TranscriptionVM] ✅ Model prewarmed on launch in \(latencyMs)ms")
        } catch {
            modelState = .failed(error.localizedDescription)
            appLog("[TranscriptionVM] ⚠️ prepareModelOnLaunch failed: \(error.localizedDescription)")
        }
    }

    /// Re-read which models Ollama currently holds in memory and update
    /// `modelState`. A failed probe keeps the previous state — a temporarily
    /// unreachable server says nothing about the model.
    func refreshModelState() async {
        guard settings.validatedOllamaEndpoint != nil else {
            modelState = .unknown
            return
        }
        do {
            let names = try await ollamaService.loadedModels()
            modelState = isModelInstalled(settings.ollamaModel, in: names) ? .loaded : .notLoaded
        } catch {
            appLog("[TranscriptionVM] refreshModelState probe failed: \(error.localizedDescription)")
        }
    }

    /// Start capturing and translating. Ignored (with a log line) unless the
    /// capture state is idle, so concurrent start requests — button, menu,
    /// status bar, hotkey, notice actions — can never overlap.
    func start() async {
        appLog("[TranscriptionVM] ▶️ start() called")
        guard captureState == .idle else {
            appLog("[TranscriptionVM] ⏭ start() ignored — capture is \(captureState.rawValue)")
            return
        }
        captureState = .starting
        // Every early return and catch branch below must land back on .idle;
        // only the success path flips to .capturing first.
        defer {
            if captureState == .starting {
                captureState = .idle
            }
        }

        var micDeniedInDual = false

        do {
            notice = nil

            // Fail closed on an invalid or non-consented Ollama endpoint before
            // any service is started or request can be made.
            if let endpointError = settings.ollamaEndpointError {
                appLog("[TranscriptionVM] ❌ Invalid Ollama endpoint: \(endpointError)")
                notice = .error("Ollama configuration is invalid: \(endpointError)", actions: [.openAppSettings])
                return
            }

            // A model this Mac cannot run at all (MLX build on Intel) fails
            // here, before permissions, services, or any loading attempt.
            if settings.isLocalOllama,
               !ModelCatalog.isCompatible(modelName: settings.ollamaModel, with: hardwareProfile) {
                appLog("[TranscriptionVM] ❌ Model is incompatible with this Mac's chip")
                notice = .error(
                    "Model '\(settings.ollamaModel)' is an MLX model and needs Apple Silicon. Pick a GGUF model in Settings.",
                    actions: [.openAppSettings]
                )
                return
            }

            // Resolve which capture lanes to run. System audio needs no
            // permission (Core Audio process tap); only the microphone lane
            // needs a TCC grant. The screen-recording check happens later and
            // only if the tap fails and the lane falls back to ScreenCaptureKit.
            appLog("[TranscriptionVM] captureSystemAudio: \(settings.captureSystemAudio), captureMicrophone: \(settings.captureMicrophone)")

            var activeSources: [AudioSource] = []

            if settings.captureSystemAudio {
                activeSources.append(.system)
            }

            if settings.captureMicrophone {
                let micGranted = await AudioCaptureService.ensureMicrophonePermission()
                if micGranted {
                    activeSources.append(.microphone)
                } else if activeSources.isEmpty {
                    appLog("[TranscriptionVM] ❌ Microphone permission denied, no other source")
                    notice = .error(
                        "Microphone permission is required to capture audio.",
                        actions: [.openMicrophoneSettings, .retryCapture]
                    )
                    return
                } else {
                    // Dual was requested but mic denied → run system-only, tell the user
                    micDeniedInDual = true
                }
            }

            guard !activeSources.isEmpty else {
                notice = .error(
                    "Enable at least one audio source (system audio or microphone) in Settings.",
                    actions: [.openAppSettings]
                )
                return
            }

            // The legacy engine runs only one on-device recognition task per
            // process, so a dual-lane request degrades to system audio only.
            let (engineSources, droppedMicrophoneLane) = SpeechEngineSelection.effectiveSources(
                activeSources, for: speechEngineKind
            )
            if droppedMicrophoneLane {
                appLog("[TranscriptionVM] ⚠️ Dual-lane recognition needs macOS 26+ — dropping the microphone lane")
            }
            activeSources = engineSources
            appLog("[TranscriptionVM] Active sources: \(activeSources.map { $0.rawValue })")

            if settings.isLocalOllama {
                // Ensure local Ollama is running (will start it if needed).
                // ensureRunning() already proved the service answers, so no
                // separate health probe is needed — just reflect it in the UI.
                appLog("[TranscriptionVM] Ensuring local Ollama is running...")
                do {
                    try await ollamaGuardian.ensureRunning()
                    isOllamaConnected = true
                    appLog("[TranscriptionVM] ✅ Local Ollama is running")
                } catch let error as OllamaGuardianError {
                    appLog("[TranscriptionVM] ❌ Local Ollama error: \(error)")
                    notice = .error(error.localizedDescription, actions: [.startOllama])
                    return
                } catch {
                    appLog("[TranscriptionVM] ❌ Local Ollama error: \(error)")
                    notice = .error("Cannot start Ollama: \(error.localizedDescription)", actions: [.startOllama])
                    return
                }
            } else {
                appLog("[TranscriptionVM] Using remote Ollama at \(settings.ollamaURL); skipping local startup")

                // Remote Ollama gets no guardian, so probe it directly.
                appLog("[TranscriptionVM] Checking Ollama connection...")
                let isConnected = await ollamaService.checkHealth()
                appLog("[TranscriptionVM] Ollama connected: \(isConnected)")
                if !isConnected {
                    notice = .error(
                        "Cannot connect to remote Ollama at \(settings.ollamaURL). Check the address in Settings.",
                        actions: [.openAppSettings]
                    )
                    return
                }
            }

            do {
                let availableModels = try await ollamaService.getAvailableModels()
                guard isModelInstalled(settings.ollamaModel, in: availableModels) else {
                    if settings.isLocalOllama {
                        // Local Ollama can pull the model right from this notice.
                        notice = .error(
                            "Model '\(settings.ollamaModel)' is not installed.",
                            actions: [.downloadModel, .openAppSettings]
                        )
                    } else {
                        notice = .error(
                            "Model '\(settings.ollamaModel)' is not installed. Install it on the configured remote Ollama server.",
                            actions: [.openAppSettings]
                        )
                    }
                    return
                }
            } catch {
                notice = .error("Cannot list Ollama models: \(error.localizedDescription)", actions: [.retryCapture])
                return
            }

            // If the model is already in memory (launch prewarm, or a
            // previous session within keep_alive), skip the loading notice —
            // prewarm below is then a fast keep_alive refresh. Cold-loading
            // can take far longer than an auto-dismiss interval, so the
            // notice stays up until the load finishes.
            let loadedModelNames = (try? await ollamaService.loadedModels()) ?? []
            let modelAlreadyLoaded = isModelInstalled(settings.ollamaModel, in: loadedModelNames)
            modelState = modelAlreadyLoaded ? .loaded : .loading
            let loadingNotice = modelAlreadyLoaded ? nil : AppNotice(
                severity: .info,
                message: "Loading translation model \"\(settings.ollamaModel)\"… the first run can take up to 30 seconds.",
                autoDismiss: false
            )
            if let loadingNotice {
                notice = loadingNotice
            }
            do {
                let latencyMs = try await ollamaService.prewarmModel()
                appLog("[TranscriptionVM] ✅ Ollama model prewarmed in \(latencyMs)ms")
                modelState = .loaded
                // Clear only the loading notice; an error that arrived
                // meanwhile (e.g. from a service binding) must survive.
                if let loadingNotice, notice?.id == loadingNotice.id {
                    notice = nil
                }
            } catch let error as OllamaError {
                modelState = .notLoaded
                notice = .error("Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)", actions: [.retryCapture])
                return
            } catch {
                modelState = .notLoaded
                notice = .error("Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)", actions: [.retryCapture])
                return
            }

            // Update speech recognizer language
            appLog("[TranscriptionVM] Setting speech language: \(settings.sourceLanguage.displayName)")
            speechEngine.setLanguage(settings.sourceLanguage)

            // Start speech recognition — one independent lane per active source.
            // Both lanes use the same recognition language for now (per-lane
            // language selection is a separate feature).
            appLog("[TranscriptionVM] Starting speech recognition...")
            let laneLanguages = Dictionary(uniqueKeysWithValues: activeSources.map { ($0, settings.sourceLanguage) })
            try await speechEngine.start(sources: activeSources, languages: laneLanguages)
            appLog("[TranscriptionVM] ✅ Speech recognition started")

            // Connect audio capture to speech recognizer (buffers stay tagged per lane)
            let engine = self.speechEngine
            audioCaptureService.onAudioBuffer = { [weak engine] buffer, source in
                engine?.appendAudioBuffer(buffer, source: source)
            }
            audioCaptureService.onAudioData = nil

            // Start audio capture for the resolved sources
            if activeSources.contains(.system) && activeSources.contains(.microphone) {
                appLog("[TranscriptionVM] Starting dual capture (system audio + microphone)...")
                try await audioCaptureService.startDualCapture()
                appLog("[TranscriptionVM] ✅ Dual capture started")
            } else if activeSources == [.microphone] {
                appLog("[TranscriptionVM] Starting microphone-only capture...")
                try await audioCaptureService.startMicrophoneOnlyCapture()
                appLog("[TranscriptionVM] ✅ Microphone-only capture started")
            } else {
                appLog("[TranscriptionVM] Starting system audio capture...")
                try await audioCaptureService.startCapture()
                appLog("[TranscriptionVM] ✅ System audio capture started")
            }

            appLog("[TranscriptionVM] ✅ start() completed successfully")
            captureState = .capturing
            let sessionStartedAt = Date()
            captureStartedAt = sessionStartedAt
            sessionTranscript.begin(at: sessionStartedAt)
            startStallMonitoring()

            // Surface lane-degraded notices now that capture is running (earlier
            // notices were overwritten by the model-loading progress message).
            if micDeniedInDual {
                notice = AppNotice(
                    severity: .warning,
                    message: "No microphone permission — capturing system audio only.",
                    actions: [.openMicrophoneSettings]
                )
            } else if droppedMicrophoneLane, notice?.severity != .error {
                notice = .warning("Capturing system audio and the microphone at the same time needs macOS 26 or later — capturing system audio only.")
            }

            // The Core Audio tap failed and the system lane is running on
            // ScreenCaptureKit, which needs the screen-recording permission.
            // Sticky — this is the flaky path the user should know about.
            if audioCaptureService.systemAudioBackend == .screenCaptureKit,
               let tapFailure = audioCaptureService.systemAudioTapFailure,
               notice?.severity != .error {
                notice = AppNotice(
                    severity: .warning,
                    message: "System audio capture fell back to screen recording mode (Core Audio tap failed: \(tapFailure)).",
                    autoDismiss: false
                )
            }

            // A virtual sound card (BlackHole & co.) carries no microphone
            // signal — tell the user right away instead of waiting for the
            // silence watchdog.
            if activeSources.contains(.microphone),
               let micDevice = audioCaptureService.activeMicrophoneDevice,
               micDevice.isVirtual,
               notice?.severity != .error {
                notice = AppNotice(
                    severity: .warning,
                    message: "Microphone input is \"\(micDevice.name)\", a virtual device with no microphone signal. Pick your real microphone in Settings.",
                    actions: [.openAppSettings]
                )
            }

            // Patrol local Ollama while capturing: restart a dead service,
            // re-warm a model Ollama dropped from memory.
            if settings.isLocalOllama {
                startOllamaPatrol()
            }

        } catch let error as SpeechAnalyzerError {
            switch error {
            case .notAuthorized:
                notice = .error(
                    "Speech recognition permission is required.",
                    actions: [.openSpeechRecognitionSettings]
                )
            case .recognizerUnavailable:
                notice = .error(
                    "Speech recognition is unavailable for \(settings.sourceLanguage.displayName). Try another language.",
                    actions: [.openAppSettings]
                )
            case .onDeviceRecognitionUnavailable:
                notice = .error(
                    "On-device speech recognition is not available for \(settings.sourceLanguage.displayName). Download its on-device speech model in System Settings, or choose another language.",
                    actions: [.openAppSettings]
                )
            case .audioSessionFailed:
                notice = .error("Failed to configure audio session.", actions: [.retryCapture])
            }
        } catch let error as AudioCaptureError {
            switch error {
            case .noPermission:
                notice = .error(
                    "Screen recording permission is required to capture system audio.",
                    actions: [.openScreenRecordingSettings]
                )
            case .noMicrophonePermission:
                notice = .error(
                    "Microphone permission is required to capture audio.",
                    actions: [.openMicrophoneSettings, .retryCapture]
                )
            case .noDisplaysAvailable:
                notice = .error("No displays available for audio capture.")
            case .captureSetupFailed(let message):
                notice = .error("Capture setup failed: \(message)", actions: [.retryCapture])
            case .audioProcessingFailed(let message):
                notice = .error("Audio processing failed: \(message)", actions: [.retryCapture])
            case .streamInterrupted(let message):
                notice = .error("Audio stream interrupted: \(message)", actions: [.retryCapture])
            }
        } catch {
            notice = .error(error.localizedDescription, actions: [.retryCapture])
        }
    }

    // MARK: - Notice Handling

    /// The SpeechAnalyzer engine started (non-nil) or finished (nil)
    /// downloading an on-device speech model. Downloads can take minutes, so
    /// the notice must not auto-dismiss; a live error outranks it.
    private func handleModelDownloadStatus(_ language: SourceLanguage?) {
        if let language {
            guard notice?.severity != .error else { return }
            let downloadNotice = AppNotice(
                severity: .info,
                message: "Downloading the on-device speech model for \(language.displayName)…",
                autoDismiss: false
            )
            modelDownloadNoticeId = downloadNotice.id
            notice = downloadNotice
        } else {
            if let id = modelDownloadNoticeId, notice?.id == id {
                notice = nil
            }
            modelDownloadNoticeId = nil
        }
    }

    /// The mic lane produced nothing but digital silence for 6 straight
    /// seconds — almost always a wrong or idle input device (e.g. BlackHole).
    private func handleMicrophoneSilence() {
        // A live error (permission lost, stream interrupted) outranks this warning.
        guard notice?.severity != .error else { return }
        let deviceName = audioCaptureService.activeMicrophoneDevice?.name ?? "unknown"
        appLog("[TranscriptionVM] ⚠️ Microphone lane silent for 6s (device: \(deviceName))")
        let silenceNotice = AppNotice(
            severity: .warning,
            message: "Microphone \"\(deviceName)\" is sending no audio. If it's a virtual device (e.g. BlackHole), pick your real microphone in Settings.",
            actions: [.openAppSettings]
        )
        micSilenceNoticeId = silenceNotice.id
        notice = silenceNotice
    }

    /// The mic lane delivered continuous audible RMS after a silence streak —
    /// retract the silence warning, but only if it's still on screen (never
    /// clobber a newer notice).
    private func handleMicrophoneAudioResumed() {
        appLog("[TranscriptionVM] ✅ Microphone lane is sending audio again")
        if let id = micSilenceNoticeId, notice?.id == id {
            notice = nil
        }
        micSilenceNoticeId = nil
    }

    /// The system-audio tap delivered no IO callback at all — macOS silently
    /// starves an unauthorized tap, so LCT is not allowed to record system
    /// audio. The service has already stopped the tap (no ScreenCaptureKit
    /// fallback); when the system lane was the whole session, wind capture
    /// down to idle, otherwise the microphone lane just keeps going.
    private func handleSystemAudioAuthorizationDenied(captureContinues: Bool) {
        appLog("[TranscriptionVM] ⚠️ System audio recording not authorized — lane stopped (capture continues: \(captureContinues))")
        if !captureContinues {
            Task { await self.speechEngine.stop() }
            translationQueue.cancelAll()
            stopStallMonitoring()
            stopOllamaPatrol()
            captureState = .idle
            captureStartedAt = nil
        }
        // A live error (permission lost, stream interrupted) outranks this one.
        guard notice?.severity != .error else { return }
        notice = .error(
            "LCT isn't allowed to record system audio. In System Settings → Privacy & Security → Screen & System Audio Recording, turn on LCT under \"System Audio Recording Only\", then start again.",
            actions: [.openSystemAudioSettings]
        )
    }

    // MARK: - Recognition Stall Detection

    /// Feed the stall watchdog with meter levels twice a second while capturing.
    private func startStallMonitoring() {
        stallDetector.reset()
        stallTimer?.cancel()
        stallTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkRecognitionStall()
            }
    }

    private func stopStallMonitoring() {
        stallTimer?.cancel()
        stallTimer = nil
        stallDetector.reset()
    }

    private func checkRecognitionStall() {
        let now = Date()
        for source in captureSources {
            let level = source == .microphone ? micLevel : systemLevel
            if stallDetector.process(level: level, for: source, at: now) {
                handleRecognitionStall(source: source)
            }
        }
    }

    /// A lane heard real audio for 8+ accumulated seconds without a single
    /// recognition result — the recognition language is the prime suspect.
    private func handleRecognitionStall(source: AudioSource) {
        // A live error (permission lost, stream interrupted) outranks this warning.
        guard notice?.severity != .error else { return }
        appLog("[TranscriptionVM] ⚠️ [\(source.rawValue)] lane audible for 8s+ but no recognition results")
        notice = AppNotice(
            severity: .warning,
            message: "Hearing audio on \(source.label) but recognizing nothing. Is the recognition language (\(settings.sourceLanguage.displayName)) right?",
            actions: [.openAppSettings]
        )
    }

    // MARK: - Ollama Patrol (capture-time recovery)

    /// While capturing, probe local Ollama every `interval` seconds: restart
    /// a service that stopped answering (backoff 10s → 20s → 40s, at most 3
    /// attempts) and re-warm the translation model when Ollama dropped it
    /// from memory. The decision logic lives in OllamaRecoveryController;
    /// this loop only probes and executes.
    func startOllamaPatrol(interval: TimeInterval = 10, backoffBase: TimeInterval = 10) {
        stopOllamaPatrol()
        ollamaPatrolTask = Task { [weak self] in
            var controller = OllamaRecoveryController(baseBackoff: backoffBase)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.captureState == .capturing else { break }
                await self.runOllamaPatrolStep(controller: &controller)
            }
        }
    }

    func stopOllamaPatrol() {
        ollamaPatrolTask?.cancel()
        ollamaPatrolTask = nil
        // Retract the patrol's in-progress notices so they don't linger after
        // the session ends; a give-up error stays — it is still actionable.
        retractOllamaRecoveryNotice()
        if let id = modelReloadNoticeId, notice?.id == id {
            notice = nil
        }
        modelReloadNoticeId = nil
    }

    private func runOllamaPatrolStep(controller: inout OllamaRecoveryController) async {
        let outcome = await probeOllamaHealth()
        guard !Task.isCancelled, captureState == .capturing else { return }

        switch controller.step(for: outcome) {
        case .probeAgain:
            break
        case .restartService(let delay, let attempt):
            showOllamaRecoveryNotice()
            appLog("[TranscriptionVM] ⚠️ Ollama not responding — restart attempt \(attempt) in \(Int(delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, captureState == .capturing else { return }
            do {
                try await ollamaGuardian.ensureRunning()
                appLog("[TranscriptionVM] ✅ Ollama restart attempt \(attempt) succeeded")
            } catch {
                appLog("[TranscriptionVM] ⚠️ Ollama restart attempt \(attempt) failed: \(error.localizedDescription)")
            }
        case .reloadModel:
            await reloadTranslationModel()
        case .announceRecovered:
            appLog("[TranscriptionVM] ✅ Ollama is healthy again")
            retractOllamaRecoveryNotice()
            if let id = ollamaGaveUpNoticeId, notice?.id == id {
                notice = nil
            }
            ollamaGaveUpNoticeId = nil
            if notice?.severity != .error || isOllamaServiceErrorNotice {
                ollamaServiceErrorNoticeId = nil
                notice = .info("Ollama is back — translation resumed.")
            }
        case .giveUp:
            appLog("[TranscriptionVM] ❌ Ollama could not be restarted after \(OllamaRecoveryController.maxRestartAttempts) attempts")
            retractOllamaRecoveryNotice()
            if notice?.severity != .error || isOllamaServiceErrorNotice {
                ollamaServiceErrorNoticeId = nil
                let giveUpNotice = AppNotice(
                    severity: .error,
                    message: "Ollama could not be restarted.",
                    actions: [.startOllama]
                )
                ollamaGaveUpNoticeId = giveUpNotice.id
                notice = giveUpNotice
            }
        }
    }

    private func probeOllamaHealth() async -> OllamaRecoveryController.ProbeOutcome {
        guard await ollamaGuardian.checkServiceStatus() else {
            return .serviceUnreachable
        }
        do {
            let names = try await ollamaService.loadedModels()
            return isModelInstalled(settings.ollamaModel, in: names) ? .healthy : .modelNotLoaded
        } catch {
            // /api/ps failed while /api/tags answered — a flaky read says
            // nothing reliable about the model; don't act on it.
            appLog("[TranscriptionVM] Ollama patrol: loadedModels probe failed: \(error.localizedDescription)")
            return .healthy
        }
    }

    /// Ollama dropped the translation model from memory (crash restart,
    /// memory pressure) — prewarm it again so translations resume.
    private func reloadTranslationModel() async {
        guard !Task.isCancelled, captureState == .capturing else { return }
        var reloadNotice: AppNotice?
        if notice?.severity != .error {
            let n = AppNotice(severity: .info, message: "Reloading translation model…", autoDismiss: false)
            modelReloadNoticeId = n.id
            reloadNotice = n
            notice = n
        }
        modelState = .loading
        do {
            _ = try await ollamaService.prewarmModel()
            modelState = .loaded
            appLog("[TranscriptionVM] ✅ Translation model reloaded")
        } catch {
            modelState = .notLoaded
            appLog("[TranscriptionVM] ⚠️ Translation model reload failed: \(error.localizedDescription)")
        }
        if let reloadNotice, modelReloadNoticeId == reloadNotice.id, notice?.id == reloadNotice.id {
            notice = nil
        }
        modelReloadNoticeId = nil
    }

    /// The patrol's non-auto-dismissing warning while a restart is in flight.
    /// Never clobbers a live error notice.
    /// Whether the notice on screen is an Ollama service error (from
    /// `ollamaService.lastError`), which the patrol is allowed to replace.
    private var isOllamaServiceErrorNotice: Bool {
        guard let id = ollamaServiceErrorNoticeId else { return false }
        return notice?.id == id
    }

    private func showOllamaRecoveryNotice() {
        if let id = ollamaRecoveryNoticeId, notice?.id == id { return }
        guard notice?.severity != .error || isOllamaServiceErrorNotice else { return }
        ollamaServiceErrorNoticeId = nil
        let n = AppNotice(
            severity: .warning,
            message: "Ollama stopped responding — restarting…",
            autoDismiss: false
        )
        ollamaRecoveryNoticeId = n.id
        notice = n
    }

    private func retractOllamaRecoveryNotice() {
        if let id = ollamaRecoveryNoticeId, notice?.id == id {
            notice = nil
        }
        ollamaRecoveryNoticeId = nil
    }

    /// Status-light click: bring Ollama up, surfacing failures as an
    /// actionable error notice instead of swallowing them.
    func startOllamaFromIndicator() {
        Task {
            do {
                try await ollamaGuardian.ensureRunning()
            } catch {
                appLog("[TranscriptionVM] ⚠️ startOllamaFromIndicator failed: \(error.localizedDescription)")
                notice = .error("Could not start Ollama: \(error.localizedDescription)", actions: [.startOllama])
            }
        }
    }

    /// Dismiss the current notice.
    func dismissNotice() {
        notice = nil
    }

    /// Perform a notice's remediation action. `.openAppSettings` is handled by
    /// the view (it owns the settings sheet) and is a no-op here.
    func perform(_ action: NoticeAction) {
        switch action {
        case .openScreenRecordingSettings:
            AudioCaptureService.openScreenRecordingSettings()
        case .openMicrophoneSettings:
            AudioCaptureService.openMicrophoneSettings()
        case .openSpeechRecognitionSettings:
            AudioCaptureService.openSpeechRecognitionSettings()
        case .openSystemAudioSettings:
            AudioCaptureService.openSystemAudioSettings()
        case .startOllama:
            notice = .info("Starting Ollama…")
            Task {
                do {
                    try await ollamaGuardian.ensureRunning()
                    await start()
                } catch {
                    notice = .error("Could not start Ollama: \(error.localizedDescription)")
                }
            }
        case .retryCapture:
            notice = nil
            Task { await start() }
        case .downloadModel:
            guard captureState == .idle, modelDownloadTask == nil else { return }
            modelDownloadTask = Task {
                await downloadSelectedModel()
                modelDownloadTask = nil
            }
        case .openAppSettings:
            break // handled by the view
        }
    }

    /// Pull the configured model into local Ollama, driven by the Download
    /// notice action. Progress lives in a non-auto-dismissing info notice; a
    /// successful download restarts capture automatically.
    private func downloadSelectedModel() async {
        let modelName = settings.ollamaModel
        guard let endpoint = settings.validatedOllamaEndpoint, endpoint.isLoopback else {
            notice = .error("Model downloads need a local Ollama server.", actions: [.openAppSettings])
            return
        }

        let manager = makeModelManager(endpoint)
        let progressNotice = AppNotice(
            severity: .info,
            message: "Downloading \(modelName)…",
            autoDismiss: false
        )
        notice = progressNotice

        let progressUpdates = manager.$pullProgress
            .combineLatest(manager.$pullCompletedBytes, manager.$pullTotalBytes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress, completed, total in
                guard let self, self.notice?.id == progressNotice.id else { return }
                var message = "Downloading \(modelName)… \(Int((progress * 100).rounded()))%"
                if total > 0 {
                    message += " (\(ByteFormatting.string(completed)) / \(ByteFormatting.string(total)))"
                }
                self.notice?.message = message
            }
        defer { progressUpdates.cancel() }

        do {
            try await manager.pullModel(modelName)
            retractOllamaDownloadNotice(progressNotice)
            notice = .info("Model \(modelName) downloaded — starting capture…")
            await start()
        } catch is CancellationError {
            retractOllamaDownloadNotice(progressNotice)
        } catch {
            retractOllamaDownloadNotice(progressNotice)
            appLog("[TranscriptionVM] ❌ Model download failed: \(error.localizedDescription)")
            // The Download button on this notice retries the pull.
            notice = .error(
                "Download of '\(modelName)' failed: \(error.localizedDescription)",
                actions: [.downloadModel, .openAppSettings]
            )
        }
    }

    private func retractOllamaDownloadNotice(_ progressNotice: AppNotice) {
        if notice?.id == progressNotice.id {
            notice = nil
        }
    }

    /// Single entry point for start/stop requests from the main button, the
    /// menu, the status bar, and the global hotkey. Requests arriving while a
    /// transition is in flight are ignored so `start()` never overlaps itself.
    func toggleCapture() async {
        switch captureState {
        case .idle:
            await start()
        case .capturing:
            await stop()
        case .starting, .stopping:
            appLog("[TranscriptionVM] ⏭ toggleCapture() ignored — capture is \(captureState.rawValue)")
        }
    }

    /// Stop capturing. Ignored (with a log line) unless capturing — a stop
    /// request during startup must not tear down a half-started session.
    func stop() async {
        guard captureState == .capturing else {
            appLog("[TranscriptionVM] ⏭ stop() ignored — capture is \(captureState.rawValue)")
            return
        }
        captureState = .stopping
        captureStartedAt = nil
        stopStallMonitoring()
        stopOllamaPatrol()
        micSilenceNoticeId = nil
        modelDownloadNoticeId = nil
        await audioCaptureService.stopCapture()
        translationQueue.cancelAll()
        await speechEngine.stop()
        liveDrafts.removeAll()
        liveTranslations.removeAll()
        liveSourceText = ""
        liveTranslation = ""
        clearTransientSegmentBookkeeping()

        captureState = .idle

        // The model intentionally stays in memory (keep_alive governs its
        // idle timeout; quitting LCT unloads it). Re-sync the HUD indicator
        // in the background so stop() returns immediately.
        Task { await refreshModelState() }
    }

    /// Toggle pause state
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            translationQueue.cancelAll()
            liveTranslations.removeAll()
            liveTranslation = ""
            // cancelAll() drops queued and in-flight work; mark those segments
            // as pending (and discard partial streaming output) so they are
            // re-enqueued on resume instead of dangling in .translating forever.
            for idx in segments.indices where segments[idx].state == .translating {
                segments[idx].state = .pending
                segments[idx].translatedText = ""
            }
        } else {
            resumePendingTranslations()
        }
    }

    /// Re-enqueue segments that finalized while paused or were canceled by pausing
    private func resumePendingTranslations() {
        for idx in segments.indices where segments[idx].state == .pending {
            segments[idx].state = .translating
            let context = settings.contextAware ? caption.getContextForTranslation() : []
            translationQueue.enqueue(
                segmentId: segments[idx].id,
                text: segments[idx].sourceText,
                context: context,
                priority: .high,
                isFinal: true
            )
        }
    }

    /// Clear all transcriptions and translations
    func clear() {
        segments.removeAll()
        liveSourceText = ""
        liveTranslation = ""
        liveDrafts.removeAll()
        liveTranslations.removeAll()
        captionSegmenters.removeAll()
        translationHistory.removeAll()
        speakerManager.clear()
        caption.clear()
        sessionTranscript.clear()
        clearTransientSegmentBookkeeping()
    }

    /// Clear all persistent history from SQLite (only while history is enabled)
    func clearPersistentHistory() {
        guard settings.historyEnabled else { return }
        do {
            try historyService.clearHistory()
        } catch {
            appLog("[TranscriptionVM] Failed to clear history: \(error)")
        }
    }

    /// Load persistent history from SQLite (only while history is enabled)
    func loadPersistentHistory(limit: Int = 200) async -> [TranslationEntry] {
        guard settings.historyEnabled else { return [] }
        do {
            return try await historyService.loadRecentTranslationsAsync(limit: limit)
        } catch {
            appLog("[TranscriptionVM] Failed to load history: \(error)")
            return []
        }
    }

    /// Search persistent history (only while history is enabled)
    func searchPersistentHistory(query: String) -> [TranslationEntry] {
        guard settings.historyEnabled else { return [] }
        do {
            return try historyService.searchTranslations(query: query)
        } catch {
            appLog("[TranscriptionVM] Failed to search history: \(error)")
            return []
        }
    }

    /// Delete a single history entry from SQLite (only while history is enabled)
    func deletePersistentEntry(_ entry: TranslationEntry) {
        guard settings.historyEnabled else { return }
        do {
            try historyService.deleteTranslation(withId: entry.id)
        } catch {
            appLog("[TranscriptionVM] Failed to delete entry: \(error)")
        }
    }

    /// Export history to CSV string (only while history is enabled)
    func exportHistoryCSV() -> String? {
        guard settings.historyEnabled else { return nil }
        do {
            return try historyService.exportToCSV()
        } catch {
            appLog("[TranscriptionVM] Failed to export: \(error)")
            return nil
        }
    }

    /// Update settings
    func updateSettings(_ newSettings: AppSettings) {
        let oldSettings = self.settings
        self.settings = newSettings
        let didSaveSettings = newSettings.save()
        let saveError = didSaveSettings ? nil : AppSettings.consumeLastPersistenceError()

        // Update services
        audioCaptureService.config = AudioCaptureConfig(
            captureSystemAudio: newSettings.captureSystemAudio,
            captureMicrophone: newSettings.captureMicrophone,
            microphoneDeviceUID: newSettings.microphoneDeviceUID
        )
        ollamaService.updateSettings(newSettings)
        caption.maxContextEntries = newSettings.maxContextEntries
        trimSegmentsIfNeeded()

        // Update speech recognizer language if changed
        if speechEngine.currentLanguage != newSettings.sourceLanguage {
            speechEngine.setLanguage(newSettings.sourceLanguage)
        }

        // Notify user if a restart is needed for certain settings
        if isCapturing {
            let needsRestart = oldSettings.captureSystemAudio != newSettings.captureSystemAudio
                || oldSettings.captureMicrophone != newSettings.captureMicrophone
                || oldSettings.microphoneDeviceUID != newSettings.microphoneDeviceUID
                || oldSettings.sourceLanguage != newSettings.sourceLanguage
                || oldSettings.ollamaModel != newSettings.ollamaModel
            if needsRestart {
                notice = .warning("Some settings need a restart — click Stop then Start to apply.")
            }
        }

        if !didSaveSettings {
            notice = .warning(
                saveError ?? "Settings save failed. Changes are active this session but may not persist.",
                autoDismiss: false
            )
        }

        // Unload the OLD model by name when the model changed (the service
        // already carries the new settings, so an unqualified unload would
        // target the wrong model), then warm the new one in the background.
        // While capturing, the restart warning above covers the switch.
        if oldSettings.ollamaModel != newSettings.ollamaModel {
            let oldModelName = oldSettings.ollamaModel
            modelState = .unknown
            Task {
                if newSettings.isLocalOllama {
                    try? await ollamaService.unloadModel(oldModelName)
                    guard !isCapturing else {
                        await refreshModelState()
                        return
                    }
                    do {
                        modelState = .loading
                        _ = try await ollamaService.prewarmModel()
                        modelState = .loaded
                        appLog("[TranscriptionVM] ✅ New translation model prewarmed after settings change")
                    } catch {
                        modelState = .failed(error.localizedDescription)
                        appLog("[TranscriptionVM] ⚠️ Prewarm after model change failed: \(error.localizedDescription)")
                    }
                } else {
                    await refreshModelState()
                }
            }
        } else if oldSettings.modelKeepAlive != newSettings.modelKeepAlive {
            // A keep_alive change applies to the next request. If the model
            // is currently loaded, touch it with a prewarm so the new idle
            // timeout takes effect immediately; never load it just for this.
            Task {
                let loaded = (try? await ollamaService.loadedModels()) ?? []
                if isModelInstalled(newSettings.ollamaModel, in: loaded) {
                    _ = try? await ollamaService.prewarmModel()
                }
                await refreshModelState()
            }
        } else {
            Task { await refreshModelState() }
        }
    }

    // MARK: - Transcription Handling

    /// Handle a new transcription result from speech recognizer (any lane)
    private func handleTranscriptionResult(_ result: TranscriptionResult) {
        let lane = result.source

        // Recognition is alive on this lane — reset its stall accumulation.
        stallDetector.registerResult(for: lane)

        if activeTranscriptionTaskIds[lane] != result.id {
            activeTranscriptionTaskIds[lane] = result.id
            // Segments from a finished ASR task can no longer be rolled back
            activeTaskSegmentIds[lane] = []
        }

        let segmenter = captionSegmenters[lane] ?? {
            let s = CaptionSegmenter()
            captionSegmenters[lane] = s
            return s
        }()

        let (newlyFinalized, draft, invalidatedTailCount, flushedFromPreviousTask) = segmenter.process(result: result)
        liveDrafts[lane] = draft
        refreshLiveSourceText()

        if invalidatedTailCount > 0 {
            rollbackTailSegments(count: invalidatedTailCount, source: lane)
            caption.updateOriginal(draft)
        }

        // The previous ASR task's uncommitted draft, kept as a caption instead
        // of being dropped. It belongs to a FINISHED task, so it must not
        // enter the new task's rollback bookkeeping.
        if let flushed = flushedFromPreviousTask {
            appendFinalizedSegment(text: flushed, lane: lane, trackForRollback: false)
        }

        for text in newlyFinalized {
            appendFinalizedSegment(text: text, lane: lane, trackForRollback: true)
        }

        updateLiveDraftTranslation(draft: draft, didFinalize: !newlyFinalized.isEmpty || flushedFromPreviousTask != nil, source: lane)
    }

    /// Emit one finalized caption: create the segment, send it to translation
    /// and context. Only segments of the lane's ACTIVE ASR task are tracked
    /// for rollback — a flushed leftover from a finished task can no longer be
    /// revised by the recognizer.
    private func appendFinalizedSegment(text: String, lane: AudioSource, trackForRollback: Bool) {
        let newSegment = TranslationSegment(sourceText: text, state: isPaused ? .pending : .translating, source: lane)
        if trackForRollback {
            activeTaskSegmentIds[lane, default: []].append(newSegment.id)
        }
        // Punctuation-only segments (e.g. a lone "." finalized on its own)
        // carry nothing to caption or translate. The id above is still
        // recorded so rollback counts stay aligned with the segmenter's;
        // revoking an id that never became a segment is a no-op.
        guard TextUtils.hasSpeechContent(text) else { return }
        segments.append(newSegment)
        trimSegmentsIfNeeded()
        sessionTranscript.append(id: newSegment.id, source: lane, sourceText: text, finalizedAt: newSegment.timestamp)

        caption.updateOriginal(text)

        if !isPaused {
            let context = settings.contextAware ? caption.getContextForTranslation() : []
            translationQueue.enqueue(
                segmentId: newSegment.id,
                text: text,
                context: context,
                priority: .high,
                isFinal: true
            )
        }
    }

    /// Rebuild the combined live source text from all lanes' drafts.
    /// In dual mode each lane's draft is prefixed so the two stay distinguishable.
    private func refreshLiveSourceText() {
        liveSourceText = combinedLaneText(liveDrafts)
    }

    private func refreshLiveTranslation() {
        liveTranslation = combinedLaneText(liveTranslations)
    }

    private func combinedLaneText(_ perLane: [AudioSource: String]) -> String {
        let ordered: [AudioSource] = [.microphone, .system]
        let parts = ordered.compactMap { lane -> String? in
            guard let text = perLane[lane], !text.isEmpty else { return nil }
            return perLane.count > 1 ? "[\(lane.label)] \(text)" : text
        }
        return parts.joined(separator: "\n")
    }

    /// Translate the in-progress draft for lower perceived latency. The result is
    /// volatile (debounced, preemptible by final segments) and shown only in the
    /// live area — it never enters `segments`, history, or translation context.
    private func updateLiveDraftTranslation(draft: String, didFinalize: Bool, source: AudioSource) {
        // A finalized cut means the previous draft's translation is now stale:
        // its text became a real segment that gets its own final translation.
        if didFinalize {
            liveTranslations[source] = nil
        }

        guard !isPaused, settings.liveDraftTranslation else {
            liveTranslations[source] = nil
            refreshLiveTranslation()
            return
        }

        if draft.isEmpty {
            liveTranslations[source] = nil
            refreshLiveTranslation()
            return
        }

        let draftId = liveDraftSegmentIds[source] ?? {
            let id = UUID()
            liveDraftSegmentIds[source] = id
            return id
        }()

        let context = settings.contextAware ? caption.getContextForTranslation() : []
        translationQueue.enqueue(
            segmentId: draftId,
            text: draft,
            context: context,
            priority: .normal, // below .high finals so a finalized sentence preempts the draft
            isFinal: false
        )
    }

    // MARK: - Translation Handling

    /// Handle translation result from queue
    private func handleTranslationResult(_ result: TranslationQueueResult) {
        let cleanedText = TextUtils.cleanTranslationOutput(result.translatedText)

        // Draft translations are transient: update the live area and stop. They
        // must not touch segments, history, or translation context.
        if let lane = liveDraftSegmentIds.first(where: { $0.value == result.segmentId })?.key {
            if result.success {
                liveTranslations[lane] = cleanedText
                refreshLiveTranslation()
                lastLatencyMs = result.latencyMs
            }
            return
        }

        let idx = segments.firstIndex(where: { $0.id == result.segmentId })
        let sourceText = idx.map { segments[$0].sourceText } ?? result.originalText

        if let idx {
            segments[idx].latencyMs = result.latencyMs
        }

        if result.success {
            if let idx {
                segments[idx].translatedText = cleanedText
                segments[idx].state = .translated
            }
            // The session record is not trimmed with the display cards, so a
            // translation may land here after its segment left the screen.
            sessionTranscript.updateTranslation(id: result.segmentId, text: cleanedText)

            // Log history
            let entry = TranslationEntry(
                sourceText: sourceText,
                translatedText: cleanedText,
                speaker: nil,
                targetLanguage: settings.targetLanguage.displayName,
                latencyMs: result.latencyMs
            )
            translationHistory.append(entry)
            if activeTaskSegmentIds.values.contains(where: { $0.contains(result.segmentId) }) {
                historyEntryIdsBySegmentId[result.segmentId] = entry.id
            }
            caption.addToContext(entry)

            // History persistence is opt-in; without consent nothing is written
            // to disk. Existing entries are retained, never silently deleted.
            if settings.historyEnabled {
                Task { try? await historyService.logTranslationAsync(entry) }
                Task {
                    try? await historyService.pruneHistoryAsync(
                        retentionDays: settings.historyRetentionDays,
                        maxEntries: settings.historyMaxEntries
                    )
                }
            }

            // Keep history limited
            if translationHistory.count > 100 {
                translationHistory.removeFirst()
            }
        } else {
            if let idx {
                segments[idx].state = .failed
                segments[idx].translatedText = "Error: \(cleanedText)"
            }
        }

        lastLatencyMs = result.latencyMs
        caption.updateTranslation(cleanedText)
    }

    private func trimSegmentsIfNeeded() {
        let maxCards = max(settings.maxDisplayCards, 1)
        guard segments.count > maxCards else { return }
        segments.removeFirst(segments.count - maxCards)
    }

    /// Revoke the most recent `count` segments of one lane's active ASR task
    /// after the recognizer revised text they were cut from. Earlier segments survive.
    private func rollbackTailSegments(count: Int, source: AudioSource) {
        var laneSegmentIds = activeTaskSegmentIds[source] ?? []
        let staleSegmentIds = Set(laneSegmentIds.suffix(count))
        laneSegmentIds.removeLast(min(count, laneSegmentIds.count))
        activeTaskSegmentIds[source] = laneSegmentIds

        guard !staleSegmentIds.isEmpty else { return }

        appLog("[TranscriptionVM] ASR rollback on [\(source.rawValue)] lane; revoking \(staleSegmentIds.count) stale tail segment(s)")
        translationQueue.cancel(segmentIds: staleSegmentIds)
        segments.removeAll { staleSegmentIds.contains($0.id) }
        sessionTranscript.remove(ids: staleSegmentIds)

        let staleHistoryIds = Set(staleSegmentIds.compactMap { historyEntryIdsBySegmentId[$0] })
        if !staleHistoryIds.isEmpty {
            translationHistory.removeAll { staleHistoryIds.contains($0.id) }
            caption.removeContextEntries(withIds: staleHistoryIds)

            for entryId in staleHistoryIds {
                Task {
                    try? await historyService.deleteTranslationAsync(withId: entryId)
                }
            }
        }

        for segmentId in staleSegmentIds {
            historyEntryIdsBySegmentId.removeValue(forKey: segmentId)
        }
    }

    private func clearTransientSegmentBookkeeping() {
        activeTranscriptionTaskIds.removeAll()
        activeTaskSegmentIds.removeAll()
        historyEntryIdsBySegmentId.removeAll()
    }

    private func isModelInstalled(_ modelName: String, in availableModels: [String]) -> Bool {
        if availableModels.contains(modelName) {
            return true
        }

        guard !modelName.contains(":") else {
            return false
        }

        return availableModels.contains { $0.hasPrefix("\(modelName):") }
    }

    /// Copy current translation to clipboard
    func copyToClipboard() {
        guard let last = segments.last else { return }
        let text = "\(last.sourceText)\n\(last.translatedText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Session Export

    /// Export the full (untrimmed) session transcript through the system save
    /// panel. The user picks the location, so the file may contain caption
    /// content; the log records only the line count and format, never text.
    func exportSession(_ format: SessionExporter.Format) {
        let transcript = sessionTranscript
        guard !transcript.entries.isEmpty else { return }

        let content = SessionExporter.export(
            transcript,
            format: format,
            sourceLanguages: settings.sourceLanguage.isoCode.uppercased(),
            targetLanguage: settings.targetLanguage.isoCode.uppercased()
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = SessionExporter.suggestedFileName(
            for: format,
            sessionStart: transcript.startedAt ?? Date()
        )
        panel.title = "Export Session"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            appLog("[TranscriptionVM] Exported session: \(transcript.entries.count) line(s), format \(format.rawValue)")
            notice = .info("Exported \(transcript.entries.count) lines to \(url.lastPathComponent)")
        } catch {
            appLog("[TranscriptionVM] ❌ Session export failed: \(error.localizedDescription)")
            notice = .error("Export failed: \(error.localizedDescription)")
        }
    }
}
