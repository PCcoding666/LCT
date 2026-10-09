import Foundation
import XCTest
@testable import LCTMac

/// Notice-action wiring for translation-model downloads: the Download button
/// on the "model not installed" notice, the MLX-on-Intel hard stop in
/// start(), and the download progress/restart flow. All offline.
@MainActor
final class DownloadModelNoticeTests: XCTestCase {

    private let log = RecordedRequestLog()

    override func setUp() {
        super.setUp()
        PullMockURLProtocol.log = log
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/tags") {
                return .respond(200, Data(#"{"models": []}"#.utf8))
            }
            return .respond(200, Data())
        }
    }

    override func tearDown() {
        PullMockURLProtocol.requestHandler = nil
        PullMockURLProtocol.log = nil
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PullMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Settings that pass the endpoint check but enable no capture lane, so a
    /// post-download start() fails fast instead of touching TCC or Ollama.
    private func noSourceSettings(model: String) -> AppSettings {
        var settings = AppSettings()
        settings.captureSystemAudio = false
        settings.captureMicrophone = false
        settings.ollamaModel = model
        settings.ollamaTimeout = 1
        return settings
    }

    private func makeViewModel(
        settings: AppSettings,
        hardware: HardwareProfile = HardwareProfile(isAppleSilicon: true, physicalMemoryBytes: 17_179_869_184, chipName: "Apple M2 Pro"),
        managerFactory: ((OllamaEndpoint) -> OllamaModelManager)? = nil
    ) -> TranscriptionViewModel {
        let service = OllamaService(settings: settings, session: stubSession())
        // An endpoint-less guardian can never reach the network.
        let guardian = OllamaGuardian(ollamaPath: "/bin/echo", ollamaURL: "not a url")
        return TranscriptionViewModel(
            settings: settings,
            ollamaService: service,
            ollamaGuardian: guardian,
            hardwareProfile: hardware,
            makeModelManager: managerFactory ?? { OllamaModelManager(endpoint: $0, session: self.stubSession()) }
        )
    }

    // MARK: - Action label and identity

    func testNoticeAction_DownloadModel_LabelIsDownload() {
        XCTAssertEqual(NoticeAction.downloadModel.label, "Download")
        XCTAssertEqual(NoticeAction.downloadModel.id, "downloadModel")
    }

    func testNoticeAction_DownloadModel_IDDoesNotCollide() {
        let ids: [NoticeAction] = [
            .openScreenRecordingSettings, .openMicrophoneSettings,
            .openSpeechRecognitionSettings, .startOllama,
            .openAppSettings, .retryCapture, .downloadModel,
        ]
        XCTAssertEqual(Set(ids.map(\.id)).count, ids.count)
    }

    // MARK: - MLX on Intel hard stop

    func testStart_MLXModelOnIntel_FailsBeforeAnyWork() async throws {
        let intel = HardwareProfile(isAppleSilicon: false, physicalMemoryBytes: 17_179_869_184, chipName: "Intel Core i7")
        let viewModel = makeViewModel(settings: noSourceSettings(model: "qwen3.5:4b-mlx"), hardware: intel)

        // Let the launch-time health probe settle, then clear the log: the
        // compatibility failure itself must not produce any request.
        try? await Task.sleep(nanoseconds: 300_000_000)
        log.reset()

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .idle)
        let notice = try XCTUnwrap(viewModel.notice)
        XCTAssertEqual(notice.severity, .error)
        XCTAssertTrue(notice.message.contains("Apple Silicon"), notice.message)
        XCTAssertEqual(notice.actions, [.openAppSettings])
        XCTAssertTrue(log.snapshot.isEmpty, "an incompatible model must stop before any network or service call")
    }

    // MARK: - Download flow

    func testPerform_DownloadModel_Success_PullsAndRestartsCapture() async throws {
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/pull") {
                let ndjson = """
                {"status":"downloading","digest":"sha256:aaa","total":100,"completed":100}
                {"status":"success"}

                """
                return .respond(200, Data(ndjson.utf8))
            }
            if path.hasSuffix("/api/tags") {
                return .respond(200, Data(#"{"models": []}"#.utf8))
            }
            return .respond(200, Data())
        }
        let viewModel = makeViewModel(settings: noSourceSettings(model: "download-test:1b"))
        viewModel.notice = .error("Model 'download-test:1b' is not installed.", actions: [.downloadModel, .openAppSettings])

        viewModel.perform(.downloadModel)

        let pulled = await waitForCondition {
            self.log.snapshot.contains { $0.path.hasSuffix("/api/pull") }
        }
        XCTAssertTrue(pulled, "the Download action must pull the configured model")

        // The successful download re-invokes start(), which — with no audio
        // source enabled — lands on the no-source error. Seeing it proves the
        // automatic restart happened.
        let restarted = await waitForCondition {
            viewModel.notice?.message.contains("audio source") == true
        }
        XCTAssertTrue(restarted, "a completed download must restart capture")

        let pull = try XCTUnwrap(log.snapshot.first { $0.path.hasSuffix("/api/pull") })
        let body = try XCTUnwrap(pull.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "download-test:1b")
    }

    func testPerform_DownloadModel_Failure_ShowsErrorWithDownloadRetry() async {
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/pull") {
                return .respond(200, Data((#"{"error":"registry: model not found"}"# + "\n").utf8))
            }
            return .respond(200, Data())
        }
        let viewModel = makeViewModel(settings: noSourceSettings(model: "download-test:1b"))

        viewModel.perform(.downloadModel)

        let failed = await waitForCondition {
            viewModel.notice?.severity == .error
                && viewModel.notice?.message.contains("failed") == true
        }
        XCTAssertTrue(failed, "a failed download must surface an error notice")
        XCTAssertEqual(viewModel.notice?.actions, [.downloadModel, .openAppSettings],
                       "the error notice must offer Download again as the retry")
        XCTAssertFalse(viewModel.notice?.autoDismiss ?? true)
    }

    func testPerform_DownloadModel_WhileDownloading_IgnoresSecondRequest() async throws {
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/pull") {
                return .hang
            }
            return .respond(200, Data())
        }
        var createdManager: OllamaModelManager?
        let viewModel = makeViewModel(
            settings: noSourceSettings(model: "download-test:1b"),
            managerFactory: { endpoint in
                let manager = OllamaModelManager(endpoint: endpoint, session: self.stubSession())
                createdManager = manager
                return manager
            }
        )

        viewModel.perform(.downloadModel)
        let started = await waitForCondition {
            self.log.snapshot.contains { $0.path.hasSuffix("/api/pull") }
        }
        XCTAssertTrue(started)

        viewModel.perform(.downloadModel)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let pullCount = log.snapshot.filter { $0.path.hasSuffix("/api/pull") }.count
        XCTAssertEqual(pullCount, 1, "a second Download tap must not start a parallel pull")

        // Cleanup: cancel the hung pull and let the task unwind.
        createdManager?.cancelPull()
        _ = await waitForCondition { createdManager?.isPulling == false }
    }
}
