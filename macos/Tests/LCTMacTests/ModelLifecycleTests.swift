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
                return (response, Data(#"{"models": [{"name": "model-a:old"}]}"#.utf8))
            }
            if path.hasSuffix("/api/tags") {
                return (response, Data(#"{"models": [{"name": "model-a:old"}, {"name": "model-b:new"}]}"#.utf8))
            }
            if path.hasSuffix("/api/chat") {
                return (response, Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8))
            }
            return (response, Data())
        }
        // Tests here load/save AppSettings through the VM; keep the shared
        // store clean so other suites see defaults.
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        LifecycleMockURLProtocol.requestHandler = nil
        LifecycleMockURLProtocol.recorder = nil
        AppSettings.resetSetupFlag()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    private func makeViewModel(settings: AppSettings) -> TranscriptionViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LifecycleMockURLProtocol.self]
        let service = OllamaService(settings: settings, session: URLSession(configuration: config))
        // An endpoint-less guardian can never reach the network; its status
        // probe degrades to local filesystem checks only.
        let guardian = OllamaGuardian(ollamaPath: "/bin/echo", ollamaURL: "not a url")
        return TranscriptionViewModel(settings: settings, ollamaService: service, ollamaGuardian: guardian)
    }

    private func localSettings(model: String) -> AppSettings {
        var settings = AppSettings()
        settings.ollamaModel = model
        settings.ollamaTimeout = 1
        return settings
    }

    /// Poll until `condition` holds or the deadline passes; returns the final value.
    private func waitFor(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testStop_DoesNotSendUnloadRequest() async throws {
        let viewModel = makeViewModel(settings: localSettings(model: "model-a:old"))
        viewModel.captureState = .capturing

        await viewModel.stop()

        XCTAssertEqual(viewModel.captureState, .idle)
        _ = await waitFor { !self.recorder.snapshot.isEmpty }
        try await Task.sleep(nanoseconds: 200_000_000)
        let unloadRequests = recorder.snapshot.filter { $0.path.hasSuffix("/api/generate") }
        XCTAssertTrue(unloadRequests.isEmpty,
                      "stop() must not unload the model; keep_alive governs the idle timeout")
    }

    func testUpdateSettings_ModelChanged_UnloadsOldModelByName() async throws {
        let viewModel = makeViewModel(settings: localSettings(model: "model-a:old"))

        viewModel.updateSettings(localSettings(model: "model-b:new"))

        let sawUnload = await waitFor {
            self.recorder.snapshot.contains { $0.path.hasSuffix("/api/generate") }
        }
        XCTAssertTrue(sawUnload, "switching models must unload the old model")

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/generate") })
        let body = try XCTUnwrap(record.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "model-a:old",
                       "the unload request must name the OLD model, not the new one")
        XCTAssertEqual(json["keep_alive"] as? Int, 0)
    }

    func testUpdateSettings_ModelChanged_PrewarmsNewModel() async throws {
        let viewModel = makeViewModel(settings: localSettings(model: "model-a:old"))

        viewModel.updateSettings(localSettings(model: "model-b:new"))

        let sawPrewarm = await waitFor {
            self.recorder.snapshot.contains { $0.path.hasSuffix("/api/chat") }
        }
        XCTAssertTrue(sawPrewarm, "switching models while idle must prewarm the new model")

        let record = try XCTUnwrap(recorder.snapshot.first { $0.path.hasSuffix("/api/chat") })
        let body = try XCTUnwrap(record.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "model-b:new")

        let stateSettled = await waitFor { viewModel.modelState == .loaded }
        XCTAssertTrue(stateSettled, "modelState must become .loaded after the new model prewarms")
    }

    func testPrepareModelOnLaunch_RemoteOllama_SendsNoRequests() async throws {
        AppSettings.markSetupComplete()
        var settings = localSettings(model: "model-a:old")
        settings.ollamaHost = "ollama.example.com"
        settings.remoteOllamaOptIn = true
        let viewModel = makeViewModel(settings: settings)

        try await Task.sleep(nanoseconds: 500_000_000)
        recorder.reset()

        await viewModel.prepareModelOnLaunch()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(recorder.snapshot.isEmpty,
                      "launch prewarm is local-only; remote Ollama must not be probed")
    }

    func testPrepareModelOnLaunch_SetupIncomplete_SendsNoRequests() async throws {
        AppSettings.resetSetupFlag()
        let viewModel = makeViewModel(settings: localSettings(model: "model-a:old"))

        try await Task.sleep(nanoseconds: 500_000_000)
        recorder.reset()

        await viewModel.prepareModelOnLaunch()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(recorder.snapshot.isEmpty,
                      "before onboarding completes, launch prewarm must not probe Ollama")
    }
}

// MARK: - Settings decoding

final class ModelLifecycleSettingsTests: XCTestCase {

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
