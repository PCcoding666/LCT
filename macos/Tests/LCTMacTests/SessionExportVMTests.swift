import XCTest
import Combine
import AVFoundation
@testable import LCTMac

/// View-model tests for the session transcript: a started session records
/// every finalized caption (not just the trimmed on-screen cards), translations
/// write back, rollbacks revoke, stop() keeps the record, clear() empties it.
/// Everything is stubbed — no real tap, no TCC, no network.
@MainActor
final class SessionExportVMTests: XCTestCase {

    // MARK: - Fakes

    /// Offline Ollama stand-in. Unlike PullMockURLProtocol it answers
    /// /api/chat like the real server: a content chunk first, the empty
    /// done-chunk a beat later. The gap lets the translation queue's
    /// main-actor token append run before its completion path reads the
    /// accumulated text — an instant single-chunk response would trip that
    /// pre-existing race and deliver an empty final translation.
    private final class ChunkedOllamaMockProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

            if path.hasSuffix("/api/chat") {
                client?.urlProtocol(self, didLoad: Data(#"{"message":{"role":"assistant","content":"ok"},"done":false}"#.utf8 + Data("\n".utf8)))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [client] in
                    client?.urlProtocol(self, didLoad: Data(#"{"message":{"role":"assistant","content":""},"done":true}"#.utf8 + Data("\n".utf8)))
                    client?.urlProtocolDidFinishLoading(self)
                }
                return
            }

            let body: Data
            if path.hasSuffix("/api/version") {
                body = Data(#"{"version":"0.0.0-test"}"#.utf8)
            } else if path.hasSuffix("/api/tags") || path.hasSuffix("/api/ps") {
                body = Data(#"{"models":[{"name":"test-model:1b"}]}"#.utf8)
            } else {
                body = Data()
            }
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class FakeSpeechEngine: SpeechRecognitionEngine {
        let kind: SpeechEngineKind = .speechTranscriber
        var onTranscription: ((TranscriptionResult) -> Void)?
        private let lastErrorSubject = CurrentValueSubject<String?, Never>(nil)
        var lastErrorPublisher: AnyPublisher<String?, Never> {
            lastErrorSubject.eraseToAnyPublisher()
        }
        var onModelDownloadStatus: ((SourceLanguage?) -> Void)?
        private(set) var currentLanguage: SourceLanguage = .english

        func setLanguage(_ language: SourceLanguage) {
            currentLanguage = language
        }

        func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws {}

        func stop() async {}

        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {}

        func statsSnapshot() -> [AudioSource: LaneStats] { [:] }
    }

    private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onFirstCallback: (@Sendable () -> Void)?

        func start() throws {
            // An authorized tap calls back immediately and continuously;
            // firing here keeps the authorization watchdog quiet in tests.
            onFirstCallback?()
        }

        func stop() {}
    }

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ChunkedOllamaMockProtocol.self)
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ChunkedOllamaMockProtocol.self)
        AppSettings.resetSetupFlag()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    private func makeViewModel() -> (TranscriptionViewModel, FakeSpeechEngine) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedOllamaMockProtocol.self]
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
            makeSystemAudioTap: { FakeSystemAudioTap() }
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

    /// Poll a main-actor condition until it holds or the timeout elapses.
    private func waitFor(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func fireFinal(_ engine: FakeSpeechEngine, text: String, taskId: UUID = UUID(), lane: AudioSource = .system) {
        engine.onTranscription?(TranscriptionResult(id: taskId, text: text, isVolatile: false, source: lane))
    }

    // MARK: - Tests

    func testSessionTranscript_StartSuccess_BeginsNewSession() async {
        let (viewModel, _) = makeViewModel()
        XCTAssertNil(viewModel.sessionTranscript.startedAt)

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .capturing)
        XCTAssertNotNil(viewModel.sessionTranscript.startedAt)
        XCTAssertTrue(viewModel.sessionTranscript.entries.isEmpty)

        await viewModel.stop()
    }

    func testSessionTranscript_Restart_ResetsEntries() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        fireFinal(engine, text: "First session line.")
        XCTAssertEqual(viewModel.sessionTranscript.entries.count, 1)
        await viewModel.stop()

        await viewModel.start()

        XCTAssertTrue(viewModel.sessionTranscript.entries.isEmpty, "a new start must begin a fresh record")
        XCTAssertNotNil(viewModel.sessionTranscript.startedAt)

        await viewModel.stop()
    }

    func testSessionTranscript_FinalizedSegment_AppendsEntry() async throws {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        let startedAt = try XCTUnwrap(viewModel.sessionTranscript.startedAt)

        fireFinal(engine, text: "Hello world.", lane: .system)
        fireFinal(engine, text: "Mic line.", lane: .microphone)

        let entries = viewModel.sessionTranscript.entries
        XCTAssertEqual(entries.map(\.sourceText), ["Hello world.", "Mic line."])
        XCTAssertEqual(entries.map(\.source), [.system, .microphone])
        XCTAssertEqual(entries.map(\.translatedText), ["", ""])
        for entry in entries {
            XCTAssertGreaterThanOrEqual(entry.finalizedAt.timeIntervalSince(startedAt), 0)
        }

        await viewModel.stop()
    }

    func testSessionTranscript_PunctuationOnlySegment_IsNotRecorded() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()

        fireFinal(engine, text: ".")

        XCTAssertTrue(viewModel.sessionTranscript.entries.isEmpty)

        await viewModel.stop()
    }

    func testSessionTranscript_TranslationCompletion_UpdatesEntry() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        fireFinal(engine, text: "Hello.")

        let updated = await waitFor {
            viewModel.sessionTranscript.entries.first?.translatedText == "ok"
        }

        XCTAssertTrue(updated, "the final translation must be written into the session record")

        await viewModel.stop()
    }

    func testSessionTranscript_Rollback_RemovesRevokedEntry() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        let taskId = UUID()
        fireFinal(engine, text: "Hello world.", taskId: taskId)
        XCTAssertEqual(viewModel.sessionTranscript.entries.count, 1)

        // Same ASR task revises its text: the committed caption is revoked.
        engine.onTranscription?(TranscriptionResult(
            id: taskId,
            text: "Hallo something entirely different",
            isVolatile: true,
            source: .system
        ))

        XCTAssertTrue(viewModel.sessionTranscript.entries.isEmpty, "rolled-back captions must leave the record")
        XCTAssertTrue(viewModel.segments.isEmpty)

        await viewModel.stop()
    }

    func testSessionTranscript_Stop_KeepsEntries() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        fireFinal(engine, text: "Keepsake.")

        await viewModel.stop()

        XCTAssertEqual(viewModel.sessionTranscript.entries.count, 1, "a stopped session stays exportable")
        XCTAssertNotNil(viewModel.sessionTranscript.startedAt)
    }

    func testSessionTranscript_Clear_EmptiesRecord() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()
        fireFinal(engine, text: "Soon gone.")

        viewModel.clear()

        XCTAssertTrue(viewModel.sessionTranscript.entries.isEmpty)
        XCTAssertNil(viewModel.sessionTranscript.startedAt)

        await viewModel.stop()
    }

    func testSessionTranscript_MoreThanDisplayCards_KeepsAllEntries() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()

        // Each sentence arrives as its own ASR task (the recognizer restarts
        // between sentences), so no rollback is involved.
        for index in 1...7 {
            fireFinal(engine, text: "Segment \(index).")
        }

        XCTAssertEqual(viewModel.segments.count, 5, "display cards are trimmed to maxDisplayCards")
        XCTAssertEqual(
            viewModel.sessionTranscript.entries.count, 7,
            "the session record must keep captions that scrolled off the screen"
        )

        await viewModel.stop()
    }

    func testSessionTranscript_FinalizedWhilePaused_TranslatesOnResume() async {
        let (viewModel, engine) = makeViewModel()
        await viewModel.start()

        viewModel.togglePause()
        fireFinal(engine, text: "Paused line.")
        XCTAssertEqual(viewModel.sessionTranscript.entries.count, 1)
        XCTAssertEqual(viewModel.sessionTranscript.entries.first?.translatedText, "")

        viewModel.togglePause()
        let updated = await waitFor {
            viewModel.sessionTranscript.entries.first?.translatedText == "ok"
        }

        XCTAssertTrue(updated, "a caption finalized while paused must update once resumed translation completes")

        await viewModel.stop()
    }
}
