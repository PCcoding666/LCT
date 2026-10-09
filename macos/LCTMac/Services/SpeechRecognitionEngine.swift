import Foundation
import Combine
@preconcurrency import AVFoundation

/// Which concrete recognizer backs a `SpeechRecognitionEngine`.
enum SpeechEngineKind: String, Equatable {
    /// SFSpeechRecognizer lanes (macOS 15+). On-device mode allows only one
    /// active recognition task per process, so two lanes keep cancelling each
    /// other (error 1110) — dual-lane capture is not really concurrent.
    case sfSpeechRecognizer = "sf"
    /// SpeechAnalyzer + SpeechTranscriber (macOS 26+). One analyzer per lane;
    /// lanes recognize truly concurrently and may use different languages.
    case speechTranscriber = "analyzer"
}

/// Contract every speech recognition engine fulfills. The view model talks to
/// the selected engine exclusively through this protocol. Sendable so the
/// capture service's @Sendable audio callbacks can hold the engine (the
/// MainActor engines are implicitly Sendable; their cross-thread entry point
/// is the lock-protected appendAudioBuffer).
@MainActor
protocol SpeechRecognitionEngine: AnyObject, Sendable {
    /// Which implementation backs this engine.
    var kind: SpeechEngineKind { get }

    /// Lane-tagged recognition results, delivered on the MainActor.
    var onTranscription: ((TranscriptionResult) -> Void)? { get set }

    /// User-presentable runtime error (nil clears it). Mirrors the old
    /// service's @Published lastError so the VM can keep its existing binding.
    var lastErrorPublisher: AnyPublisher<String?, Never> { get }

    /// Download progress of an on-device speech model: non-nil while a
    /// download for that language is in flight, nil when it ends. The legacy
    /// engine never downloads (it fails fast instead), so it never fires this.
    var onModelDownloadStatus: ((SourceLanguage?) -> Void)? { get set }

    var currentLanguage: SourceLanguage { get }
    func setLanguage(_ language: SourceLanguage)

    /// Start recognition, one independent lane per source. `languages`
    /// optionally overrides the recognition language per source; sources
    /// without an entry use `currentLanguage`.
    func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws

    /// Stop all lanes. Async because the SpeechAnalyzer engine's teardown
    /// (flushing final results) completes asynchronously; the legacy engine's
    /// synchronous teardown still satisfies this requirement.
    func stop() async

    /// Append one audio buffer to a lane. Called from realtime audio threads
    /// (two different threads in dual capture) — implementations must be
    /// thread-safe and must not block.
    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource)

    /// Numbers-only snapshot of the per-lane counters (used by the self-test
    /// report; contains no transcript content).
    func statsSnapshot() -> [AudioSource: LaneStats]

    /// Recent lane-scoped error descriptions for diagnostics (error messages
    /// only, never transcript content). Engines that don't track per-lane
    /// errors report an empty map.
    var laneErrorDescriptions: [AudioSource: [String]] { get }
}

extension SpeechRecognitionEngine {
    /// Default for engines that never download models.
    var onModelDownloadStatus: ((SourceLanguage?) -> Void)? {
        get { nil }
        set {}
    }

    /// Default for engines without per-lane error tracking.
    var laneErrorDescriptions: [AudioSource: [String]] { [:] }
}

/// Pure engine-selection and lane-degradation logic, kept free of any
/// Speech-framework dependency so it can be unit-tested directly.
enum SpeechEngineSelection {
    /// Pick the engine kind: the SpeechAnalyzer engine whenever it is compiled
    /// in and the OS supports it, otherwise the legacy SFSpeechRecognizer one.
    static func engineKind(transcriberEngineAvailable: Bool) -> SpeechEngineKind {
        transcriberEngineAvailable ? .speechTranscriber : .sfSpeechRecognizer
    }

    /// Restrict requested capture lanes to what the engine can actually run.
    /// The legacy engine runs a single on-device task at a time, so a dual
    /// request degrades to the system-audio lane only (system audio is the
    /// primary caption source; the mic lane is the one dropped).
    static func effectiveSources(
        _ requested: [AudioSource],
        for kind: SpeechEngineKind
    ) -> (sources: [AudioSource], droppedMicrophone: Bool) {
        guard kind == .sfSpeechRecognizer,
              requested.contains(.system), requested.contains(.microphone) else {
            return (requested, false)
        }
        return (requested.filter { $0 == .system }, true)
    }
}

/// Whether the SpeechAnalyzer-based engine is usable in this build on this OS.
enum SpeechEngineAvailability {
    static var isTranscriberEngineAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return SpeechTranscriberEngine.isAvailableOnThisDevice
        }
        return false
        #else
        return false
        #endif
    }
}

/// Builds the engine for a kind, falling back to the legacy engine when the
/// SpeechAnalyzer engine was requested but is not actually available.
@MainActor
enum SpeechEngineFactory {
    static func makeEngine(kind: SpeechEngineKind, language: SourceLanguage) -> any SpeechRecognitionEngine {
        switch kind {
        case .speechTranscriber:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                return SpeechTranscriberEngine(language: language)
            }
            #endif
            appLog("[SpeechEngineFactory] SpeechAnalyzer engine unavailable; falling back to SFSpeechRecognizer")
            return SpeechAnalyzerService(language: language)
        case .sfSpeechRecognizer:
            return SpeechAnalyzerService(language: language)
        }
    }
}
