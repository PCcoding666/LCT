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
    private let speakerManager: SpeakerManager
    
    // MARK: - Settings
    
    @Published var settings: AppSettings
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var audioBuffer = Data()
    private var translationTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init() {
        self.settings = AppSettings.load()
        self.audioCaptureService = AudioCaptureService(
            config: AudioCaptureConfig(
                captureSystemAudio: settings.captureSystemAudio,
                captureMicrophone: settings.captureMicrophone
            )
        )
        self.ollamaService = OllamaService(settings: settings)
        self.speakerManager = SpeakerManager()
        
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
        
        // Bind Ollama state
        ollamaService.$isTranslating
            .receive(on: DispatchQueue.main)
            .assign(to: &$isTranslating)
        
        ollamaService.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOllamaConnected)
        
        // Bind errors
        audioCaptureService.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.errorMessage = error
                }
            }
            .store(in: &cancellables)
        
        ollamaService.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.errorMessage = error
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Actions
    
    /// Start capturing and translating
    func start() async {
        do {
            errorMessage = nil
            
            // Check Ollama connection
            let isConnected = await ollamaService.checkHealth()
            if !isConnected {
                errorMessage = "Cannot connect to Ollama. Please ensure it's running."
                return
            }
            
            // Setup audio callback
            audioCaptureService.onAudioData = { [weak self] data in
                self?.handleAudioData(data)
            }
            
            // Start audio capture
            try await audioCaptureService.startCapture()
            
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    /// Stop capturing
    func stop() async {
        await audioCaptureService.stopCapture()
        translationTask?.cancel()
        
        // Unload model to free memory
        try? await ollamaService.unloadModel()
    }
    
    /// Toggle pause state
    func togglePause() {
        isPaused.toggle()
        if isPaused {
            currentTranslatedText = "[Paused]"
        }
    }
    
    /// Clear all transcriptions and translations
    func clear() {
        segments.removeAll()
        recentSegments.removeAll()
        currentOriginalText = ""
        currentTranslatedText = ""
        translationHistory.removeAll()
        speakerManager.clear()
    }
    
    /// Update settings
    func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
        newSettings.save()
        
        // Update services
        audioCaptureService.config = AudioCaptureConfig(
            captureSystemAudio: newSettings.captureSystemAudio,
            captureMicrophone: newSettings.captureMicrophone
        )
        ollamaService.updateSettings(newSettings)
    }
    
    // MARK: - Audio Processing
    
    private func handleAudioData(_ data: Data) {
        guard !isPaused else { return }
        
        // Accumulate audio data
        audioBuffer.append(data)
        
        // Process when we have enough data (e.g., 1 second of audio at 16kHz = 32000 bytes)
        let bufferThreshold = 32000
        if audioBuffer.count >= bufferThreshold {
            let dataToProcess = audioBuffer
            audioBuffer = Data()
            
            // Send to WhisperEngine for transcription
            Task {
                await processAudioChunk(dataToProcess)
            }
        }
    }
    
    private func processAudioChunk(_ data: Data) async {
        // TODO: Send to WhisperEngine via IPC
        // For now, this is a placeholder that will be implemented in Phase 2
        
        // Simulated transcription result for testing
        // In production, this will come from WhisperEngine
    }
    
    /// Add a new transcription result
    func addTranscription(_ result: TranscriptionResult) {
        segments.append(result)
        
        // Update recent segments
        let maxRecent = settings.maxDisplayCards
        recentSegments = Array(segments.suffix(maxRecent))
        
        // Update current text
        currentOriginalText = result.text
        
        // Translate if not paused
        if !isPaused {
            translateCurrentText(result.text, speaker: result.speaker)
        }
    }
    
    /// Translate the current text
    private func translateCurrentText(_ text: String, speaker: String?) {
        translationTask?.cancel()
        
        translationTask = Task {
            do {
                let (translatedText, latencyMs) = try await ollamaService.translate(
                    text: text,
                    context: translationHistory
                )
                
                guard !Task.isCancelled else { return }
                
                self.currentTranslatedText = translatedText
                self.lastLatencyMs = latencyMs
                
                // Add to history
                let entry = TranslationEntry(
                    sourceText: text,
                    translatedText: translatedText,
                    speaker: speaker,
                    targetLanguage: settings.targetLanguage.displayName,
                    latencyMs: latencyMs
                )
                self.translationHistory.append(entry)
                
                // Keep history limited
                if translationHistory.count > 100 {
                    translationHistory.removeFirst()
                }
                
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                    self.currentTranslatedText = "[ERROR] \(error.localizedDescription)"
                }
            }
        }
    }
    
    /// Copy current translation to clipboard
    func copyToClipboard() {
        let text = "\(currentOriginalText)\n\(currentTranslatedText)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
