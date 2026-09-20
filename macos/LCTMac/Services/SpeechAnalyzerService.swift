import Foundation
import Speech
import AVFoundation
import os

/// Thread-safe container for state shared between @MainActor and audio threads.
/// Uses os_unfair_lock for low-overhead synchronization.
private final class SharedSpeechState: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _isRunning: Bool = false
    private var _bufferCount: Int = 0
    private var _request: SFSpeechAudioBufferRecognitionRequest?

    var isRunning: Bool {
        get { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; return _isRunning }
        set { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; _isRunning = newValue }
    }

    var bufferCount: Int {
        get { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; return _bufferCount }
        set { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; _bufferCount = newValue }
    }

    /// Atomically increment buffer count and return new value
    func incrementBufferCount() -> Int {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _bufferCount += 1
        return _bufferCount
    }

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; return _request }
        set { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; _request = newValue }
    }
}

/// One recognition lane: an independent request + task for a single AudioSource.
/// Lanes never share a request — interleaving two audio streams into one
/// SFSpeechAudioBufferRecognitionRequest sequentially concatenates the audio
/// and garbles recognition for both sources.
private final class RecognitionLane {
    let source: AudioSource
    let sharedState = SharedSpeechState()
    var task: SFSpeechRecognitionTask?
    var currentSegmentId: UUID = UUID()
    var lastTranscript: String = ""
    var sessionStartTime: Date = Date()

    init(source: AudioSource) {
        self.source = source
    }
}

/// Apple speech recognition service using SFSpeechRecognizer.
/// Supports up to two concurrent lanes (.system + .microphone), each with its
/// own recognition task; results are tagged with the producing AudioSource.
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

    // Lanes are accessed from audio threads via nonisolated append; they are
    // only created/torn down on MainActor while lanes are stopped, so unsafe
    // access is contained (same pattern as the service's callbacks).
    nonisolated(unsafe) private var lanes: [AudioSource: RecognitionLane] = [:]

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

    /// Start recognition for the given audio sources (one independent lane each).
    func start(sources: [AudioSource]) async throws {
        appLog("[SpeechAnalyzerService] start() called for lanes: \(sources.map { $0.rawValue })")

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
        appLog("[SpeechAnalyzerService] Stopping any existing recognition...")
        stop()

        for source in sources {
            startLane(source: source, recognizer: recognizer)
        }

        isRunning = true
        lastError = nil
        appLog("[SpeechAnalyzerService] ✅ Recognition started for \(sources.count) lane(s)")
    }

    /// Start a single lane: fresh request + recognition task.
    private func startLane(source: AudioSource, recognizer: SFSpeechRecognizer) {
        let lane = RecognitionLane(source: source)

        let request = makeRequest()
        appLog("[SpeechAnalyzerService] [\(source.rawValue)] Recognition request native format: \(request.nativeAudioFormat.sampleRate)Hz, \(request.nativeAudioFormat.channelCount)ch")

        lane.sharedState.request = request
        lane.sessionStartTime = Date()

        lane.task = recognizer.recognitionTask(with: request) { [weak self, weak lane] result, error in
            Task { @MainActor in
                guard let self = self, let lane = lane else { return }
                self.handleRecognitionResult(result: result, error: error, lane: lane)
            }
        }

        lane.sharedState.isRunning = true
        lanes[source] = lane
        appLog("[SpeechAnalyzerService] ✅ [\(source.rawValue)] lane started")
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false // Allow network if needed for better quality

        // Configure for real-time transcription
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        return request
    }

    /// Append audio buffer to the matching lane's recognition request - can be
    /// called from any thread. Thread safety is ensured by SharedSpeechState's
    /// os_unfair_lock. Buffers from unknown/inactive lanes are dropped.
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let lane = lanes[source], lane.sharedState.isRunning, let request = lane.sharedState.request else { return }
        let count = lane.sharedState.incrementBufferCount()
        if count % 50 == 1 {
            appLog("[SpeechAnalyzerService] 🎤 [\(source.rawValue)] Audio buffer #\(count) appended (format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch, frames: \(buffer.frameLength))")
        }
        request.append(buffer)
    }

    /// Whether any lane is actively recognizing. Callable from any thread.
    nonisolated var anyLaneRunning: Bool {
        lanes.values.contains { $0.sharedState.isRunning }
    }

    func stop() {
        for (_, lane) in lanes {
            lane.sharedState.request?.endAudio()
            lane.task?.cancel()
            lane.task = nil
            lane.sharedState.request = nil
            lane.sharedState.isRunning = false
            lane.lastTranscript = ""
        }
        lanes.removeAll()
        isRunning = false
    }

    // MARK: - Private Methods

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?, lane: RecognitionLane) {
        // Handle errors
        if let error = error {
            let nsError = error as NSError
            let description = error.localizedDescription
            appLog("[SpeechAnalyzerService] ⚠️ [\(lane.source.rawValue)] Recognition error: domain=\(nsError.domain) code=\(nsError.code) - \(description)")
            // Ignore cancellation errors
            if nsError.code == 216 || nsError.code == 1 || description.localizedCaseInsensitiveContains("cancel") {
                return
            }
            // kAFAssistantErrorDomain 1110 = "No speech detected": the task timed
            // out on silence. This is normal during quiet periods, not a failure —
            // don't surface an error banner; just restart the lane so it keeps listening.
            if nsError.code == 1110 {
                Task {
                    await self.restartLaneForContinuous(lane)
                }
                return
            }
            lastError = description
            return
        }

        guard let result = result else {
            appLog("[SpeechAnalyzerService] ⚠️ [\(lane.source.rawValue)] handleRecognitionResult called with nil result and nil error")
            return
        }
        appLog("[SpeechAnalyzerService] 📝 [\(lane.source.rawValue)] Recognition result: isFinal=\(result.isFinal), text=\"\(result.bestTranscription.formattedString.prefix(80))\"")

        let transcript = result.bestTranscription.formattedString

        // Skip if empty or unchanged
        if transcript.isEmpty || transcript == lane.lastTranscript {
            return
        }

        lane.lastTranscript = transcript

        // Calculate timing
        let (startTime, endTime) = segmentTiming(from: result, lane: lane)

        // Calculate confidence
        let confidence = calculateConfidence(from: result)

        // Create transcription result, tagged with the producing lane
        let transcription = TranscriptionResult(
            id: lane.currentSegmentId,
            text: transcript,
            speaker: nil,
            startTime: startTime,
            endTime: endTime,
            isVolatile: !result.isFinal,
            confidence: confidence,
            source: lane.source
        )

        // Notify callback
        onTranscription?(transcription)

        // Restart this lane's recognition for continuous transcription
        if result.isFinal {
            Task {
                await restartLaneForContinuous(lane)
            }
        }
    }

    private func segmentTiming(from result: SFSpeechRecognitionResult, lane: RecognitionLane) -> (TimeInterval, TimeInterval) {
        guard let lastSegment = result.bestTranscription.segments.last else {
            let elapsed = Date().timeIntervalSince(lane.sessionStartTime)
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

    private func restartLaneForContinuous(_ lane: RecognitionLane) async {
        guard lanes[lane.source] === lane, lane.sharedState.isRunning else { return }

        // Brief delay to prevent rapid restart loops if Apple fires isFinal in quick succession.
        // Reduced from 100ms to 50ms to minimize audio loss during the gap.
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        guard lanes[lane.source] === lane, lane.sharedState.isRunning else { return }

        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        // === Buffer gap minimization strategy ===
        // Create the NEW request BEFORE tearing down the old one.
        // This way, when we swap the request, appendAudioBuffer() immediately
        // starts feeding buffers to the new request with no gap.

        let newRequest = makeRequest()

        // Capture old references before swapping
        let oldRequest = lane.sharedState.request
        let oldTask = lane.task

        // Atomically swap the request pointer — appendAudioBuffer() will immediately
        // start appending to the new request from this point forward.
        lane.sharedState.request = newRequest
        lane.currentSegmentId = UUID()
        lane.lastTranscript = ""

        // Now tear down the old request/task. Any buffers that were appended to oldRequest
        // after endAudio() are silently discarded by Apple (documented behavior).
        oldRequest?.endAudio()
        oldTask?.cancel()

        // Start the new recognition task for this lane
        lane.task = recognizer.recognitionTask(with: newRequest) { [weak self, weak lane] result, error in
            Task { @MainActor in
                guard let self = self, let lane = lane else { return }
                self.handleRecognitionResult(result: result, error: error, lane: lane)
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
