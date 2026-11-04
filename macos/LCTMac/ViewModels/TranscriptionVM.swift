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

/// Whether the embedded translation model is loaded in this process.
/// The service's published lifecycle drives the HUD model indicator.
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

    /// Whether the embedded translation model is loaded right now.
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

    /// Lanes the speech engine is actually recognizing on (after legacy-engine
    /// degradation), recorded when recognition starts. Unlike `captureSources`
    /// (an audio-capture publisher), this is deterministic — language restarts
    /// key off it.
    var recognitionLanes: [AudioSource] = []

    /// Regenerated at every successful start(). A lane language restart that
    /// outlives its session (stopped, or stopped and restarted, while a model
    /// download was in flight) must not touch the new session's lane state.
    private var captureSessionId = UUID()

    /// Microphone input device actually in use (nil when the mic lane is off)
    @Published var microphoneDeviceName: String?
    @Published var microphoneDeviceIsVirtual: Bool = false

    /// Current user-facing notice (info / warning / error with optional actions)
    @Published var notice: AppNotice?

    /// Last translation latency
    @Published var lastLatencyMs: Int = 0

    @Published private(set) var translationStatusText = "Off"
    var isTranslationReady: Bool { translationFailure == nil && translationReadiness() }
    private var canTranslate: Bool { captureState == .capturing && settings.translationEnabled && isTranslationReady && !isPaused }

    /// When the current capture session started (nil when stopped)
    @Published var captureStartedAt: Date?

    /// Latest per-language on-device availability (drives the language menu's
    /// filtering and "(download)" markers). Empty while the first probe is in
    /// flight — the menu then lists every language unannotated.
    @Published private(set) var languageAvailability: [SourceLanguage: LanguageAvailability] = [:]
    @Published private var speechFailure: String?
    @Published private var preparingSpeechLanguage: SourceLanguage?

    /// Readiness of original captions, independent from optional translation.
    var speechStatusText: String {
        if speechFailure != nil { return "Unavailable" }
        if preparingSpeechLanguage != nil { return "Preparing resources" }
        switch captureState {
        case .starting: return "Preparing resources"
        case .capturing: return isPaused ? "Paused" : "Listening"
        case .stopping: return "Stopping"
        case .idle:
            var sources: [AudioSource] = []
            if settings.captureSystemAudio { sources.append(.system) }
            if settings.captureMicrophone { sources.append(.microphone) }
            let (effectiveSources, _) = SpeechEngineSelection.effectiveSources(sources, for: speechEngineKind)
            let languages = effectiveSources.isEmpty
                ? [settings.sourceLanguage]
                : effectiveSources.map { settings.language(for: $0) }
            let availability = languages.map { languageAvailability[$0] }
            if availability.contains(.unsupported) { return "Unavailable" }
            if availability.contains(.downloadable) { return "Resources needed" }
            if availability.contains(nil) { return "Checking resources" }
            return "Ready"
        }
    }

    /// Whether the selected engine runs independent per-lane recognition, so
    /// the microphone lane may use its own language (drives the Microphone
    /// section of the language menu; the legacy engine runs a single lane).
    var supportsPerLaneLanguages: Bool { speechEngineKind == .speechTranscriber }

    /// Re-probe which source languages the engine can recognize on-device.
    /// Locale checks only — no recognition, download, or permission prompt.
    func refreshLanguageAvailability() async {
        languageAvailability = await speechEngine.languageAvailability()
    }

    /// Untrimmed record of the current session, the source for session
    /// exports. Independent of the trimmed on-screen cards and of the opt-in
    /// persistent history; survives stop() so a finished session stays
    /// exportable until the next start() or clear().
    @Published private(set) var sessionTranscript = SessionTranscript()

    // MARK: - Services

    private let audioCaptureService: AudioCaptureService
    private let translationEngine: any TranslationEngine
    private let embeddedTranslationService: EmbeddedTranslationService?
    private let translationReadiness: @MainActor () -> Bool
    private let persistSettings: (AppSettings) -> Bool
    private let captionAudioGate = CaptionAudioGate()
    private var translationFailure: String?
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
    private let historyService: HistoryService

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
    private var persistedHistorySegmentIDs: Set<UUID> = []
    private var historyPersistenceTask: Task<Void, Never>?
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
    /// Identifies the mic-silence warning currently on screen so the recovery
    /// callback retracts exactly that notice and nothing else.
    private var micSilenceNoticeId: UUID?
    /// The "hearing audio but recognizing nothing" warning on screen and the
    /// lane it is about, so a later result on that lane retracts exactly it.
    private var recognitionStallNotice: (id: UUID, source: AudioSource)?
    /// Identifies the on-device speech model download notice currently on
    /// screen, so the download-finished callback retracts exactly that one.
    private var modelDownloadNoticeId: UUID?
    /// The task pulling the translation model from the Download notice
    /// action; non-nil only while a download is in flight.
    private var modelDownloadTask: Task<Void, Never>?
    // MARK: - Initialization

    init(settings: AppSettings = .load(),
         ollamaService: OllamaService? = nil,
         ollamaGuardian: OllamaGuardian? = nil,
         hardwareProfile: HardwareProfile = .current(),
         makeModelManager: @escaping (OllamaEndpoint) -> OllamaModelManager = { OllamaModelManager(endpoint: $0) },
         audioCaptureService: AudioCaptureService? = nil,
         speechEngine: (any SpeechRecognitionEngine)? = nil,
         translationEngine: (any TranslationEngine)? = nil,
         translationReadiness: (@MainActor () -> Bool)? = nil,
         historyService: HistoryService? = nil,
         persistSettings: @escaping (AppSettings) -> Bool = { $0.save() }) {
        let loadedSettings = settings
        self.settings = loadedSettings
        self.persistSettings = persistSettings
        self.historyService = historyService ?? HistoryService()
        self.audioCaptureService = audioCaptureService ?? AudioCaptureService(
            config: AudioCaptureConfig(
                captureSystemAudio: loadedSettings.captureSystemAudio,
                captureMicrophone: loadedSettings.captureMicrophone,
                microphoneDeviceUID: loadedSettings.microphoneDeviceUID
            )
        )
        // Legacy arguments are accepted by old transport fixtures, but no
        // guardian/model manager is constructed or invoked by the app.
        let selectedEngine: any TranslationEngine
        if let translationEngine {
            selectedEngine = translationEngine
            self.embeddedTranslationService = nil
            self.translationReadiness = translationReadiness ?? { true }
        } else if let ollamaService {
            selectedEngine = ollamaService
            self.embeddedTranslationService = nil
            self.translationReadiness = translationReadiness ?? { true }
        } else {
            let service = EmbeddedTranslationService.shared
            selectedEngine = service
            self.embeddedTranslationService = service
            self.translationReadiness = translationReadiness ?? { service.isReady }
        }
        self.translationEngine = selectedEngine
        selectedEngine.updateSettings(loadedSettings)
        self.translationQueue = TranslationQueue(engine: selectedEngine)
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

        updateTranslationStatus()

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

        // Bind errors. These are runtime failures surfaced mid-session; offer a
        // retry since the user's intent was to keep capturing.
        audioCaptureService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.notice = .error(error, actions: [.retryCapture])
            }
            .store(in: &cancellables)

        speechEngine.lastErrorPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.speechFailure = error
                if let error {
                    self?.notice = .error(error, actions: [.retryCapture])
                }
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
            self.recognitionLanes = []
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

        if let service = embeddedTranslationService {
            service.$state
                .sink { [weak self] state in
                    guard let self else { return }
                    self.updateTranslationStatus(state: state)
                    if state != .ready { self.cancelPendingTranslation() }
                }
                .store(in: &cancellables)
        }

    }

    // MARK: - Actions

    /// Drain caption writes before exporting retained history or ending capture.
    func flushHistoryPersistence() async {
        await historyPersistenceTask?.value
    }

    /// Keep source saves, completed translations, and ASR rollbacks in order.
    /// Otherwise a delayed source write could replace its finished translation.
    private func enqueueHistoryMutation(_ operation: @escaping @Sendable (HistoryService) async throws -> Void) {
        let previous = historyPersistenceTask
        let service = historyService
        historyPersistenceTask = Task {
            await previous?.value
            do { try await operation(service) }
            catch { appLog("[TranscriptionVM] Failed to save history: \(error)") }
        }
    }

    private func persistHistoryEntry(_ entry: TranslationEntry) {
        guard settings.historyEnabled else { return }
        persistedHistorySegmentIDs.insert(entry.id)
        let retentionDays = settings.historyRetentionDays
        let maxEntries = settings.historyMaxEntries
        enqueueHistoryMutation { service in
            try await service.logTranslationAsync(entry)
            try await service.pruneHistoryAsync(retentionDays: retentionDays, maxEntries: maxEntries)
        }
    }

    /// Loading a previously downloaded model is optional and independent of
    /// caption startup. This never downloads weights or starts an external service.
    func prepareModelOnLaunch() async {
        guard settings.translationEnabled,
              let service = embeddedTranslationService, service.isModelDownloaded else { return }
        await prepareTranslation()
    }

    func refreshModelState() async {
        updateTranslationStatus()
    }

    private func updateTranslationStatus(state: EmbeddedTranslationState? = nil) {
        let state = state ?? embeddedTranslationService?.state
        if let failure = translationFailure {
            modelState = .failed(failure)
            translationStatusText = "Translation unavailable"
            return
        }
        if let state {
            switch state {
            case .notDownloaded:
                modelState = .notLoaded
                translationStatusText = settings.translationEnabled ? "Model needed" : "Off"
            case .downloading:
                modelState = .notLoaded
                translationStatusText = "Downloading model"
            case .verifying:
                modelState = .notLoaded
                translationStatusText = "Verifying model"
            case .downloaded:
                modelState = .notLoaded
                translationStatusText = settings.translationEnabled ? "Model ready to load" : "Off"
            case .loading:
                modelState = .loading
                translationStatusText = "Loading model"
            case .ready:
                modelState = .loaded
                translationStatusText = settings.translationEnabled ? "Ready" : "Off"
            case .failed(let message):
                modelState = .failed(message)
                translationStatusText = "Translation unavailable"
            }
        } else {
            modelState = isTranslationReady ? .loaded : .notLoaded
            translationStatusText = !settings.translationEnabled ? "Off" : (isTranslationReady ? "Ready" : "Translation unavailable")
        }
    }

    /// Cancel only translation work. Original captions and completed translations
    /// remain in the session when a model is disabled, changed, or fails.
    private func cancelPendingTranslation() {
        translationQueue.cancelAll()
        liveTranslations.removeAll()
        liveTranslation = ""
        for index in segments.indices where segments[index].state == .translating || segments[index].state == .pending {
            segments[index].state = .captionOnly
            segments[index].translatedText = ""
        }
    }

    func prepareTranslation() async {
        translationFailure = nil
        guard let service = embeddedTranslationService else {
            updateTranslationStatus()
            if notice?.actions.contains(.retryTranslation) == true { notice = nil }
            return
        }
        guard service.isModelDownloaded else {
            updateTranslationStatus()
            notice = AppNotice(severity: .info, message: "Original captions are ready. Download the local model to add translation.", actions: [.downloadModel], autoDismiss: false)
            return
        }
        do {
            try await service.loadModel()
            updateTranslationStatus()
            if notice?.actions.contains(.retryTranslation) == true { notice = nil }
        } catch is CancellationError {
            updateTranslationStatus()
        } catch {
            updateTranslationStatus()
            notice = AppNotice(severity: .warning, message: "Translation is unavailable: \(error.localizedDescription). Original captions continue.", actions: [.retryTranslation], autoDismiss: false)
        }
    }

    func start() async {
        appLog("[TranscriptionVM] ▶️ start() called")
        guard captureState == .idle else {
            appLog("[TranscriptionVM] ⏭ start() ignored — capture is \(captureState.rawValue)")
            return
        }
        captureState = .starting
        speechFailure = nil
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

            // Update speech recognizer language
            appLog("[TranscriptionVM] Setting speech language: \(settings.sourceLanguage.displayName)")
            speechEngine.setLanguage(settings.sourceLanguage)

            // Start speech recognition — one independent lane per active
            // source, each recognizing its own configured language.
            appLog("[TranscriptionVM] Starting speech recognition...")
            let laneLanguages = Dictionary(uniqueKeysWithValues: activeSources.map { ($0, settings.language(for: $0)) })
            try await speechEngine.start(sources: activeSources, languages: laneLanguages)
            recognitionLanes = activeSources
            appLog("[TranscriptionVM] ✅ Speech recognition started")

            // Connect audio capture to speech recognizer (buffers stay tagged per lane)
            let engine = self.speechEngine
            let gate = captionAudioGate
            isPaused = false
            gate.setEnabled(true)
            audioCaptureService.onAudioBuffer = { [weak engine] buffer, source in
                guard gate.isEnabled else { return }
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
            captureSessionId = UUID()
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


        } catch let error as SpeechAnalyzerError {
            speechFailure = error.localizedDescription
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
        preparingSpeechLanguage = language
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
            captionAudioGate.setEnabled(false)
            captureState = .idle
            captureStartedAt = nil
            recognitionLanes = []
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
    func handleRecognitionStall(source: AudioSource) {
        // A live error (permission lost, stream interrupted) outranks this warning.
        guard notice?.severity != .error else { return }
        appLog("[TranscriptionVM] ⚠️ [\(source.rawValue)] lane audible for 8s+ but no recognition results")
        let stallNotice = AppNotice(
            severity: .warning,
            message: "Hearing audio on \(source.label) but recognizing nothing. Is the recognition language (\(settings.language(for: source).displayName)) right?",
            actions: [.openAppSettings]
        )
        recognitionStallNotice = (stallNotice.id, source)
        notice = stallNotice
    }

    /// The lane the stall warning was about recognized something again
    /// (e.g. the user fixed its language) — retract that warning.
    private func retractRecognitionStallNotice(for lane: AudioSource) {
        guard let stall = recognitionStallNotice, stall.source == lane else { return }
        if notice?.id == stall.id {
            notice = nil
        }
        recognitionStallNotice = nil
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
        case .startOllama, .retryTranslation:
            Task { await prepareTranslation() }
        case .retryCapture:
            notice = nil
            Task { await start() }
        case .downloadModel:
            guard modelDownloadTask == nil else { return }
            modelDownloadTask = Task {
                await downloadSelectedModel()
                modelDownloadTask = nil
            }
        case .cancelModelDownload:
            modelDownloadTask?.cancel()
            embeddedTranslationService?.cancelDownload()
        case .openAppSettings:
            break // handled by the view
        }
    }

    private func downloadSelectedModel() async {
        guard let service = embeddedTranslationService else { return }
        let progressNotice = AppNotice(severity: .info, message: "Downloading the local translation model… Original captions remain available.", actions: [.cancelModelDownload], autoDismiss: false)
        notice = progressNotice
        do {
            try await service.downloadModel()
            if notice?.id == progressNotice.id { notice = nil }
            if settings.translationEnabled { await prepareTranslation() }
        } catch is CancellationError {
            if notice?.id == progressNotice.id { notice = nil }
        } catch {
            notice = AppNotice(severity: .warning, message: "Model download failed: \(error.localizedDescription). Original captions remain available.", actions: [.downloadModel], autoDismiss: false)
        }
        updateTranslationStatus()
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
        captionAudioGate.setEnabled(false)
        micSilenceNoticeId = nil
        modelDownloadNoticeId = nil
        await audioCaptureService.stopCapture()
        translationQueue.cancelAll()
        await speechEngine.stop()
        // Some recognizers finish with only a partial result. Preserve each
        // remaining visible draft after final callbacks have been drained;
        // a lane that delivered its final result has no draft left to repeat.
        for lane in [AudioSource.microphone, .system] {
            finalizeLaneDraft(lane)
        }
        cancelPendingTranslation()
        preparingSpeechLanguage = nil
        recognitionLanes = []
        captionSegmenters.removeAll()
        liveDrafts.removeAll()
        liveTranslations.removeAll()
        liveSourceText = ""
        liveTranslation = ""
        clearTransientSegmentBookkeeping()

        captureState = .idle

        isPaused = false
        await flushHistoryPersistence()
    }

    /// Pause the caption stream without destroying the capture session. The
    /// real-time gate stops audio entering ASR; late recognition results are
    /// ignored while paused. Resume keeps the same transcript and segmenters.
    func togglePause() {
        guard captureState == .capturing else { return }
        isPaused.toggle()
        captionAudioGate.setEnabled(!isPaused)
        if isPaused {
            cancelPendingTranslation()
            stopStallMonitoring()
        } else {
            startStallMonitoring()
        }
    }

    /// Clear all transcriptions and translations
    func clear() {
        translationQueue.cancelAll()
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
        enqueueHistoryMutation { try $0.clearHistory() }
    }

    /// Load persistent history from SQLite (only while history is enabled)
    func loadPersistentHistory(limit: Int = 200) async -> [TranslationEntry] {
        guard settings.historyEnabled else { return [] }
        await flushHistoryPersistence()
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
        enqueueHistoryMutation { try await $0.deleteTranslationAsync(withId: entry.id) }
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
        let lanesToRestart = applyUpdatedSettings(newSettings)
        guard !lanesToRestart.isEmpty else { return }
        Task { await restartLanesForLanguageChange(lanesToRestart) }
    }

    /// HUD language menu: change one lane's recognition language. `nil` for
    /// the microphone lane means "same as system audio". While capturing, only
    /// the affected lanes restart their recognition — the switch takes effect
    /// without stopping the session.
    func setSourceLanguage(_ language: SourceLanguage?, for source: AudioSource) async {
        var newSettings = settings
        switch source {
        case .system:
            guard let language, language != settings.sourceLanguage else { return }
            newSettings.sourceLanguage = language
        case .microphone:
            guard language != settings.microphoneSourceLanguage else { return }
            newSettings.microphoneSourceLanguage = language
        }
        let lanesToRestart = applyUpdatedSettings(newSettings)
        await restartLanesForLanguageChange(lanesToRestart)
    }

    /// HUD language menu: change the translation target language. Applies to
    /// translations produced from now on — nothing restarts.
    func setTargetLanguage(_ language: TargetLanguage) {
        guard language != settings.targetLanguage else { return }
        var newSettings = settings
        newSettings.targetLanguage = language
        _ = applyUpdatedSettings(newSettings)
    }

    /// Shared settings-application path for `updateSettings` and the HUD
    /// language menu: persists the settings, updates the services, and
    /// returns the capture lanes whose effective recognition language changed
    /// (empty unless capturing — idle changes just ride the next start()).
    @discardableResult
    private func applyUpdatedSettings(_ newSettings: AppSettings) -> [AudioSource] {
        let oldSettings = self.settings
        self.settings = newSettings
        let didSaveSettings = persistSettings(newSettings)
        let saveError = didSaveSettings ? nil : AppSettings.consumeLastPersistenceError()

        // Update services
        audioCaptureService.config = AudioCaptureConfig(
            captureSystemAudio: newSettings.captureSystemAudio,
            captureMicrophone: newSettings.captureMicrophone,
            microphoneDeviceUID: newSettings.microphoneDeviceUID
        )
        if oldSettings.translationEnabled != newSettings.translationEnabled
            || oldSettings.targetLanguage != newSettings.targetLanguage
            || oldSettings.customPrompt != newSettings.customPrompt {
            cancelPendingTranslation()
        }
        translationEngine.updateSettings(newSettings)
        caption.maxContextEntries = newSettings.maxContextEntries
        trimSegmentsIfNeeded()

        // Language changes take effect live while capturing: each affected
        // lane restarts its own recognition (restartLanesForLanguageChange)
        // instead of forcing a stop/start cycle. Changing the system-audio
        // language also restarts the microphone lane while the mic follows
        // the system language — its effective language changed too.
        var lanesToRestart: [AudioSource] = []
        if isCapturing {
            if oldSettings.language(for: .system) != newSettings.language(for: .system) {
                lanesToRestart.append(.system)
            }
            if oldSettings.language(for: .microphone) != newSettings.language(for: .microphone) {
                lanesToRestart.append(.microphone)
            }
        } else if speechEngine.currentLanguage != newSettings.sourceLanguage {
            speechEngine.setLanguage(newSettings.sourceLanguage)
        }

        // Notify user if a restart is needed for certain settings. Language
        // changes apply live and no longer need one.
        if isCapturing {
            let needsRestart = oldSettings.captureSystemAudio != newSettings.captureSystemAudio
                || oldSettings.captureMicrophone != newSettings.captureMicrophone
                || oldSettings.microphoneDeviceUID != newSettings.microphoneDeviceUID
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

        if oldSettings.translationEnabled != newSettings.translationEnabled {
            translationFailure = nil
            if newSettings.translationEnabled {
                Task { await prepareTranslation() }
            }
        }
        updateTranslationStatus()

        return lanesToRestart
    }

    /// Restart the given lanes' recognition with their configured language,
    /// one lane at a time. A lane that isn't running (dropped by the legacy
    /// single-task engine, or never started) is skipped; a lane that fails to
    /// restart surfaces an error without affecting its sibling.
    private func restartLanesForLanguageChange(_ lanes: [AudioSource]) async {
        let session = captureSessionId
        for lane in lanes {
            guard captureState == .capturing else {
                appLog("[TranscriptionVM] ⏭ lane language restart aborted — capture is \(captureState.rawValue)")
                return
            }
            guard recognitionLanes.contains(lane) else { continue }

            let language = settings.language(for: lane)
            appLog("[TranscriptionVM] 🔀 restarting [\(lane.rawValue)] recognition with language \(language.displayName)")
            // A new language gets a fresh stall budget on this lane.
            stallDetector.resetLane(lane)
            do {
                try await speechEngine.restartLane(lane, language: language)
                appLog("[TranscriptionVM] ✅ [\(lane.rawValue)] lane now recognizes \(language.displayName)")
            } catch {
                appLog("[TranscriptionVM] ⚠️ [\(lane.rawValue)] lane language switch failed: \(error.localizedDescription)")
                if captureState == .capturing, captureSessionId == session {
                    notice = .error("Could not switch the \(lane == .system ? "system audio" : "microphone") language to \(language.displayName): \(error.localizedDescription)")
                }
            }
            // A stop (or stop + start) while the restart was in flight — e.g.
            // during an on-device model download — made this flow stale:
            // leave the current session's lane state alone.
            guard captureState == .capturing, captureSessionId == session else { return }
            // The old recognition task is finished whether the restart
            // succeeded or not: keep its uncommitted draft as a caption and
            // reset the lane's segmentation state for the new task.
            finalizeLaneDraft(lane)
            // A speech-model download may have completed during the restart.
            await refreshLanguageAvailability()
        }
    }

    /// The lane's recognition task ended (lane language restart): keep its
    /// uncommitted draft as a finalized caption — the same flush semantics as
    /// a finished ASR task in handleTranscriptionResult — then reset the
    /// lane's segmentation and live-draft state so the next task starts clean.
    private func finalizeLaneDraft(_ lane: AudioSource) {
        let draft = liveDrafts[lane]?.trimmingCharacters(in: .whitespaces) ?? ""

        captionSegmenters[lane]?.reset()
        captionSegmenters[lane] = nil
        liveDrafts[lane] = nil
        liveTranslations[lane] = nil
        if let draftId = liveDraftSegmentIds.removeValue(forKey: lane) {
            translationQueue.cancel(segmentIds: [draftId])
        }
        // Segments of the finished task can no longer be rolled back.
        activeTranscriptionTaskIds[lane] = nil
        activeTaskSegmentIds[lane] = []
        refreshLiveSourceText()
        refreshLiveTranslation()

        if !draft.isEmpty {
            appendFinalizedSegment(text: draft, lane: lane, trackForRollback: false)
        }
    }

    // MARK: - Transcription Handling

    /// Handle a new transcription result from speech recognizer (any lane)
    private func handleTranscriptionResult(_ result: TranscriptionResult) {
        guard !isPaused, captureState == .capturing || captureState == .stopping else { return }
        speechFailure = nil
        let lane = result.source

        // Recognition is alive on this lane — reset its stall accumulation.
        stallDetector.registerResult(for: lane)
        retractRecognitionStallNotice(for: lane)

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
        let newSegment = TranslationSegment(sourceText: text, state: canTranslate ? .translating : .captionOnly, source: lane)
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
        if trackForRollback {
            historyEntryIdsBySegmentId[newSegment.id] = newSegment.id
        }
        persistHistoryEntry(TranslationEntry(
            id: newSegment.id,
            sourceText: text,
            translatedText: "",
            targetLanguage: "",
            timestamp: newSegment.timestamp
        ))

        caption.updateOriginal(text)

        if canTranslate {
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

        guard canTranslate, settings.liveDraftTranslation else {
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
        if !result.success {
            if let index = segments.firstIndex(where: { $0.id == result.segmentId }) {
                segments[index].state = .failed
                segments[index].translatedText = ""
            }
            translationFailure = result.error?.localizedDescription ?? "Translation failed"
            cancelPendingTranslation()
            updateTranslationStatus()
            notice = AppNotice(severity: .warning, message: "Translation stopped. Original captions continue.", actions: [.retryTranslation], autoDismiss: false)
            return
        }

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
                id: result.segmentId,
                sourceText: sourceText,
                translatedText: cleanedText,
                speaker: nil,
                targetLanguage: settings.targetLanguage.displayName,
                timestamp: sessionTranscript.entries.first(where: { $0.id == result.segmentId })?.finalizedAt ?? Date(),
                latencyMs: result.latencyMs
            )
            translationHistory.append(entry)
            if activeTaskSegmentIds.values.contains(where: { $0.contains(result.segmentId) }) {
                historyEntryIdsBySegmentId[result.segmentId] = entry.id
            }
            caption.addToContext(entry)

            // Replace the source-only row, retaining its stable id and time.
            persistHistoryEntry(entry)

            // Keep history limited
            if translationHistory.count > 100 {
                translationHistory.removeFirst()
            }
        }

        lastLatencyMs = result.latencyMs
        if result.success { caption.updateTranslation(cleanedText) }
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

            for entryId in staleHistoryIds where persistedHistorySegmentIDs.contains(entryId) {
                enqueueHistoryMutation { try await $0.deleteTranslationAsync(withId: entryId) }
                persistedHistorySegmentIDs.remove(entryId)
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
        persistedHistorySegmentIDs.removeAll()
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

        // Per-lane recognition languages (F9): "ZH", or "SYS ZH · MIC EN" when
        // the session has microphone lines in a different language.
        let systemCode = settings.language(for: .system).isoCode.uppercased()
        let microphoneCode = settings.language(for: .microphone).isoCode.uppercased()
        let hasMicrophoneLines = transcript.entries.contains { $0.source == .microphone }
        let sourceLanguages = hasMicrophoneLines && microphoneCode != systemCode
            ? "SYS \(systemCode) · MIC \(microphoneCode)"
            : systemCode
        let content = SessionExporter.export(
            transcript,
            format: format,
            sourceLanguages: sourceLanguages,
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

/// Audio callbacks run on real-time threads and cannot read MainActor state.
private final class CaptionAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}
