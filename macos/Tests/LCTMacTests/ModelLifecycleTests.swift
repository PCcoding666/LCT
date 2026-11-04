import Foundation
import XCTest
@testable import LCTMac

/// Thread-safe record of requests captured by the mock protocol.
private final class RequestRecorder: @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let body: Data?
    }

    private let lock = NSLock()
    private var records: [Recorded] = []

    func append(method: String, path: String, body: Data?) {
        lock.lock()
        records.append(Recorded(method: method, path: path, body: body))
        lock.unlock()
    }

    var snapshot: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func reset() {
        lock.lock()
        records.removeAll()
        lock.unlock()
    }
}

private final class LifecycleMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recorder: RequestRecorder?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder?.append(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            body: Self.readBody(of: request)
        )

        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// The URL loading system may hand the body to the protocol either inline
    /// or as a stream; accept both.
    static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

// MARK: - keep_alive mapping

final class ModelKeepAliveTests: XCTestCase {

    func testModelKeepAlive_OllamaValue_MapsMinutesToDurationString() {
        XCTAssertEqual(ModelKeepAlive.minutes5.ollamaValue, "5m")
        XCTAssertEqual(ModelKeepAlive.minutes15.ollamaValue, "15m")
        XCTAssertEqual(ModelKeepAlive.minutes30.ollamaValue, "30m")
        XCTAssertEqual(ModelKeepAlive.hour1.ollamaValue, "60m")
    }

    func testModelKeepAlive_UntilQuit_MapsToNegativeDuration() {
        XCTAssertEqual(ModelKeepAlive.untilQuit.ollamaValue, "-1m")
    }

    func testModelKeepAlive_DisplayNames() {
        XCTAssertEqual(ModelKeepAlive.minutes5.displayName, "5 minutes")
        XCTAssertEqual(ModelKeepAlive.minutes15.displayName, "15 minutes")
        XCTAssertEqual(ModelKeepAlive.minutes30.displayName, "30 minutes")
        XCTAssertEqual(ModelKeepAlive.hour1.displayName, "1 hour")
        XCTAssertEqual(ModelKeepAlive.untilQuit.displayName, "Until LCT quits")
    }

    func testModelKeepAlive_AllCases_CoverEveryPickerOption() {
        XCTAssertEqual(ModelKeepAlive.allCases.count, 5)
    }
}

// MARK: - Request-level tests (stubbed URLSession, no real Ollama)

@MainActor
final class OllamaModelLifecycleRequestTests: XCTestCase {

    private let recorder = RequestRecorder()

    override func setUp() {
        super.setUp()
        LifecycleMockURLProtocol.recorder = recorder
        LifecycleMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/ps") {
                return (response, Data(#"{"models": []}"#.utf8))
            }
            if path.hasSuffix("/api/tags") {
                return (response, Data(#"{"models": []}"#.utf8))
            }
            if path.hasSuffix("/api/chat") {
                return (response, Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8))
            }
            return (response, Data())
        }
    }

    override func tearDown() {
        LifecycleMockURLProtocol.requestHandler = nil
        LifecycleMockURLProtocol.recorder = nil
        super.tearDown()
    }

    func testCheckHealth_ServerUnreachable_ReturnsFalseWithoutLastError() async {
        LifecycleMockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let service = makeService()

        let healthy = await service.checkHealth()

        XCTAssertFalse(healthy)
        XCTAssertFalse(service.isConnected)
        // A probe must not publish an error: the view model turns lastError
        // into an error notice, which appeared at launch while LCT was
        // already starting Ollama.
        XCTAssertNil(service.lastError)
    }

    private func makeService(keepAlive: ModelKeepAlive = .minutes30, model: String = "test-model") -> OllamaService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleMockURLProtocol.self]

        var settings = AppSettings()
        settings.ollamaModel = model
        settings.modelKeepAlive = keepAlive
        settings.ollamaTimeout = 1

        return OllamaService(settings: settings, session: URLSession(configuration: config))
    }

    private func bodyJSON(_ record: RequestRecorder.Recorded) throws -> [String: Any] {
        let body = try XCTUnwrap(record.body, "request must carry a JSON body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Unload request shape

    func testUnloadModel_RequestShape_PostsGenerateWithOnlyModelAndKeepAliveZero() async throws {
        let service = makeService()
        try await service.unloadModel("old-model:7b")

        let unload = recorder.snapshot.first { $0.path.hasSuffix("/api/generate") }
        let record = try XCTUnwrap(unload, "unload must hit /api/generate")
        XCTAssertEqual(record.method, "POST")

        let json = try bodyJSON(record)
        XCTAssertEqual(json["model"] as? String, "old-model:7b")
        XCTAssertEqual(json["keep_alive"] as? Int, 0)
        XCTAssertEqual(Set(json.keys), ["model", "keep_alive"],
                       "the unload body must not carry messages or a prompt (no inference)")
    }

    func testUnloadModel_UsesConfiguredModelNameNotServiceModel() async throws {
        let service = makeService(model: "current-model")
        try await service.unloadModel("some-other-model")

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/generate") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["model"] as? String, "some-other-model",
                       "unload must target the name argument, not the configured model")
    }

    // MARK: Load request keep_alive

    func testLoadModel_KeepAlive_ComesFromSettings() async throws {
        let service = makeService(keepAlive: .hour1)
        try await service.loadModel("test-model")

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/generate") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["keep_alive"] as? String, "60m")
        XCTAssertNil(json["prompt"], "load must not run inference")
    }

    // MARK: /api/ps parsing (pure function)

    func testParseLoadedModels_NameField_ReturnsNames() throws {
        let data = Data(#"{"models": [{"name": "qwen3.5:4b-mlx"}, {"name": "llama3.2:3b"}]}"#.utf8)
        XCTAssertEqual(try OllamaService.parseLoadedModels(from: data), ["qwen3.5:4b-mlx", "llama3.2:3b"])
    }

    func testParseLoadedModels_ModelField_FallsBackToModelKey() throws {
        let data = Data(#"{"models": [{"model": "qwen3.5:4b-mlx"}]}"#.utf8)
        XCTAssertEqual(try OllamaService.parseLoadedModels(from: data), ["qwen3.5:4b-mlx"])
    }

    func testParseLoadedModels_EmptyList_ReturnsEmpty() throws {
        let data = Data(#"{"models": []}"#.utf8)
        XCTAssertEqual(try OllamaService.parseLoadedModels(from: data), [])
    }

    func testParseLoadedModels_MixedFields_PrefersNameAndSkipsEmptyEntries() throws {
        let data = Data(#"{"models": [{"name": "a:1", "model": "ignored:2"}, {"model": "b:3"}, {}]}"#.utf8)
        XCTAssertEqual(try OllamaService.parseLoadedModels(from: data), ["a:1", "b:3"])
    }

    func testParseLoadedModels_MalformedJSON_Throws() {
        XCTAssertThrowsError(try OllamaService.parseLoadedModels(from: Data("not json".utf8)))
    }

    // MARK: loadedModels() end to end

    func testLoadedModels_ReturnsNamesFromPS() async throws {
        LifecycleMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"models": [{"name": "qwen3.5:4b-mlx"}]}"#.utf8))
        }
        let service = makeService()

        let names = try await service.loadedModels()

        XCTAssertEqual(names, ["qwen3.5:4b-mlx"])
        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/ps") })
        XCTAssertEqual(record.method, "GET")
    }

    // MARK: keep_alive on model-loading requests

    func testPrewarmModel_KeepAlive_ComesFromSettings() async throws {
        let service = makeService(keepAlive: .untilQuit)
        _ = try await service.prewarmModel()

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/chat") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["keep_alive"] as? String, "-1m")
    }

    func testTranslate_KeepAlive_ComesFromSettings() async throws {
        let service = makeService(keepAlive: .minutes15)
        _ = try await service.translate(text: "hello")

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/chat") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["keep_alive"] as? String, "15m")
    }

    func testTranslateStreaming_KeepAlive_ComesFromSettings() async throws {
        LifecycleMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let ndjson = """
            {"message":{"role":"assistant","content":"hola"},"done":false}
            {"message":{"role":"assistant","content":""},"done":true}

            """
            return (response, Data(ndjson.utf8))
        }
        let service = makeService(keepAlive: .minutes5)
        _ = try await service.translateStreaming(text: "hello") { _ in }

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/chat") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["keep_alive"] as? String, "5m")
    }

    func testPrewarmModel_DefaultKeepAlive_IsThirtyMinutes() async throws {
        let service = makeService()
        _ = try await service.prewarmModel()

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/chat") })
        let json = try bodyJSON(record)
        XCTAssertEqual(json["keep_alive"] as? String, "30m")
    }
}

// MARK: - View model lifecycle tests

@MainActor
final class ModelLifecycleViewModelTests: XCTestCase {
    func testStop_CaptionOnly_PreservesSessionWithoutLegacyLifecycleRequests() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Recorded source.")
        let transcript = harness.viewModel.sessionTranscript

        await harness.viewModel.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.viewModel.captureState, .idle)
        XCTAssertEqual(harness.viewModel.sessionTranscript, transcript)
        XCTAssertEqual(harness.network.value, 0)
        XCTAssertEqual(harness.launcher.launchServeCallCount, 0)
    }

    func testUpdateSettings_LegacyModelChanged_DoesNotLoadOrUnloadOllama() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Existing source.")
        let transcript = harness.viewModel.sessionTranscript
        var settings = harness.viewModel.settings
        settings.ollamaModel = "obsolete-model:7b"

        harness.viewModel.updateSettings(settings)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.viewModel.sessionTranscript, transcript)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.network.value, 0)
        XCTAssertEqual(harness.launcher.launchServeCallCount, 0)
        await harness.viewModel.stop()
    }

    func testPrepareModelOnLaunch_NoReadyTranslation_SendsNoLegacyRequests() async {
        let harness = CaptionOnlyTestHarness()

        await harness.viewModel.prepareModelOnLaunch()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.network.value, 0, "count from construction, without resetting away init requests")
        XCTAssertEqual(harness.launcher.launchServeCallCount, 0)
        XCTAssertTrue(harness.translator.texts.isEmpty)
        XCTAssertFalse(harness.viewModel.isTranslationReady)
    }
}

// MARK: - Settings decoding

final class ModelLifecycleSettingsTests: XCTestCase {

    func testAppSettings_LegacyJSONWithoutTranslationOptIn_PreservesConsentAndLanguages() throws {
        var legacy = AppSettings()
        legacy.historyEnabled = true
        legacy.targetLanguage = .japanese
        legacy.ollamaHost = "old-server.example"
        legacy.customPrompt = "Keep my terminology."
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "translationEnabled")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertFalse(decoded.translationEnabled, "legacy service settings must not silently enable an engine")
        XCTAssertTrue(decoded.historyEnabled)
        XCTAssertEqual(decoded.targetLanguage, .japanese)
        XCTAssertEqual(decoded.customPrompt, "Keep my terminology.")
    }

    func testAppSettings_LegacyJSONWithoutModelLifecycleKeys_DecodesWithDefaults() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "modelKeepAlive")
        object.removeValue(forKey: "unloadModelOnQuit")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.modelKeepAlive, .minutes30)
        XCTAssertTrue(decoded.unloadModelOnQuit)
    }

    func testAppSettings_ModelLifecycleKeys_RoundTrip() throws {
        var settings = AppSettings()
        settings.modelKeepAlive = .untilQuit
        settings.unloadModelOnQuit = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.modelKeepAlive, .untilQuit)
        XCTAssertFalse(decoded.unloadModelOnQuit)
        XCTAssertEqual(settings, decoded)
    }
}
