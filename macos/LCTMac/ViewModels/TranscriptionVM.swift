import SwiftUI
import Combine

/// Main transcription and translation view model
@MainActor
class TranscriptionViewModel: ObservableObject {
    // MARK: - Published Properties
    
    /// Current transcription segments
    @Published var segments: [TranscriptionResult] = []
    
    /// Recent segments for display (limited count)
    @Published var recentSegments: [TranscriptionResult] = []
    
    /// Current original text being processed
    @Published var currentOriginalText: String = ""
    
    /// Current translated text
    @Published var currentTranslatedText: String = ""
    
    /// Streaming translation text (real-time update)
    @Published var streamingTranslatedText: String = ""
    
    /// Recent translation pairs for display (configurable count)
    @Published var recentTranslations: [(original: String, translated: String)] = []
    
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
    private let ollamaGuardian = OllamaGuardian.shared
    private let historyService = HistoryService()

    // MARK: - Settings
    
    @Published var settings: AppSettings
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    
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
        
        // Handle streaming updates (real-time token updates)
        translationQueue.onStreamingUpdate = { [weak self] streamingText in
            self?.streamingTranslatedText = streamingText
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
        
        // Bind streaming text from queue
        translationQueue.$streamingText
            .receive(on: DispatchQueue.main)
            .assign(to: &$streamingTranslatedText)
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
        
        // Stop health monitoring
        ollamaGuardian.stopHealthMonitoring()

        // Unload model to free memory
        try? await ollamaService.unloadModel()
    }
    
    /// Toggle pause state
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            currentTranslatedText = "[Paused]"
            translationQueue.cancelAll()
        }
    }
    
    /// Clear all transcriptions and translations
    func clear() {
        segments.removeAll()
        recentSegments.removeAll()
        currentOriginalText = ""
        currentTranslatedText = ""
        streamingTranslatedText = ""
        recentTranslations.removeAll()
        translationHistory.removeAll()
        speakerManager.clear()
        caption.clear()
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
        newSettings.save()
        
        // Update services
        audioCaptureService.config = AudioCaptureConfig(
            captureSystemAudio: newSettings.captureSystemAudio,
            captureMicrophone: newSettings.captureMicrophone
        )
        ollamaService.updateSettings(newSettings)
        caption.maxContextEntries = newSettings.maxContextEntries
        
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
        // Note: We do NOT filter out volatile results based on confidence here because 
        // Apple's SFSpeechRecognizer often returns 0.0 confidence for real-time (volatile) 
        // segments until they are fully finalized. Filtering them out causes the UI to show nothing.
        
        // Update segments
        if let lastIndex = segments.lastIndex(where: { $0.isVolatile }) {
            segments[lastIndex] = result
        } else {
            segments.append(result)
        }

        // Update recent segments for display
        let maxRecent = settings.maxDisplayCards
        recentSegments = Array(segments.suffix(maxRecent))

        // Update current text
        currentOriginalText = result.text
        caption.updateOriginal(result.text)

        // Enqueue for translation if not paused
        if !isPaused {
            let context = settings.contextAware ? caption.getContextForTranslation() : []
            translationQueue.enqueue(
                text: result.text,
                context: context,
                priority: result.isVolatile ? .low : .high,
                isFinal: !result.isVolatile
            )
        }
    }
    
    // MARK: - Translation Handling
    
    /// Handle translation result from queue
    private func handleTranslationResult(_ result: TranslationQueueResult) {
        // Clean up translation output
        let cleanedText = TextUtils.cleanTranslationOutput(result.translatedText)
        
        currentTranslatedText = cleanedText
        lastLatencyMs = result.latencyMs
        caption.updateTranslation(cleanedText)
        
        // Add to history if successful
        if result.success {
            let entry = TranslationEntry(
                sourceText: result.originalText,
                translatedText: cleanedText,
                speaker: nil,
                targetLanguage: settings.targetLanguage.displayName,
                latencyMs: result.latencyMs
            )
            translationHistory.append(entry)
            caption.addToContext(entry)
            
            // Persist to SQLite
            Task {
                try? await historyService.logTranslationAsync(entry)
            }
            
            // Update recent translations (keep last N pairs for display)
            recentTranslations.append((original: result.originalText, translated: cleanedText))
            let maxDisplay = settings.captionLogMax  // Use captionLogMax setting (default 2-3)
            if recentTranslations.count > maxDisplay {
                recentTranslations.removeFirst(recentTranslations.count - maxDisplay)
            }
            
            // Keep history limited
            if translationHistory.count > 100 {
                translationHistory.removeFirst()
            }
        }
        
        // Clear streaming text after complete
        streamingTranslatedText = ""
    }
    
    /// Copy current translation to clipboard
    func copyToClipboard() {
        let text = "\(currentOriginalText)\n\(currentTranslatedText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
