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

    /// Current error message
    @Published var errorMessage: String?

    /// Last translation latency
    @Published var lastLatencyMs: Int = 0

    /// Ollama connection status
    @Published var isOllamaConnected: Bool = false

    // MARK: - Services

    private let audioCaptureService: AudioCaptureService
    private let ollamaService: OllamaService
    private let translationQueue: TranslationQueue
    private let speakerManager: SpeakerManager
    private let speechAnalyzerService: SpeechAnalyzerService
    private let caption: Caption
    private let captionSegmenter = CaptionSegmenter()
    private let ollamaGuardian = OllamaGuardian.shared
    private let historyService = HistoryService()

    // MARK: - Settings

    @Published var settings: AppSettings

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var activeTranscriptionTaskId: UUID?
    private var segmentTaskIdsBySegmentId: [UUID: UUID] = [:]
    private var historyEntryIdsBySegmentId: [UUID: UUID] = [:]

    // MARK: - Initialization

    init() {
        let loadedSettings = AppSettings.load()
        self.settings = loadedSettings
        self.audioCaptureService = AudioCaptureService(
            config: AudioCaptureConfig(
                captureSystemAudio: loadedSettings.captureSystemAudio,
                captureMicrophone: loadedSettings.captureMicrophone
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
            errorMessage = persistenceError
        }
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind audio level
        audioCaptureService.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

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

        // Bind errors
        audioCaptureService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)

        ollamaService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)

        speechAnalyzerService.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.errorMessage = error
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
            self.errorMessage = "Audio capture interrupted: \(error.localizedDescription). Please click Start to resume."
        }

    }

    // MARK: - Actions

    /// Start capturing and translating
    func start() async {
        appLog("[TranscriptionVM] ▶️ start() called")

        do {
            errorMessage = nil

            // Check if we need screen capture (system audio) or just microphone
            let needsScreenCapture = settings.captureSystemAudio
            appLog("[TranscriptionVM] needsScreenCapture: \(needsScreenCapture)")
            appLog("[TranscriptionVM] captureMicrophone: \(settings.captureMicrophone)")

            if needsScreenCapture {
                appLog("[TranscriptionVM] Checking screen capture permission...")
                // Check screen capture permission first
                let hasPermission = await audioCaptureService.checkPermission()
                appLog("[TranscriptionVM] Screen capture permission: \(hasPermission)")

                if !hasPermission {
                    // If microphone is also enabled, offer to continue with microphone only
                    if settings.captureMicrophone {
                        appLog("[TranscriptionVM] Screen capture denied, will fall back to microphone-only mode")
                        // Continue with microphone only - don't return
                    } else {
                        appLog("[TranscriptionVM] ❌ No permission and no microphone fallback")
                        errorMessage = "Screen recording permission required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
                        // Open system settings automatically
                        AudioCaptureService.openScreenRecordingSettings()
                        return
                    }
                }
            }

            // Ensure Ollama is running (will start it if needed)
            appLog("[TranscriptionVM] Ensuring Ollama is running...")
            do {
                try await ollamaGuardian.ensureRunning()
                appLog("[TranscriptionVM] ✅ Ollama is running")
            } catch {
                appLog("[TranscriptionVM] ❌ Ollama error: \(error)")
                errorMessage = "Cannot start Ollama: \(error.localizedDescription)"
                return
            }

            // Check Ollama connection
            appLog("[TranscriptionVM] Checking Ollama connection...")
            let isConnected = await ollamaService.checkHealth()
            appLog("[TranscriptionVM] Ollama connected: \(isConnected)")
            if !isConnected {
                errorMessage = "Cannot connect to Ollama at \(settings.ollamaURL). Please check your settings."
                return
            }

            do {
                let availableModels = try await ollamaService.getAvailableModels()
                guard isModelInstalled(settings.ollamaModel, in: availableModels) else {
                    errorMessage = "Ollama model '\(settings.ollamaModel)' is not installed. Install it in setup or run: ollama pull \(settings.ollamaModel)"
                    return
                }
            } catch {
                errorMessage = "Cannot list Ollama models: \(error.localizedDescription)"
                return
            }

            errorMessage = "Loading translation model. The first run may take longer..."
            do {
                let latencyMs = try await ollamaService.prewarmModel()
                appLog("[TranscriptionVM] ✅ Ollama model prewarmed in \(latencyMs)ms")
                errorMessage = nil
            } catch let error as OllamaError {
                errorMessage = "Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)"
                return
            } catch {
                errorMessage = "Cannot load model '\(settings.ollamaModel)': \(error.localizedDescription)"
                return
            }

            // Update speech recognizer language
            appLog("[TranscriptionVM] Setting speech language: \(settings.sourceLanguage.displayName)")
            speechAnalyzerService.setLanguage(settings.sourceLanguage)

            // Start speech recognition
            appLog("[TranscriptionVM] Starting speech recognition...")
            try await speechAnalyzerService.start()
            appLog("[TranscriptionVM] ✅ Speech recognition started")

            // Connect audio capture to speech recognizer
            let analyzer = self.speechAnalyzerService
            audioCaptureService.onAudioBuffer = { [weak analyzer] buffer in
                analyzer?.appendAudioBuffer(buffer)
            }
            audioCaptureService.onAudioData = nil

            // Start audio capture (will use microphone if screen capture fails)
            appLog("[TranscriptionVM] Starting audio capture...")
            do {
                try await audioCaptureService.startCapture()
                appLog("[TranscriptionVM] ✅ Audio capture started (screen + mic)")
            } catch AudioCaptureError.noPermission where settings.captureMicrophone {
                // Fall back to microphone-only mode
                appLog("[TranscriptionVM] Screen capture failed, falling back to microphone-only mode")
                try await audioCaptureService.startMicrophoneOnlyCapture()
                appLog("[TranscriptionVM] ✅ Microphone-only capture started")
            }

            appLog("[TranscriptionVM] ✅ start() completed successfully")

            // Start health monitoring for Ollama
            ollamaGuardian.startHealthMonitoring(interval: 30)

        } catch let error as SpeechAnalyzerError {
            switch error {
            case .notAuthorized:
                errorMessage = "Speech recognition permission required. Please grant permission in System Settings > Privacy & Security > Speech Recognition."
            case .recognizerUnavailable:
                errorMessage = "Speech recognizer is unavailable for \(settings.sourceLanguage.displayName). Please try a different language."
            case .audioSessionFailed:
                errorMessage = "Failed to configure audio session."
            }
        } catch let error as AudioCaptureError {
            switch error {
            case .noPermission:
                errorMessage = "Screen recording permission required. Please grant permission in System Settings > Privacy & Security > Screen Recording."
                AudioCaptureService.openScreenRecordingSettings()
            case .noDisplaysAvailable:
                errorMessage = "No displays available for audio capture."
            case .captureSetupFailed(let message):
                errorMessage = "Capture setup failed: \(message)"
            case .audioProcessingFailed(let message):
                errorMessage = "Audio processing failed: \(message)"
            case .streamInterrupted(let message):
                errorMessage = "Audio stream interrupted: \(message)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stop capturing
    func stop() async {
        await audioCaptureService.stopCapture()
        translationQueue.cancelAll()
        speechAnalyzerService.stop()
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
        }
    }

    /// Clear all transcriptions and translations
    func clear() {
        segments.removeAll()
        liveSourceText = ""
        captionSegmenter.reset()
        translationHistory.removeAll()
        speakerManager.clear()
        caption.clear()
        clearTransientSegmentBookkeeping()
    }

    /// Clear all persistent history from SQLite
    func clearPersistentHistory() {
        do {
            try historyService.clearHistory()
        } catch {
            appLog("[TranscriptionVM] Failed to clear history: \(error)")
        }
    }

    /// Load persistent history from SQLite
    func loadPersistentHistory(limit: Int = 200) async -> [TranslationEntry] {
        do {
            return try await historyService.loadRecentTranslationsAsync(limit: limit)
        } catch {
            appLog("[TranscriptionVM] Failed to load history: \(error)")
            return []
        }
    }

    /// Search persistent history
    func searchPersistentHistory(query: String) -> [TranslationEntry] {
        do {
            return try historyService.searchTranslations(query: query)
        } catch {
            appLog("[TranscriptionVM] Failed to search history: \(error)")
            return []
        }
    }

    /// Delete a single history entry from SQLite
    func deletePersistentEntry(_ entry: TranslationEntry) {
        do {
            try historyService.deleteTranslation(withId: entry.id)
        } catch {
            appLog("[TranscriptionVM] Failed to delete entry: \(error)")
        }
    }

    /// Export history to CSV string
    func exportHistoryCSV() -> String? {
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
            captureMicrophone: newSettings.captureMicrophone
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
                || oldSettings.sourceLanguage != newSettings.sourceLanguage
                || oldSettings.ollamaModel != newSettings.ollamaModel
            if needsRestart {
                errorMessage = "Some settings require restarting capture to take effect. Please click Stop then Start."
            }
        }

        if !didSaveSettings {
            errorMessage = saveError ?? "Settings save failed. Your changes are active for this session but may not persist after restart."
        }

        // Unload old model if model changed
        if oldSettings.ollamaModel != newSettings.ollamaModel {
            Task {
                try? await ollamaService.unloadModel()
            }
        }
    }

    // MARK: - Transcription Handling

    /// Handle a new transcription result from speech recognizer
    private func handleTranscriptionResult(_ result: TranscriptionResult) {
        if activeTranscriptionTaskId != result.id {
            if let oldTaskId = activeTranscriptionTaskId {
                discardRollbackBookkeeping(for: oldTaskId)
            }
            activeTranscriptionTaskId = result.id
        }

        let (newlyFinalized, draft, didRollback) = captionSegmenter.process(result: result)
        liveSourceText = draft

        if didRollback {
            rollbackSegments(for: result.id)
            caption.updateOriginal(draft)
        }

        for text in newlyFinalized {
            let newSegment = TranslationSegment(sourceText: text, state: .translating)
            segmentTaskIdsBySegmentId[newSegment.id] = result.id
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
    }

    // MARK: - Translation Handling

    /// Handle translation result from queue
    private func handleTranslationResult(_ result: TranslationQueueResult) {
        let cleanedText = TextUtils.cleanTranslationOutput(result.translatedText)

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
            if segmentTaskIdsBySegmentId[result.segmentId] == activeTranscriptionTaskId {
                historyEntryIdsBySegmentId[result.segmentId] = entry.id
            }
            caption.addToContext(entry)

            Task { try? await historyService.logTranslationAsync(entry) }
            Task {
                try? await historyService.pruneHistoryAsync(
                    retentionDays: settings.historyRetentionDays,
                    maxEntries: settings.historyMaxEntries
                )
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

    private func rollbackSegments(for taskId: UUID) {
        let staleSegmentIds = Set(segmentTaskIdsBySegmentId.compactMap { segmentId, mappedTaskId in
            mappedTaskId == taskId ? segmentId : nil
        })

        guard !staleSegmentIds.isEmpty else { return }

        appLog("[TranscriptionVM] ASR rollback detected; canceling \(staleSegmentIds.count) stale segment(s)")
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
            segmentTaskIdsBySegmentId.removeValue(forKey: segmentId)
            historyEntryIdsBySegmentId.removeValue(forKey: segmentId)
        }
    }

    private func discardRollbackBookkeeping(for taskId: UUID) {
        let oldSegmentIds = Set(segmentTaskIdsBySegmentId.compactMap { segmentId, mappedTaskId in
            mappedTaskId == taskId ? segmentId : nil
        })

        for segmentId in oldSegmentIds {
            segmentTaskIdsBySegmentId.removeValue(forKey: segmentId)
            historyEntryIdsBySegmentId.removeValue(forKey: segmentId)
        }
    }

    private func clearTransientSegmentBookkeeping() {
        activeTranscriptionTaskId = nil
        segmentTaskIdsBySegmentId.removeAll()
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
