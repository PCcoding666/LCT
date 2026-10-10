import Foundation
import XCTest
@testable import LCTMac

/// Mutable, thread-safe state the stub URLProtocol reads on background
/// threads; tests flip it from the MainActor to simulate Ollama going up/down.
final class OllamaStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var _serviceUp = false
    private var _loadedModels: [String] = []
    private var _chatRequestCount = 0

    var serviceUp: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _serviceUp }
        set { lock.lock(); _serviceUp = newValue; lock.unlock() }
    }

    var loadedModels: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _loadedModels }
        set { lock.lock(); _loadedModels = newValue; lock.unlock() }
    }

    var chatRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _chatRequestCount
    }

    func addLoadedModel(_ name: String) {
        lock.lock()
        if !_loadedModels.contains(name) { _loadedModels.append(name) }
        lock.unlock()
    }

    func noteChatRequest() {
        lock.lock()
        _chatRequestCount += 1
        lock.unlock()
    }
}

final class GuardianStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var state: OllamaStubState?
    /// Artificial delay for /api/chat (keeps transient notices observable).
    nonisolated(unsafe) static var chatDelay: TimeInterval = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.state, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        guard state.serviceUp else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let path = url.path
        let body: Data
        if path.hasSuffix("/api/tags") {
            body = Data(#"{"models":[]}"#.utf8)
        } else if path.hasSuffix("/api/version") {
            body = Data(#"{"version":"0.0.0-test"}"#.utf8)
        } else if path.hasSuffix("/api/ps") {
            let names = state.loadedModels.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
            body = Data(#"{"models":[\#(names)]}"#.utf8)
        } else if path.hasSuffix("/api/chat") {
            state.noteChatRequest()
            if Self.chatDelay > 0 {
                Thread.sleep(forTimeInterval: Self.chatDelay)
            }
            // A successful prewarm holds the model in memory — reflect that in /api/ps.
            if let requestBody = Self.readBody(of: request),
               let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any],
               let model = json["model"] as? String {
                state.addLoadedModel(model)
            }
            body = Data(#"{"message":{"role":"assistant","content":"ok"},"done":true}"#.utf8)
        } else {
            body = Data()
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

// MARK: - Fakes

/// Test double for an `ollama serve` process. Only ever touched from the
/// MainActor in these tests, hence @unchecked Sendable.
final class FakeOllamaServeProcess: OllamaServeProcess, @unchecked Sendable {
    private(set) var isRunning: Bool
    private(set) var terminateCallCount = 0
    private(set) var forceKillCallCount = 0
    /// Simulates a process that ignores SIGTERM (forces the SIGKILL path).
    var survivesTerminate = false
    var terminationHandler: (@MainActor (Int32) -> Void)?

    init(startsRunning: Bool = true) {
        self.isRunning = startsRunning
    }

    func terminate() {
        terminateCallCount += 1
        if !survivesTerminate { isRunning = false }
    }

    func forceKill() {
        forceKillCallCount += 1
        isRunning = false
    }

    /// Simulates the process exiting on its own (crash, port conflict).
    @MainActor
    func simulateExit(code: Int32 = 1) {
        isRunning = false
        terminationHandler?(code)
    }
}

/// Test double recording every launch request; never starts real processes.
final class FakeOllamaLauncher: OllamaLauncher {
    private(set) var openAppCallCount = 0
    private(set) var launchServeCallCount = 0
    private(set) var launchedProcesses: [FakeOllamaServeProcess] = []
    var errorToThrow: Error?
    /// Returned processes are already dead on arrival (port conflict & co.).
    var launchesDeadProcess = false
    var onOpenApp: (() -> Void)?
    var onLaunchServe: (() -> Void)?

    func openOllamaApp(at url: URL) {
        openAppCallCount += 1
        onOpenApp?()
    }

    func launchOllamaServe(executablePath: String, standardOutput: FileHandle, standardError: FileHandle) throws -> any OllamaServeProcess {
        launchServeCallCount += 1
        if let errorToThrow { throw errorToThrow }
        let process = FakeOllamaServeProcess(startsRunning: !launchesDeadProcess)
        launchedProcesses.append(process)
        onLaunchServe?()
        return process
    }
}

// MARK: - Guardian tests

@MainActor
final class OllamaGuardianTests: XCTestCase {

    private let state = OllamaStubState()
    private let launcher = FakeOllamaLauncher()

    override func setUp() {
        super.setUp()
        GuardianStubURLProtocol.state = state
        GuardianStubURLProtocol.chatDelay = 0
    }

    override func tearDown() {
        GuardianStubURLProtocol.state = nil
        GuardianStubURLProtocol.chatDelay = 0
        super.tearDown()
    }

    private func makeGuardian(
        installation: OllamaInstallation = .cli("/fake/ollama"),
        startupMaxAttempts: Int = 50
    ) -> OllamaGuardian {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuardianStubURLProtocol.self]
        return OllamaGuardian(
            ollamaPath: "/fake/ollama",
            ollamaURL: "http://localhost:11434",
            session: URLSession(configuration: config),
            launcher: launcher,
            installationDetector: { installation },
            serveLogFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("LCTMacTests-ollama-\(UUID().uuidString).log"),
            startupPollInterval: 0.01,
            startupMaxAttempts: startupMaxAttempts,
            stopGracePeriod: 0.1
        )
    }

    /// Three overlapping callers must share one startup: the launcher runs
    /// once and every caller gets the same success.
    func testEnsureRunning_ConcurrentCallers_LaunchOnlyOnce() async throws {
        state.serviceUp = false
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        let guardian = makeGuardian()

        func attempt() async -> Result<Void, Error> {
            do {
                try await guardian.ensureRunning()
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        async let first = attempt()
        async let second = attempt()
        async let third = attempt()
        let results = await [first, second, third]

        for (index, result) in results.enumerated() {
            if case .failure(let error) = result {
                XCTFail("caller \(index) failed: \(error)")
            }
        }
        XCTAssertEqual(launcher.launchServeCallCount, 1,
                       "concurrent ensureRunning() calls must share a single startup")
        XCTAssertEqual(guardian.status, .running)
        XCTAssertEqual(guardian.launchedByLCT, .cli)
    }

    /// A failed startup reaches every concurrent caller, and the next
    /// ensureRunning() retries the launch instead of staying stuck.
    func testEnsureRunning_ConcurrentFailure_AllFailAndNextCallRetries() async throws {
        state.serviceUp = false
        launcher.errorToThrow = NSError(domain: "test", code: 1, userInfo: nil)
        let guardian = makeGuardian()

        func attempt() async -> Result<Void, Error> {
            do {
                try await guardian.ensureRunning()
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        async let first = attempt()
        async let second = attempt()
        async let third = attempt()
        let results = await [first, second, third]

        XCTAssertEqual(results.count, 3)
        for (index, result) in results.enumerated() {
            guard case .failure(let error) = result, let guardianError = error as? OllamaGuardianError else {
                XCTFail("caller \(index) must fail with an OllamaGuardianError")
                continue
            }
            guard case .startupFailed = guardianError else {
                XCTFail("caller \(index) must fail with startupFailed, got \(guardianError)")
                continue
            }
        }
        XCTAssertEqual(launcher.launchServeCallCount, 1,
                       "even a failing startup must be shared between concurrent callers")

        launcher.errorToThrow = nil
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        try await guardian.ensureRunning()
        XCTAssertEqual(launcher.launchServeCallCount, 2, "after a failure the next call must retry the launch")
        XCTAssertEqual(guardian.status, .running)
    }

    /// A service that was already running is not LCT's: nothing is launched
    /// and stopService() leaves it alone.
    func testEnsureRunning_ServiceAlreadyRunning_DoesNotLaunchAndStopIsNoOp() async throws {
        state.serviceUp = true
        let guardian = makeGuardian()

        try await guardian.ensureRunning()

        XCTAssertEqual(guardian.status, .running)
        XCTAssertEqual(guardian.ollamaVersion, "0.0.0-test")
        XCTAssertEqual(launcher.launchServeCallCount, 0)
        XCTAssertEqual(launcher.openAppCallCount, 0)
        XCTAssertNil(guardian.launchedByLCT,
                     "a pre-existing service is not LCT's — stopService() must never touch it")

        await guardian.stopService()

        XCTAssertTrue(launcher.launchedProcesses.allSatisfy { $0.terminateCallCount == 0 })
        XCTAssertEqual(guardian.status, .running, "stopService() must not disturb a service LCT did not start")
    }

    /// When the LCT-spawned serve process exits unexpectedly, status flips to
    /// .stopped immediately and ownership is cleared.
    func testServeProcess_UnexpectedExit_StatusBecomesStopped() async throws {
        state.serviceUp = false
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        let guardian = makeGuardian()
        try await guardian.ensureRunning()
        XCTAssertEqual(guardian.launchedByLCT, .cli)

        let process = try XCTUnwrap(launcher.launchedProcesses.first)
        process.simulateExit(code: 1)

        XCTAssertEqual(guardian.status, .stopped)
        XCTAssertNil(guardian.launchedByLCT)

        // Nothing left to stop — the process is already gone.
        await guardian.stopService()
        XCTAssertEqual(process.terminateCallCount, 0)
    }

    /// stopService() terminates the LCT-started CLI process (SIGTERM is
    /// enough) and reports the service stopped.
    func testStopService_LCTStartedCLIProcess_TerminatesIt() async throws {
        state.serviceUp = false
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        let guardian = makeGuardian()
        try await guardian.ensureRunning()
        let process = try XCTUnwrap(launcher.launchedProcesses.first)

        await guardian.stopService()

        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEqual(process.forceKillCallCount, 0, "a well-behaved process must not need SIGKILL")
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(guardian.launchedByLCT)
        XCTAssertEqual(guardian.status, .stopped)
    }

    /// A serve process that ignores SIGTERM is escalated to SIGKILL.
    func testStopService_ProcessIgnoresTerminate_EscalatesToForceKill() async throws {
        state.serviceUp = false
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        let guardian = makeGuardian()
        try await guardian.ensureRunning()
        let process = try XCTUnwrap(launcher.launchedProcesses.first)
        process.survivesTerminate = true

        await guardian.stopService()

        XCTAssertEqual(process.terminateCallCount, 1)
        XCTAssertEqual(process.forceKillCallCount, 1, "a process surviving SIGTERM must get SIGKILL")
        XCTAssertFalse(process.isRunning)
    }

    /// Ollama.app launches are tracked as .app — stopService() must not try
    /// to kill anything for them.
    func testStopService_AppLaunch_LeavesOllamaAppAlone() async throws {
        state.serviceUp = false
        launcher.onOpenApp = { [state] in state.serviceUp = true }
        let guardian = makeGuardian(installation: .app(URL(fileURLWithPath: "/Applications/Ollama.app")))

        try await guardian.ensureRunning()

        XCTAssertEqual(launcher.openAppCallCount, 1)
        XCTAssertEqual(launcher.launchServeCallCount, 0)
        XCTAssertEqual(guardian.launchedByLCT, .app)
        XCTAssertEqual(guardian.status, .running)

        await guardian.stopService()

        XCTAssertEqual(launcher.launchServeCallCount, 0, "no serve process exists to terminate")
        XCTAssertEqual(guardian.status, .running, "stopService() must not touch Ollama.app")
        XCTAssertEqual(guardian.launchedByLCT, .app)
    }

    /// When the startup probe times out, the half-started serve process LCT
    /// spawned is cleaned up instead of being orphaned.
    func testStartService_StartupTimeout_CleansUpSpawnedProcess() async throws {
        state.serviceUp = false  // never comes up
        let guardian = makeGuardian(startupMaxAttempts: 5)

        do {
            try await guardian.ensureRunning()
            XCTFail("startup must time out when the service never answers")
        } catch let error as OllamaGuardianError {
            guard case .startupTimeout = error else {
                return XCTFail("expected startupTimeout, got \(error)")
            }
        }

        let process = try XCTUnwrap(launcher.launchedProcesses.first)
        XCTAssertEqual(process.terminateCallCount, 1,
                       "a half-started serve process must not be orphaned on startup failure")
        XCTAssertFalse(process.isRunning)
        XCTAssertNil(guardian.launchedByLCT)
    }

    /// If the spawned process dies before the service answers (e.g. the port
    /// is taken), startup fails fast instead of polling until timeout, and LCT
    /// does not claim ownership of whatever answered later.
    func testStartService_ProcessExitsDuringStartup_FailsFast() async throws {
        state.serviceUp = false
        launcher.launchesDeadProcess = true
        let guardian = makeGuardian(startupMaxAttempts: 50)

        do {
            try await guardian.ensureRunning()
            XCTFail("startup must fail when the serve process exits immediately")
        } catch let error as OllamaGuardianError {
            guard case .startupFailed = error else {
                return XCTFail("expected startupFailed, got \(error)")
            }
        }
        XCTAssertNil(guardian.launchedByLCT)
    }
}
