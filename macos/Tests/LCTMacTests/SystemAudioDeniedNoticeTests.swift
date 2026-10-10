import XCTest
import Combine
@testable import LCTMac
import AVFoundation

/// View-model tests for the system-audio authorization denial flow: the
/// capture service reports (on the MainActor) that the running tap delivered
/// no IO callback — macOS's silent answer to a denied consent. The VM must
/// surface the actionable error, keep a running microphone lane alive, and
/// wind the session down when the system lane was the only one. Everything is
/// stubbed — no real tap, no TCC, no network.
@MainActor
final class SystemAudioDeniedNoticeTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeSpeechEngine: SpeechRecognitionEngine {
        let kind: SpeechEngineKind = .speechTranscriber
        var onTranscription: ((TranscriptionResult) -> Void)?
        private let lastErrorSubject = CurrentValueSubject<String?, Never>(nil)
        var lastErrorPublisher: AnyPublisher<String?, Never> {
            lastErrorSubject.eraseToAnyPublisher()
        }
        var onModelDownloadStatus: ((SourceLanguage?) -> Void)?
        private(set) var currentLanguage: SourceLanguage = .english
        private(set) var startedSources: [AudioSource]?
        private(set) var stopCallCount = 0

        func setLanguage(_ language: SourceLanguage) {
            currentLanguage = language
        }

        func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws {
            startedSources = sources
        }

        func stop() async {
            stopCallCount += 1
        }

        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {}

        func statsSnapshot() -> [AudioSource: LaneStats] { [:] }
    }

    private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onFirstCallback: (@Sendable () -> Void)?
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        func start() throws {
            startCallCount += 1
        }

        func stop() {
            stopCallCount += 1
        }
    }

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/version") {
                return .respond(200, Data(#"{"version":"0.0.0-test"}"#.utf8))
            }
            if path.hasSuffix("/api/tags") {
                return .respond(200, Data(#"{"models":[{"name":"test-model:1b"}]}"#.utf8))
            }
            if path.hasSuffix("/api/ps") {
                return .respond(200, Data(#"{"models":[{"name":"test-model:1b"}]}"#.utf8))
            }
            if path.hasSuffix("/api/chat") {
                return .respond(200, Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8))
            }
            return .respond(200, Data())
        }
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        PullMockURLProtocol.requestHandler = nil
        PullMockURLProtocol.log = nil
        AppSettings.resetSetupFlag()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    private static let deniedMessage = "LCT isn't allowed to record system audio. In System Settings → Privacy & Security → Screen & System Audio Recording, turn on LCT under \"System Audio Recording Only\", then start again."

    /// Builds a capturing view model whose system lane runs on a fake tap.
    /// The watchdog window is set far in the future so these tests drive the
    /// denial callback directly instead of waiting it out.
    private func makeCapturingViewModel() async -> (TranscriptionViewModel, FakeSpeechEngine, AudioCaptureService) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PullMockURLProtocol.self]
        var settings = AppSettings()
        settings.captureSystemAudio = true
        settings.captureMicrophone = false
        settings.ollamaModel = "test-model:1b"
        settings.ollamaTimeout = 1
        let service = OllamaService(settings: settings, session: URLSession(configuration: config))
        let guardian = OllamaGuardian(
            ollamaPath: "/fake/ollama",
            ollamaURL: "http://localhost:11434",
            session: URLSession(configuration: config),
            launcher: FakeOllamaLauncher(),
            installationDetector: { .cli("/fake/ollama") },
            serveLogFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("LCTMacTests-ollama-\(UUID().uuidString).log"),
            startupPollInterval: 0.01,
            startupMaxAttempts: 5,
            stopGracePeriod: 0.1
        )
        let tap = FakeSystemAudioTap()
        let captureService = AudioCaptureService(
            makeSystemAudioTap: { tap },
            systemAudioAuthorizationTimeout: 60
        )
        let engine = FakeSpeechEngine()
        let viewModel = TranscriptionViewModel(
            settings: settings,
            ollamaService: service,
            ollamaGuardian: guardian,
            audioCaptureService: captureService,
            speechEngine: engine
        )
        await viewModel.start()
        return (viewModel, engine, captureService)
    }

    // MARK: - Tests

    /// Denial with no other lane running: capture winds down to idle, speech
    /// recognition stops, and the error carries the settings action.
    func testSystemAudioDenied_SystemOnlyLane_ReturnsToIdleWithSettingsAction() async {
        let (viewModel, engine, captureService) = await makeCapturingViewModel()
        XCTAssertEqual(viewModel.captureState, .capturing, "test setup: capture must be running")

        captureService.onSystemAudioAuthorizationDenied?(false)

        XCTAssertEqual(viewModel.captureState, .idle)
        XCTAssertNil(viewModel.captureStartedAt)
        let engineStopped = await waitForCondition { engine.stopCallCount == 1 }
        XCTAssertTrue(engineStopped, "ending the session must stop speech recognition")
        let notice = try? XCTUnwrap(viewModel.notice)
        XCTAssertEqual(notice?.severity, .error)
        XCTAssertEqual(notice?.message, Self.deniedMessage)
        XCTAssertEqual(notice?.actions, [.openSystemAudioSettings])
    }

    /// Denial while the microphone lane is still running: capture continues;
    /// only the notice tells the user the system lane is gone.
    func testSystemAudioDenied_MicrophoneContinues_KeepsCapturingWithNotice() async {
        let (viewModel, engine, captureService) = await makeCapturingViewModel()
        XCTAssertEqual(viewModel.captureState, .capturing, "test setup: capture must be running")

        captureService.onSystemAudioAuthorizationDenied?(true)

        XCTAssertEqual(viewModel.captureState, .capturing, "the microphone lane keeps the session alive")
        XCTAssertEqual(engine.stopCallCount, 0, "speech recognition must not stop while capture continues")
        let notice = try? XCTUnwrap(viewModel.notice)
        XCTAssertEqual(notice?.severity, .error)
        XCTAssertEqual(notice?.message, Self.deniedMessage)
        XCTAssertEqual(notice?.actions, [.openSystemAudioSettings])

        await viewModel.stop()
    }

    /// A live error on screen outranks the denial error — but the session
    /// teardown still happens.
    func testSystemAudioDenied_ExistingError_IsNotOverridden() async {
        let (viewModel, _, captureService) = await makeCapturingViewModel()
        XCTAssertEqual(viewModel.captureState, .capturing, "test setup: capture must be running")
        let sentinel = AppNotice.error("sentinel", actions: [.retryCapture])
        viewModel.notice = sentinel

        captureService.onSystemAudioAuthorizationDenied?(false)

        XCTAssertEqual(viewModel.notice, sentinel, "an existing error must not be replaced")
        XCTAssertEqual(viewModel.captureState, .idle, "the session still winds down")
    }
}
