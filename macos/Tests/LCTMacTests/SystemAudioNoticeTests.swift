import XCTest
import Combine
import AVFoundation
@testable import LCTMac

/// View-model tests for the system-audio permission flow: starting a capture
/// with only the system lane must never ask for the screen-recording
/// permission, and the ScreenCaptureKit fallback must surface the right
/// notice. Everything is stubbed — no real tap, no TCC, no network.
@MainActor
final class SystemAudioNoticeTests: XCTestCase {

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
        var errorToThrow: Error?
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        func start() throws {
            startCallCount += 1
            if let errorToThrow { throw errorToThrow }
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

    private func makeViewModel(
        tap: FakeSystemAudioTap,
        screenPermissionChecker: (() async -> Bool)? = nil,
        screenCaptureStreamStarter: (() async throws -> Void)? = nil
    ) -> (TranscriptionViewModel, FakeSpeechEngine) {
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
        let captureService = AudioCaptureService(
            makeSystemAudioTap: { tap },
            screenPermissionChecker: screenPermissionChecker,
            screenCaptureStreamStarter: screenCaptureStreamStarter
        )
        let engine = FakeSpeechEngine()
        let viewModel = TranscriptionViewModel(
            settings: settings,
            ollamaService: service,
            ollamaGuardian: guardian,
            audioCaptureService: captureService,
            speechEngine: engine
        )
        return (viewModel, engine)
    }

    // MARK: - Tests

    /// The whole point of the Core Audio tap: system-audio-only capture runs
    /// without the screen-recording permission ever being consulted.
    func testStart_SystemAudioOnlyWithoutScreenPermission_KeepsSystemLane() async {
        let tap = FakeSystemAudioTap()
        let (viewModel, engine) = makeViewModel(
            tap: tap,
            screenPermissionChecker: {
                XCTFail("screen permission must not be checked while the tap works")
                return false
            },
            screenCaptureStreamStarter: {
                XCTFail("ScreenCaptureKit must not start while the tap works")
            }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .capturing)
        XCTAssertEqual(engine.startedSources, [.system])
        XCTAssertEqual(tap.startCallCount, 1)
        XCTAssertNil(viewModel.notice)

        await viewModel.stop()
        XCTAssertEqual(tap.stopCallCount, 1)
    }

    /// The tap fails but the ScreenCaptureKit fallback has permission: capture
    /// runs, and a sticky warning tells the user which mode they are in.
    func testStart_CoreAudioTapFails_ShowsStickyFallbackWarning() async {
        let tap = FakeSystemAudioTap()
        tap.errorToThrow = SystemAudioTapError(step: "AudioHardwareCreateProcessTap", status: -50)
        let (viewModel, _) = makeViewModel(
            tap: tap,
            screenPermissionChecker: { true },
            screenCaptureStreamStarter: {}
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .capturing)
        let notice = try? XCTUnwrap(viewModel.notice)
        XCTAssertEqual(notice?.severity, .warning)
        XCTAssertEqual(
            notice?.message,
            "System audio capture fell back to screen recording mode (Core Audio tap failed: AudioHardwareCreateProcessTap (OSStatus -50))."
        )
        XCTAssertEqual(notice?.autoDismiss, false, "the fallback warning stays on screen until capture stops")

        await viewModel.stop()
    }

    /// The tap fails and the fallback has no screen permission either: start
    /// aborts with the screen-recording error and its settings action.
    func testStart_CoreAudioTapFailsWithoutScreenPermission_ShowsScreenRecordingError() async {
        let tap = FakeSystemAudioTap()
        tap.errorToThrow = SystemAudioTapError(step: "AudioHardwareCreateProcessTap", status: -50)
        let (viewModel, _) = makeViewModel(
            tap: tap,
            screenPermissionChecker: { false },
            screenCaptureStreamStarter: {
                XCTFail("ScreenCaptureKit must not start without the screen permission")
            }
        )

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .idle)
        let notice = try? XCTUnwrap(viewModel.notice)
        XCTAssertEqual(notice?.severity, .error)
        XCTAssertEqual(notice?.message, "Screen recording permission is required to capture system audio.")
        XCTAssertEqual(notice?.actions, [.openScreenRecordingSettings])
    }
}
