import Foundation
import Combine
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

/// Pure decision logic for recognition-lane callbacks and restarts.
/// Deliberately free of any Speech-framework dependency so it can be
/// unit-tested directly.
struct RecognitionRestartPolicy: Equatable {
    /// A callback is only worth processing when it comes from the lane's
    /// current recognition task: the lane must still be the active one and the
    /// generation captured when the task was created must still match the
    /// lane's generation.
    static func shouldProcessCallback(laneIsCurrent: Bool, callbackGeneration: Int, currentGeneration: Int) -> Bool {
        laneIsCurrent && callbackGeneration == currentGeneration
    }

    static let initialBackoff: TimeInterval = 0.3
    static let maxBackoff: TimeInterval = 3.0

    /// Consecutive no-speech (error 1110) restarts since the last non-empty transcript.
    private(set) var consecutiveNoSpeechRestarts: Int = 0

    /// Register a no-speech timeout and return how long to wait before the
    /// replacement task starts: 0.3s, doubling per consecutive timeout,
    /// capped at 3s.
    mutating func registerNoSpeechRestart() -> TimeInterval {
        let delay = min(Self.initialBackoff * pow(2.0, Double(consecutiveNoSpeechRestarts)), Self.maxBackoff)
        consecutiveNoSpeechRestarts += 1
        return delay
    }

    /// A non-empty transcript means speech is present — reset the backoff.
    mutating func noteNonEmptyTranscript() {
        consecutiveNoSpeechRestarts = 0
    }
}

/// Per-lane counters. Numbers only (never transcript content) so they are
/// safe to write to the log — see DiagnosticsPrivacyTests.
struct LaneStats: Equatable {
    var resultCount = 0
    /// Results the recognizer marked as final (SpeechAnalyzer engine).
    var finalCount = 0
    /// Results-stream or runtime errors (SpeechAnalyzer engine; the legacy
    /// engine tracks its 1110s and other errors via the fields below).
    var errorCount = 0
    var error1110Count = 0
    var restartCount = 0
    var staleCallbackCount = 0
}

/// One recognition lane: an independent recognizer + request + task for a
/// single AudioSource. Lanes never share a request — interleaving two audio
/// streams into one SFSpeechAudioBufferRecognitionRequest sequentially
/// concatenates the audio and garbles recognition for both sources. Each lane
/// also owns its SFSpeechRecognizer so lanes can run different locales.
private final class RecognitionLane {
    let source: AudioSource
    let recognizer: SFSpeechRecognizer
    let sharedState = SharedSpeechState()
    var task: SFSpeechRecognitionTask?
    /// Monotonic id of the lane's current recognition task. Bumped every time
    /// a replacement task is scheduled, so a late callback from a torn-down
    /// task is recognized as stale and dropped.
    var generation: Int = 0
    var policy = RecognitionRestartPolicy()
    var stats = LaneStats()
    var currentSegmentId: UUID = UUID()
    var lastTranscript: String = ""
    var sessionStartTime: Date = Date()

    init(source: AudioSource, recognizer: SFSpeechRecognizer) {
        self.source = source
        self.recognizer = recognizer
    }
}

/// Lock-protected registry of the active lanes. Read by audio threads
/// (appendAudioBuffer) and written on MainActor (start/stop/restart).
private final class LaneRegistry: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _lanes: [AudioSource: RecognitionLane] = [:]

    func lane(for source: AudioSource) -> RecognitionLane? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _lanes[source]
    }

    func set(_ lane: RecognitionLane, for source: AudioSource) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _lanes[source] = lane
    }

    /// Remove all lanes atomically and return them so the caller can tear
    /// them down outside the lock.
    func removeAllLanes() -> [RecognitionLane] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let lanes = Array(_lanes.values)
        _lanes.removeAll()
        return lanes
    }

    var allLanes: [RecognitionLane] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return Array(_lanes.values)
    }

    var anyRunning: Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _lanes.values.contains { $0.sharedState.isRunning }
    }
}

/// Apple speech recognition service using SFSpeechRecognizer.
/// Supports up to two concurrent lanes (.system + .microphone), each with its
/// own recognizer and recognition task; results are tagged with the producing
/// AudioSource.
@MainActor
class SpeechAnalyzerService: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var currentLanguage: SourceLanguage = .english

    // MARK: - Callback
    var onTranscription: ((TranscriptionResult) -> Void)?

    // MARK: - Private Properties

    /// Delay before replacing a task that ended with isFinal (a natural
    /// segment boundary). Short, because speech is flowing and the request
    /// swap already eliminates the audio gap.
    private static let finalRestartDelay: TimeInterval = 0.05

    private let laneRegistry = LaneRegistry()

    // MARK: - Initialization

    init(language: SourceLanguage = .english) {
        self.currentLanguage = language
        // Note: SFSpeechRecognizer instances are NOT created here to avoid
        // triggering a TCC privacy check at app launch before the UI is ready.
        // They are created per lane when start() is called.
    }

    // MARK: - Language Management

    /// Update the recognition language used for lanes that don't get an
    /// explicit per-lane language in start(sources:languages:).
    func setLanguage(_ language: SourceLanguage) {
        // Only change if different
        guard language != currentLanguage else { return }

        let wasRunning = isRunning
        if wasRunning {
            stop()
        }

        currentLanguage = language

        // Note: We don't auto-restart here anymore to avoid race conditions
        // The caller should restart if needed. Per-lane recognizers are
        // created fresh on the next start(), so nothing else to update here.
    }

    /// Check if a language is available on this device
    func isLanguageAvailable(_ language: SourceLanguage) -> Bool {
        let recognizer = SFSpeechRecognizer(locale: language.locale)
        return recognizer?.isAvailable ?? false
    }

    /// Whether on-device recognition is available for a locale. A missing
    /// recognizer or missing on-device model both count as unavailable — we
    /// never fall back to Apple's network recognition.
    func isOnDeviceRecognitionAvailable(locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
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
    /// `languages` optionally overrides the recognition language per source;
    /// sources without an entry use `currentLanguage`.
    func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage] = [:]) async throws {
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

        // Resolve every lane's recognizer up front so a configuration problem
        // fails before any lane starts. On-device recognition is mandatory —
        // we never silently send audio to Apple's servers.
        appLog("[SpeechAnalyzerService] Checking recognizer availability...")
        var recognizers: [AudioSource: SFSpeechRecognizer] = [:]
        for source in sources {
            let language = languages[source] ?? currentLanguage
            guard let recognizer = SFSpeechRecognizer(locale: language.locale), recognizer.isAvailable else {
                lastError = "Speech recognizer is unavailable for \(language.displayName)."
                appLog("[SpeechAnalyzerService] ❌ Recognizer unavailable for \(language.displayName)")
                throw SpeechAnalyzerError.recognizerUnavailable
            }
            guard recognizer.supportsOnDeviceRecognition else {
                lastError = "On-device speech recognition is not available for \(language.displayName)."
                appLog("[SpeechAnalyzerService] ❌ On-device recognition unavailable for \(language.displayName)")
                throw SpeechAnalyzerError.onDeviceRecognitionUnavailable
            }
            recognizers[source] = recognizer
        }

        // Stop any existing recognition
        appLog("[SpeechAnalyzerService] Stopping any existing recognition...")
        stop()

        for source in sources {
            guard let recognizer = recognizers[source] else { continue }
            startLane(source: source, recognizer: recognizer)
        }

        isRunning = true
        lastError = nil
        appLog("[SpeechAnalyzerService] ✅ Recognition started for \(sources.count) lane(s)")
    }

    /// Start a single lane: fresh request + recognition task.
    private func startLane(source: AudioSource, recognizer: SFSpeechRecognizer) {
        let lane = RecognitionLane(source: source, recognizer: recognizer)

        let request = makeRecognitionRequest()
        appLog("[SpeechAnalyzerService] [\(source.rawValue)] Recognition request native format: \(request.nativeAudioFormat.sampleRate)Hz, \(request.nativeAudioFormat.channelCount)ch")

        lane.sharedState.request = request
        lane.sessionStartTime = Date()

        lane.generation += 1
        let generation = lane.generation
        lane.task = recognizer.recognitionTask(with: request) { [weak self, weak lane] result, error in
            Task { @MainActor in
                guard let self = self, let lane = lane else { return }
                self.handleRecognitionResult(result: result, error: error, lane: lane, generation: generation)
            }
        }

        lane.sharedState.isRunning = true
        laneRegistry.set(lane, for: source)
        appLog("[SpeechAnalyzerService] ✅ [\(source.rawValue)] lane started")
    }

    /// Build the only kind of recognition request this app ever uses:
    /// on-device is required, so a request can never silently fall back to
    /// Apple's network recognition.
    func makeRecognitionRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        return request
    }

    /// Append audio buffer to the matching lane's recognition request - can be
    /// called from any thread. Thread safety is ensured by the lane registry
    /// lock plus SharedSpeechState's os_unfair_lock. Buffers from
    /// unknown/inactive lanes are dropped.
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let lane = laneRegistry.lane(for: source), lane.sharedState.isRunning, let request = lane.sharedState.request else { return }
        let count = lane.sharedState.incrementBufferCount()
        if count % 50 == 1 {
            appLog("[SpeechAnalyzerService] 🎤 [\(source.rawValue)] Audio buffer #\(count) appended (format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch, frames: \(buffer.frameLength))")
        }
        request.append(buffer)
    }

    /// Whether any lane is actively recognizing. Callable from any thread.
    nonisolated var anyLaneRunning: Bool {
        laneRegistry.anyRunning
    }

    func stop() {
        let lanes = laneRegistry.removeAllLanes()
        for lane in lanes {
            lane.sharedState.isRunning = false
            lane.sharedState.request?.endAudio()
            lane.task?.cancel()
            lane.task = nil
            lane.sharedState.request = nil
            lane.lastTranscript = ""
        }
        if !lanes.isEmpty {
            let summary = lanes
                .sorted { $0.source.rawValue < $1.source.rawValue }
                .map { lane in
                    "\(lane.source.rawValue) results=\(lane.stats.resultCount) error1110=\(lane.stats.error1110Count) restarts=\(lane.stats.restartCount) staleDropped=\(lane.stats.staleCallbackCount)"
                }
                .joined(separator: " | ")
            appLog("[SpeechAnalyzerService] stop() summary: \(summary)")
        }
        isRunning = false
    }

    /// Numbers-only snapshot of the per-lane counters (used by the self-test
    /// report; contains no transcript content).
    func statsSnapshot() -> [AudioSource: LaneStats] {
        var snapshot: [AudioSource: LaneStats] = [:]
        for lane in laneRegistry.allLanes {
            snapshot[lane.source] = lane.stats
        }
        return snapshot
    }

    // MARK: - Private Methods

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?, lane: RecognitionLane, generation: Int) {
        // Drop callbacks from superseded tasks. Restarting bumps the lane's
        // generation before the old task is cancelled, so the old task's
        // trailing callbacks (including its 1110) can never trigger another
        // restart or emit a transcript — that was the infinite-restart loop.
        guard RecognitionRestartPolicy.shouldProcessCallback(
            laneIsCurrent: laneRegistry.lane(for: lane.source) === lane,
            callbackGeneration: generation,
            currentGeneration: lane.generation
        ) else {
            lane.stats.staleCallbackCount += 1
            return
        }

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
            // don't surface an error banner; just restart the lane (with backoff)
            // so it keeps listening.
            if nsError.code == 1110 {
                lane.stats.error1110Count += 1
                let delay = lane.policy.registerNoSpeechRestart()
                scheduleLaneRestart(lane, generation: generation, delay: delay)
                return
            }
            lastError = description
            return
        }

        guard let result = result else {
            appLog("[SpeechAnalyzerService] ⚠️ [\(lane.source.rawValue)] handleRecognitionResult called with nil result and nil error")
            return
        }
        appLog("[SpeechAnalyzerService] 📝 [\(lane.source.rawValue)] Recognition result: isFinal=\(result.isFinal), length=\(result.bestTranscription.formattedString.count)")

        let transcript = result.bestTranscription.formattedString

        if !transcript.isEmpty {
            lane.policy.noteNonEmptyTranscript()
        }

        // Emit only non-empty, changed transcripts
        if !transcript.isEmpty && transcript != lane.lastTranscript {
            lane.lastTranscript = transcript
            lane.stats.resultCount += 1

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
        }

        // A final result ends this task — restart the lane so transcription
        // continues. This also covers empty/unchanged finals, which previously
        // stalled the lane until the next no-speech timeout.
        if result.isFinal {
            scheduleLaneRestart(lane, generation: generation, delay: Self.finalRestartDelay)
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

    /// Replace the lane's finished/timed-out recognition task with a fresh one
    /// after `delay`. Both restart paths (error 1110 and isFinal) funnel here.
    ///
    /// The lane's generation is bumped immediately, so any late callback from
    /// the old task is dropped as stale. The replacement request is created
    /// and swapped in NOW — before the delay — so audio appended during the
    /// backoff window is queued in the request and recognized once the new
    /// task starts, instead of being dropped on the floor.
    private func scheduleLaneRestart(_ lane: RecognitionLane, generation: Int, delay: TimeInterval) {
        guard laneRegistry.lane(for: lane.source) === lane,
              lane.sharedState.isRunning,
              lane.generation == generation else { return }

        lane.generation += 1
        let newGeneration = lane.generation
        lane.stats.restartCount += 1

        let newRequest = makeRecognitionRequest()

        // Capture old references before swapping
        let oldRequest = lane.sharedState.request
        let oldTask = lane.task

        // Atomically swap the request pointer — appendAudioBuffer() immediately
        // starts appending to the new request from this point forward.
        lane.sharedState.request = newRequest
        lane.currentSegmentId = UUID()
        lane.lastTranscript = ""

        // Tear down the old request/task. Its trailing callbacks carry the old
        // generation and are dropped as stale.
        oldRequest?.endAudio()
        oldTask?.cancel()

        appLog("[SpeechAnalyzerService] [\(lane.source.rawValue)] lane restarting in \(String(format: "%.2f", delay))s")

        Task { [weak self, weak lane] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, let lane = lane else { return }
            self.startDeferredTask(lane: lane, generation: newGeneration, request: newRequest)
        }
    }

    /// Start the replacement task created by scheduleLaneRestart, unless the
    /// lane was stopped or superseded while the backoff was elapsing.
    private func startDeferredTask(lane: RecognitionLane, generation: Int, request: SFSpeechAudioBufferRecognitionRequest) {
        guard laneRegistry.lane(for: lane.source) === lane,
              lane.sharedState.isRunning,
              lane.generation == generation else { return }
        guard lane.recognizer.isAvailable else {
            // The lane cannot recover on its own: stop it cleanly so buffers
            // don't pile up in the swapped-in request forever, and surface the
            // failure instead of leaving a silently dead lane.
            appLog("[SpeechAnalyzerService] ⚠️ [\(lane.source.rawValue)] Recognizer unavailable; lane stopped")
            lane.sharedState.isRunning = false
            lane.sharedState.request = nil
            lastError = "Speech recognizer became unavailable for the \(lane.source.rawValue) lane."
            return
        }
        lane.task = lane.recognizer.recognitionTask(with: request) { [weak self, weak lane] result, error in
            Task { @MainActor in
                guard let self = self, let lane = lane else { return }
                self.handleRecognitionResult(result: result, error: error, lane: lane, generation: generation)
            }
        }
    }
}

// MARK: - SpeechRecognitionEngine conformance

extension SpeechAnalyzerService: SpeechRecognitionEngine {
    var kind: SpeechEngineKind { .sfSpeechRecognizer }

    var lastErrorPublisher: AnyPublisher<String?, Never> {
        $lastError.eraseToAnyPublisher()
    }

    /// The legacy engine runs a single lane, so a lane restart is a stop +
    /// start of that lane with the new language. The stop runs first so any
    /// failure below leaves the lane stopped rather than half-configured.
    func restartLane(_ source: AudioSource, language: SourceLanguage) async throws {
        appLog("[SpeechAnalyzerService] [\(source.rawValue)] lane restart requested (language: \(language.rawValue))")
        stop()
        try await start(sources: [source], languages: [source: language])
    }

    /// The legacy engine never downloads models: a language with an on-device
    /// recognizer is usable now, everything else is unsupported.
    func languageAvailability() async -> [SourceLanguage: LanguageAvailability] {
        var result: [SourceLanguage: LanguageAvailability] = [:]
        for language in SourceLanguage.allCases {
            let installed = isOnDeviceRecognitionAvailable(locale: language.locale)
            result[language] = LanguageAvailability(isSupported: installed, isInstalled: installed)
        }
        return result
    }
}

// MARK: - Error Types

enum SpeechAnalyzerError: Error, LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case audioSessionFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition is not authorized"
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable"
        case .onDeviceRecognitionUnavailable:
            return "On-device speech recognition is not available for this language. Download its on-device speech model in System Settings, or choose another language. LCT never sends audio to the network."
        case .audioSessionFailed:
            return "Failed to configure audio session"
        }
    }
}
