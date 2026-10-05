import SwiftUI
import Combine

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

    /// Is currently capturing audio
    @Published var isCapturing: Bool = false

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

    // MARK: - Services

    private let audioCaptureService: AudioCaptureService
    private let ollamaService: OllamaService
    private let translationQueue: TranslationQueue
    private let speakerManager: SpeakerManager
    private let speechAnalyzerService: SpeechAnalyzerService
    private let caption: Caption
    /// One segmenter per capture lane — each lane's transcript evolves
    /// independently and must not be fed into a shared segmenter.
    private var captionSegmenters: [AudioSource: CaptionSegmenter] = [:]
    private let ollamaGuardian = OllamaGuardian.shared
    private let historyService = HistoryService()

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

    // MARK: - Initialization

    init() {
        let loadedSettings = AppSettings.load()
        self.settings = loadedSettings
        self.audioCaptureService = AudioCaptureService(
            config: AudioCaptureConfig(
                captureSystemAudio: loadedSettings.captureSystemAudio,
                captureMicrophone: loadedSettings.captureMicrophone,
                microphoneDeviceUID: loadedSettings.microphoneDeviceUID
            )
        )
        self.ollamaService = OllamaService(settings: loadedSettings)
        self.translationQueue = TranslationQueue(ollamaService: ollamaService)
        self.speakerManager = SpeakerManager()
        self.speechAnalyzerService = SpeechAnalyzerService(language: loadedSettings.sourceLanguage)
        self.caption = Caption.shared

        caption.maxContextEntries = loadedSettings.maxContextEntries

        setupBindings()

        if let persistenceError = AppSettings.consumeLastPersistenceError() {
            notice = .warning(persistenceError, autoDismiss: false)
        }

        // Probe Ollama on launch so the status indicator reflects reality
        // immediately, instead of showing the default "stopped" until first use.
        Task {
            await ollamaGuardian.checkStatus()
            isOllamaConnected = await ollamaService.checkHealth()
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

        // Bind capture state
        audioCaptureService.$isCapturing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCapturing)

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
                self?.notice = .error(error, actions: [.retryCapture])
            }
            .store(in: &cancellables)

        speechAnalyzerService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.notice = .error(error, actions: [.retryCapture])
            }
            .store(in: &cancellables)

        // Handle speech recognition results
        speechAnalyzerService.onTranscription = { [weak self] result in
            self?.handleTranscriptionResult(result)
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
            self.speechAnalyzerService.stop()
            self.translationQueue.cancelAll()
            self.notice = .error("Audio capture interrupted: \(error.localizedDescription)", actions: [.retryCapture])
        }

        // Mic lane delivered only digital silence for a full session streak —
        // almost always the wrong input device (e.g. an idle virtual sound card).
        audioCaptureService.onMicrophoneSilenceDetected = { [weak self] in
            self?.handleMicrophoneSilence()
        }

    }

    // MARK: - Actions

    /// Start capturing and translating
    func start() async {
        appLog("[TranscriptionVM] ▶️ start() called")

        var micOnlyFallback = false
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

            // Resolve which capture lanes to run: each enabled source needs its
            // own permission. system → screen recording TCC, mic → microphone TCC.
            appLog("[TranscriptionVM] captureSystemAudio: \(settings.captureSystemAudio), captureMicrophone: \(settings.captureMicrophone)")

            var activeSources: [AudioSource] = []

            if settings.captureSystemAudio {
                appLog("[TranscriptionVM] Checking screen capture permission...")
                let hasPermission = await audioCaptureService.checkPermission()
                appLog("[TranscriptionVM] Screen capture permission: \(hasPermission)")

                if hasPermission {
                    activeSources.append(.system)
                } else if !settings.captureMicrophone {
                    appLog("[TranscriptionVM] ❌ No screen permission and no microphone fallback")
                    notice = .error(
                        "Screen recording permission is required to capture system audio.",
                        actions: [.openScreenRecordingSettings]
                    )
                    return
                }
            }

            if settings.captureMicrophone {
                let micGranted = await AudioCaptureService.ensureMicrophonePermission()
                if micGranted {
                    activeSources.append(.microphone)
                    if settings.captureSystemAudio && !activeSources.contains(.system) {
                        // Screen denied, mic OK → classic mic-only fallback
                        micOnlyFallback = true
                    }
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
            appLog("[TranscriptionVM] Active sources: \(activeSources.map { $0.rawValue })")

            if settings.isLocalOllama {
                // Ensure local Ollama is running (will start it if needed).
                appLog("[TranscriptionVM] Ensuring local Ollama is running...")
                do {
                    try await ollamaGuardian.ensureRunning()
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
            }

            // Check Ollama connection
            appLog("[TranscriptionVM] Checking Ollama connection...")
            let isConnected = await ollamaService.checkHealth()
            appLog("[TranscriptionVM] Ollama connected: \(isConnected)")
            if !isConnected {
                if settings.isLocalOllama {
                    notice = .error(
                        "Cannot connect to local Ollama at \(settings.ollamaURL).",
                        actions: [.startOllama]
                    )
                } else {
                    notice = .error(
                        "Cannot connect to remote Ollama at \(settings.ollamaURL). Check the address in Settings.",
                        actions: [.openAppSettings]
                    )
                }
                return
            }

            do {
                let availableModels = try await ollamaService.getAvailableModels()
                guard isModelInstalled(settings.ollamaModel, in: availableModels) else {
                    let installHint = settings.isLocalOllama
                        ? "Run: ollama pull \(settings.ollamaModel)"
                        : "Install it on the configured remote Ollama server."
                    notice = .error(
                        "Model '\(settings.ollamaModel)' is not installed. \(installHint)",
                        actions: [.openAppSettings]
                    )
                    return
                }
            } catch {
                notice = .error("Cannot list Ollama models: \(error.localizedDescription)", actions: [.retryCapture])
                return
            }

            notice = .info("Loading translation model — the first run may take 5–30 seconds…")
            do {
                let latencyMs = try await ollamaService.prewarmModel()
                appLog("[TranscriptionVM] ✅ Ollama model prewarmed in \(latencyMs)ms")
                notice = nil
            } catch let error as OllamaError {
                notice = .error("Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)", actions: [.retryCapture])
                return
            } catch {
                notice = .error("Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)", actions: [.retryCapture])
                return
            }

            // Update speech recognizer language
            appLog("[TranscriptionVM] Setting speech language: \(settings.sourceLanguage.displayName)")
            speechAnalyzerService.setLanguage(settings.sourceLanguage)

            // Start speech recognition — one independent lane per active source
            appLog("[TranscriptionVM] Starting speech recognition...")
            try await speechAnalyzerService.start(sources: activeSources)
            appLog("[TranscriptionVM] ✅ Speech recognition started")

            // Connect audio capture to speech recognizer (buffers stay tagged per lane)
            let analyzer = self.speechAnalyzerService
            audioCaptureService.onAudioBuffer = { [weak analyzer] buffer, source in
                analyzer?.appendAudioBuffer(buffer, source: source)
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
            captureStartedAt = Date()

            // Surface lane-degraded notices now that capture is running (earlier
            // notices were overwritten by the model-loading progress message).
            if micOnlyFallback {
                notice = .warning("No screen recording permission — capturing microphone only.")
            } else if micDeniedInDual {
                notice = AppNotice(
                    severity: .warning,
                    message: "No microphone permission — capturing system audio only.",
                    actions: [.openMicrophoneSettings]
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

            // Start local health monitoring only for local Ollama.
            if settings.isLocalOllama {
                ollamaGuardian.startHealthMonitoring(interval: 30)
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

    /// The mic lane produced nothing but digital silence for 6 straight
    /// seconds — almost always a wrong or idle input device (e.g. BlackHole).
    private func handleMicrophoneSilence() {
        // A live error (permission lost, stream interrupted) outranks this warning.
        guard notice?.severity != .error else { return }
        let deviceName = audioCaptureService.activeMicrophoneDevice?.name ?? "unknown"
        appLog("[TranscriptionVM] ⚠️ Microphone lane silent for 6s (device: \(deviceName))")
        notice = AppNotice(
            severity: .warning,
            message: "Microphone \"\(deviceName)\" is sending no audio. If it's a virtual device (e.g. BlackHole), pick your real microphone in Settings.",
            actions: [.openAppSettings]
        )
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
        case .openAppSettings:
            break // handled by the view
        }
    }

    /// Stop capturing
    func stop() async {
        captureStartedAt = nil
        await audioCaptureService.stopCapture()
        translationQueue.cancelAll()
        speechAnalyzerService.stop()
        liveDrafts.removeAll()
        liveTranslations.removeAll()
        liveSourceText = ""
        liveTranslation = ""
        clearTransientSegmentBookkeeping()

        // Stop health monitoring
        ollamaGuardian.stopHealthMonitoring()

        // Unload model to free memory
        try? await ollamaService.unloadModel()
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
        if speechAnalyzerService.currentLanguage != newSettings.sourceLanguage {
            speechAnalyzerService.setLanguage(newSettings.sourceLanguage)
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

        // Unload old model if model changed
        if oldSettings.ollamaModel != newSettings.ollamaModel {
            Task {
                try? await ollamaService.unloadModel()
            }
        }
    }

    // MARK: - Transcription Handling

    /// Handle a new transcription result from speech recognizer (any lane)
    private func handleTranscriptionResult(_ result: TranscriptionResult) {
        let lane = result.source

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

        let (newlyFinalized, draft, invalidatedTailCount) = segmenter.process(result: result)
        liveDrafts[lane] = draft
        refreshLiveSourceText()

        if invalidatedTailCount > 0 {
            rollbackTailSegments(count: invalidatedTailCount, source: lane)
            caption.updateOriginal(draft)
        }

        for text in newlyFinalized {
            let newSegment = TranslationSegment(sourceText: text, state: isPaused ? .pending : .translating, source: lane)
            activeTaskSegmentIds[lane, default: []].append(newSegment.id)
            segments.append(newSegment)
            trimSegmentsIfNeeded()

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

        updateLiveDraftTranslation(draft: draft, didFinalize: !newlyFinalized.isEmpty, source: lane)
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
}
