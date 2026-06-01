import Foundation
import Speech
import AVFoundation

/// Apple speech recognition service using SFSpeechRecognizer
@MainActor
class SpeechAnalyzerService: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentLanguage: SourceLanguage = .english
    
    // MARK: - Callback
    var onTranscription: ((TranscriptionResult) -> Void)?
    
    // MARK: - Private Properties
    private var speechRecognizer: SFSpeechRecognizer?
    // Mark as nonisolated(unsafe) to allow thread-safe access from appendAudioBuffer
    // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe according to Apple documentation
    nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastTranscript: String = ""
    private var lastFinalTranscript: String = ""
    private var sessionStartTime: Date = Date()
    // Flag to track running state for nonisolated access
    nonisolated(unsafe) private var _isRunningFlag: Bool = false
    // Debug: buffer counter to verify audio is flowing
    nonisolated(unsafe) private var _bufferCount: Int = 0
    // Audio format converter for sample rate conversion (e.g., 48kHz → 16kHz)
    nonisolated(unsafe) private var _audioConverter: AVAudioConverter?
    nonisolated(unsafe) private var _targetFormat: AVAudioFormat?
    
    // MARK: - Initialization
    
    init(language: SourceLanguage = .english) {
        self.currentLanguage = language
        // Note: SFSpeechRecognizer is NOT created here to avoid triggering
        // a TCC privacy check at app launch before the UI is ready.
        // It will be created lazily when start() or setLanguage() is called.
    }
    
    /// Lazily create the speech recognizer when actually needed
    private func ensureRecognizer() {
        if speechRecognizer == nil {
            speechRecognizer = SFSpeechRecognizer(locale: currentLanguage.locale)
        }
    }
    
    // MARK: - Language Management
    
    /// Update the recognition language
    func setLanguage(_ language: SourceLanguage) {
        // Only change if different
        guard language != currentLanguage else { return }
        
        let wasRunning = isRunning
        if wasRunning {
            stop()
        }
        
        currentLanguage = language
        speechRecognizer = SFSpeechRecognizer(locale: language.locale)
        
        // Note: We don't auto-restart here anymore to avoid race conditions
        // The caller should restart if needed
    }
    
    /// Check if a language is available on this device
    func isLanguageAvailable(_ language: SourceLanguage) -> Bool {
        let recognizer = SFSpeechRecognizer(locale: language.locale)
        return recognizer?.isAvailable ?? false
    }
    
    /// Get all available languages on this device
    func availableLanguages() -> [SourceLanguage] {
        SourceLanguage.allCases.filter { isLanguageAvailable($0) }
    }
    
    // MARK: - Authorization
    
    nonisolated func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        appLog("[SpeechAnalyzerService] requestAuthorization() - checking current status...")
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        appLog("[SpeechAnalyzerService] Current authorization status: \(currentStatus.rawValue)")
        
        if currentStatus == .notDetermined {
            appLog("[SpeechAnalyzerService] Status is notDetermined, requesting authorization from system...")
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        
        return currentStatus
    }
    
    // MARK: - Recognition Control
    
    func start() async throws {
        appLog("[SpeechAnalyzerService] start() called")
        
        appLog("[SpeechAnalyzerService] Requesting/checking authorization status...")
        let status = await requestAuthorization()
        appLog("[SpeechAnalyzerService] Authorization status: \(status.rawValue)")
        
        // If not authorized, fail immediately
        if status != .authorized {
            lastError = "Speech recognition permission not granted. Please enable it in System Settings."
            appLog("[SpeechAnalyzerService] ❌ Not authorized (status: \(status.rawValue))")
            throw SpeechAnalyzerError.notAuthorized
        }
        
        // Lazily create recognizer now that we have authorization
        ensureRecognizer()
        
        // Check recognizer availability
        appLog("[SpeechAnalyzerService] Checking recognizer availability...")
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            lastError = "Speech recognizer is unavailable for \(currentLanguage.displayName)."
            appLog("[SpeechAnalyzerService] ❌ Recognizer unavailable")
            throw SpeechAnalyzerError.recognizerUnavailable
        }
        appLog("[SpeechAnalyzerService] Recognizer available: \(recognizer.isAvailable)")
        
        // Stop any existing recognition
        // Stop any existing recognition
        appLog("[SpeechAnalyzerService] Stopping any existing recognition...")
        stop()
        
        // Create new recognition request
        appLog("[SpeechAnalyzerService] Creating recognition request...")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false // Allow network if needed for better quality
        
        // Configure for real-time transcription
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        
        // Log the native audio format expected by the recognizer
        let nativeFormat = request.nativeAudioFormat
        appLog("[SpeechAnalyzerService] Recognition request native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")
        
        recognitionRequest = request
        sessionStartTime = Date()
        lastTranscript = ""
        lastFinalTranscript = ""
        
        // Start recognition task
        appLog("[SpeechAnalyzerService] Starting recognition task on main thread...")
        
        let weakSelf = self
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                weakSelf.handleRecognitionResult(result: result, error: error)
            }
        }
        
        isRunning = true
        _isRunningFlag = true
        _bufferCount = 0
        lastError = nil
        appLog("[SpeechAnalyzerService] ✅ Recognition started successfully")
    }
    
    /// Append audio buffer to recognition request - can be called from any thread
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard _isRunningFlag, let request = recognitionRequest else { return }
        _bufferCount += 1
        if _bufferCount % 50 == 1 {
            appLog("[SpeechAnalyzerService] 🎤 Audio buffer #\(_bufferCount) appended (format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch, frames: \(buffer.frameLength))")
        }
        request.append(buffer)
    }
    
    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRunning = false
        _isRunningFlag = false
        lastTranscript = ""
    }
    
    // MARK: - Private Methods
    
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        // Handle errors
        if let error = error {
            let nsError = error as NSError
            let description = error.localizedDescription
            appLog("[SpeechAnalyzerService] ⚠️ Recognition error: domain=\(nsError.domain) code=\(nsError.code) - \(description)")
            // Ignore cancellation errors
            if nsError.code == 216 || nsError.code == 1 || description.localizedCaseInsensitiveContains("cancel") {
                return
            }
            lastError = description
            return
        }
        
        guard let result = result else {
            appLog("[SpeechAnalyzerService] ⚠️ handleRecognitionResult called with nil result and nil error")
            return
        }
        appLog("[SpeechAnalyzerService] 📝 Recognition result: isFinal=\(result.isFinal), text=\"\(result.bestTranscription.formattedString.prefix(80))\"")
        
        let transcript = result.bestTranscription.formattedString
        
        // Skip if empty or unchanged
        if transcript.isEmpty || transcript == lastTranscript {
            return
        }
        
        lastTranscript = transcript
        
        // Calculate timing
        let (startTime, endTime) = segmentTiming(from: result)
        
        // Calculate confidence
        let confidence = calculateConfidence(from: result)
        
        // Create transcription result
        let transcription = TranscriptionResult(
            text: transcript,
            speaker: nil,
            startTime: startTime,
            endTime: endTime,
            isVolatile: !result.isFinal,
            confidence: confidence
        )
        
        // Notify callback
        onTranscription?(transcription)
        
        // Update last final transcript
        if result.isFinal {
            lastFinalTranscript = transcript
            
            // Restart recognition for continuous transcription
            Task {
                await restartRecognitionForContinuous()
            }
        }
    }
    
    private func segmentTiming(from result: SFSpeechRecognitionResult) -> (TimeInterval, TimeInterval) {
        guard let lastSegment = result.bestTranscription.segments.last else {
            let elapsed = Date().timeIntervalSince(sessionStartTime)
            return (elapsed - 1, elapsed)
        }
        let start = lastSegment.timestamp
        let end = lastSegment.timestamp + lastSegment.duration
        return (start, end)
    }
    
    private func calculateConfidence(from result: SFSpeechRecognitionResult) -> Float {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return 0.0 }
        
        let totalConfidence = segments.reduce(0.0) { $0 + $1.confidence }
        return totalConfidence / Float(segments.count)
    }
    
    private func restartRecognitionForContinuous() async {
        guard isRunning else { return }
        
        // Brief delay to prevent rapid restart loops if Apple fires isFinal in quick succession.
        // Reduced from 100ms to 50ms to minimize audio loss during the gap.
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        guard isRunning else { return }
        
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }
        
        // === Buffer gap minimization strategy ===
        // Create the NEW request BEFORE tearing down the old one.
        // This way, when we swap `recognitionRequest`, `appendAudioBuffer()` immediately
        // starts feeding buffers to the new request with no gap.
        
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            newRequest.addsPunctuation = true
        }
        
        // Capture old references before swapping
        let oldRequest = recognitionRequest
        let oldTask = recognitionTask
        
        // Atomically swap the request pointer — appendAudioBuffer() will immediately
        // start appending to the new request from this point forward.
        recognitionRequest = newRequest
        lastTranscript = ""
        
        // Now tear down the old request/task. Any buffers that were appended to oldRequest
        // after endAudio() are silently discarded by Apple (documented behavior).
        oldRequest?.endAudio()
        oldTask?.cancel()
        
        // Start the new recognition task
        let weakSelf = self
        recognitionTask = recognizer.recognitionTask(with: newRequest) { result, error in
            Task { @MainActor in
                weakSelf.handleRecognitionResult(result: result, error: error)
            }
        }
    }
}

// MARK: - Error Types

enum SpeechAnalyzerError: Error, LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioSessionFailed
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable"
        case .audioSessionFailed:
            return "Failed to configure audio session"
        }
    }
}
