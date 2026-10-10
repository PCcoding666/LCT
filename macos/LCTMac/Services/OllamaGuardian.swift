import Foundation
import Combine
import AppKit

/// Ollama installation and service status
enum OllamaStatus: Equatable {
    case notInstalled
    case installed
    case running
    case starting
    case stopped
    case error(String)

    var isAvailable: Bool {
        self == .running
    }

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not Installed"
        case .installed:
            return "Installed (Not Running)"
        case .running:
            return "Running"
        case .starting:
            return "Starting..."
        case .stopped:
            return "Stopped"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    var statusColor: String {
        switch self {
        case .running:
            return "green"
        case .starting:
            return "yellow"
        case .notInstalled, .stopped, .error:
            return "red"
        case .installed:
            return "orange"
        }
    }
}

enum OllamaInstallation: Equatable {
    case none
    case app(URL)
    case cli(String)

    var isInstalled: Bool {
        self != .none
    }
}

/// How the running Ollama service was brought up. Only set when LCT itself
/// performed the launch and the service became ready afterwards; a service
/// that was already running leaves this nil so LCT never touches it.
enum OllamaLaunchKind: Equatable {
    case app
    case cli
}

/// Handle to an `ollama serve` process spawned on LCT's behalf. Abstracted so
/// tests can drive termination and lifecycle without real processes.
protocol OllamaServeProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    /// Invoked on the MainActor with the exit code once the process exits.
    var terminationHandler: (@MainActor (Int32) -> Void)? { get set }
    func terminate()
    /// SIGKILL — last resort after terminate() is ignored.
    func forceKill()
}

/// Launches Ollama by either mechanism. Abstracted so tests can count
/// launches and never start real apps or processes.
protocol OllamaLauncher {
    func openOllamaApp(at url: URL)
    func launchOllamaServe(executablePath: String, standardOutput: FileHandle, standardError: FileHandle) throws -> any OllamaServeProcess
}

/// Real launcher: opens Ollama.app via NSWorkspace or spawns `ollama serve`.
struct SystemOllamaLauncher: OllamaLauncher {
    func openOllamaApp(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    func launchOllamaServe(executablePath: String, standardOutput: FileHandle, standardError: FileHandle) throws -> any OllamaServeProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["serve"]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        return SystemOllamaServeProcess(process: process)
    }
}

/// Wraps a spawned `ollama serve` Process. The Process terminationHandler
/// fires on a background queue; the boxed handler hop keeps Swift 6 from
/// complaining about crossing into the MainActor with a non-Sendable closure.
final class SystemOllamaServeProcess: OllamaServeProcess, @unchecked Sendable {
    private let process: Process
    private let handlerLock = NSLock()
    private var boxedTerminationHandler: (@MainActor (Int32) -> Void)?

    var terminationHandler: (@MainActor (Int32) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return boxedTerminationHandler
        }
        set {
            handlerLock.lock()
            boxedTerminationHandler = newValue
            handlerLock.unlock()
        }
    }

    init(process: Process) {
        self.process = process
        process.terminationHandler = { [weak self] process in
            guard let handler = self?.terminationHandler else { return }
            let exitCode = process.terminationStatus
            Task { @MainActor in
                handler(exitCode)
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        process.terminate()
    }

    func forceKill() {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Service for managing Ollama installation and lifecycle
@MainActor
class OllamaGuardian: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var status: OllamaStatus = .stopped
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var ollamaVersion: String?
    /// Set only when LCT itself launched the service (and it became ready).
    /// nil for a service the user started — LCT must never stop that one.
    @Published private(set) var launchedByLCT: OllamaLaunchKind?

    // MARK: - Configuration

    private let ollamaPath: String
    /// Validated endpoint for the local Ollama service, or nil when the
    /// configured URL was malformed or not loopback. No request is made while
    /// this is nil.
    let endpoint: OllamaEndpoint?
    private let session: URLSession
    private let launcher: any OllamaLauncher
    /// Test hook replacing the filesystem/`which`-based installation probe.
    private let installationDetector: (@MainActor () async -> OllamaInstallation)?
    /// Where `ollama serve` stdout/stderr goes (append mode).
    private let serveLogFileURL: URL
    private let startupPollInterval: TimeInterval
    private let startupMaxAttempts: Int
    /// How long stopService() waits for SIGTERM before escalating to SIGKILL.
    private let stopGracePeriod: TimeInterval
    /// Shared in-flight startup; every ensureRunning() caller awaits the same
    /// task so Ollama is never launched twice concurrently.
    private var startupTask: Task<Void, Error>?
    /// The `ollama serve` process LCT spawned (CLI launches only).
    private var serveProcess: (any OllamaServeProcess)?

    // MARK: - Singleton

    static let shared = OllamaGuardian()

    // MARK: - Initialization

    init(ollamaPath: String? = nil,
         ollamaURL: String = "http://localhost:11434",
         session: URLSession? = nil,
         launcher: any OllamaLauncher = SystemOllamaLauncher(),
         installationDetector: (@MainActor () async -> OllamaInstallation)? = nil,
         serveLogFileURL: URL? = nil,
         startupPollInterval: TimeInterval = 1,
         startupMaxAttempts: Int = 20,
         stopGracePeriod: TimeInterval = 2) {
        // Dynamically resolve path if not explicitly provided
        self.ollamaPath = ollamaPath ?? OllamaGuardian.findOllamaPath() ?? "/usr/local/bin/ollama"
        self.endpoint = OllamaEndpoint.parsedLoopback(from: ollamaURL)
        if let session {
            self.session = session
        } else {
            // Status probes must fail fast — a hung Ollama must not stall the
            // patrol or startup on URLSession's 60s default.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            config.timeoutIntervalForResource = 3
            self.session = URLSession(configuration: config)
        }
        self.launcher = launcher
        self.installationDetector = installationDetector
        self.serveLogFileURL = serveLogFileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LCTMac-ollama.log")
        self.startupPollInterval = startupPollInterval
        self.startupMaxAttempts = startupMaxAttempts
        self.stopGracePeriod = stopGracePeriod
    }

    /// Build a request URL for an Ollama API path from the validated
    /// endpoint, or nil when no valid endpoint exists.
    func requestURL(apiPath: String) -> URL? {
        endpoint?.baseURL.appendingPathComponent(apiPath)
    }

    /// Find Ollama executable path from common install locations
    static func findOllamaPath() -> String? {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            "\(NSHomeDirectory())/bin/ollama"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Find Ollama.app from common macOS application locations.
    static func findOllamaAppURL() -> URL? {
        let urls = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Ollama.app")
        ]

        return urls.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Detect whether Ollama is installed as a native app or CLI.
    func detectInstallation() async -> OllamaInstallation {
        if let installationDetector {
            return await installationDetector()
        }

        if let appURL = Self.findOllamaAppURL() {
            return .app(appURL)
        }

        if let cliPath = getOllamaPath() {
            return .cli(cliPath)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = ["ollama"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: .none)
                        return
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if let path, !path.isEmpty {
                        continuation.resume(returning: .cli(path))
                    } else {
                        continuation.resume(returning: .none)
                    }
                } catch {
                    continuation.resume(returning: .none)
                }
            }
        }
    }

    // MARK: - Installation Check

    /// Check if Ollama is installed
    func checkInstallation() async -> Bool {
        await detectInstallation().isInstalled
    }

    /// Get the Ollama executable path
    func getOllamaPath() -> String? {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            "\(NSHomeDirectory())/bin/ollama"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - Service Status

    /// Check if Ollama service is running
    func checkServiceStatus() async -> Bool {
        guard let url = requestURL(apiPath: "api/tags") else {
            return false
        }

        do {
            let (_, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    /// Get Ollama version
    func getVersion() async -> String? {
        guard let url = requestURL(apiPath: "api/version") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                if let json = try? JSONDecoder().decode([String: String].self, from: data) {
                    return json["version"]
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Full Status Check

    /// Perform a complete status check
    func checkStatus() async {
        isChecking = true
        defer { isChecking = false }

        // A running local service is usable even when the CLI is not on PATH.
        if await checkServiceStatus() {
            status = .running
            ollamaVersion = await getVersion()
        } else {
            let installation = await detectInstallation()
            status = installation.isInstalled ? .installed : .notInstalled
        }
    }

    // MARK: - Service Control

    /// Ensure Ollama is running, starting it if necessary. Concurrent callers
    /// share a single startup: the first caller that finds the service down
    /// creates the startup task, later callers await its result instead of
    /// launching Ollama a second time.
    func ensureRunning() async throws {
        if let startupTask {
            appLog("[OllamaGuardian] Startup already in flight — awaiting shared task")
            try await startupTask.value
            return
        }

        if await checkServiceStatus() {
            status = .running
            ollamaVersion = await getVersion()
            return
        }

        // Re-check after the suspension above: another caller may have
        // created the shared startup while we were probing the service.
        if let startupTask {
            appLog("[OllamaGuardian] Startup already in flight — awaiting shared task")
            try await startupTask.value
            return
        }

        // No await between this check and the assignment, so exactly one
        // startup task can ever be created.
        let task = Task { @MainActor in
            defer { self.startupTask = nil }
            try await self.performStartup()
        }
        startupTask = task
        try await task.value
    }

    private func performStartup() async throws {
        let installation = await detectInstallation()
        guard installation.isInstalled else {
            appLog("[OllamaGuardian] ❌ Ollama not installed")
            status = .notInstalled
            throw OllamaGuardianError.notInstalled
        }

        // The service may have come up while installation was being detected.
        if await checkServiceStatus() {
            appLog("[OllamaGuardian] ✅ Service already running")
            status = .running
            ollamaVersion = await getVersion()
            return
        }

        status = .starting

        switch installation {
        case .app(let appURL):
            appLog("[OllamaGuardian] Opening Ollama.app at \(appURL.path)")
            launcher.openOllamaApp(at: appURL)
            try await waitForServiceAfterLaunch()
            launchedByLCT = .app
        case .cli(let ollamaPath):
            try await startCLIService(at: ollamaPath)
        case .none:
            throw OllamaGuardianError.notInstalled
        }
    }

    private func startCLIService(at ollamaPath: String) async throws {
        appLog("[OllamaGuardian] Starting ollama serve from \(ollamaPath) (log: \(serveLogFileURL.path))")

        FileManager.default.createFile(atPath: serveLogFileURL.path, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: serveLogFileURL.path)
        logHandle?.seekToEndOfFile()

        let process: any OllamaServeProcess
        do {
            process = try launcher.launchOllamaServe(
                executablePath: ollamaPath,
                standardOutput: logHandle ?? FileHandle.nullDevice,
                standardError: logHandle ?? FileHandle.nullDevice
            )
        } catch {
            try? logHandle?.close()
            appLog("[OllamaGuardian] ❌ Failed to launch ollama serve: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
            throw OllamaGuardianError.startupFailed(error.localizedDescription)
        }
        // The child holds its own copy of the fd; the parent's can go.
        try? logHandle?.close()
        trackServeProcess(process)

        do {
            try await waitForServiceAfterLaunch(watching: process)
        } catch {
            // Startup failed after we spawned the process — don't leave a
            // half-started serve of ours behind.
            await terminateProcess(process)
            serveProcess = nil
            throw error
        }

        // Only claim ownership when our process is actually still alive — if
        // it exited (e.g. port already taken) but something else answered the
        // readiness probe, that service is not ours to manage.
        if process.isRunning {
            launchedByLCT = .cli
        }
    }

    /// Record the spawned serve process and flip status to .stopped the
    /// moment it exits, so a crash is reflected immediately instead of at the
    /// next probe.
    private func trackServeProcess(_ process: any OllamaServeProcess) {
        serveProcess = process
        process.terminationHandler = { [weak self] exitCode in
            guard let self else { return }
            appLog("[OllamaGuardian] ollama serve exited (code \(exitCode))")
            guard let current = self.serveProcess, current === process else { return }
            self.serveProcess = nil
            if self.launchedByLCT == .cli {
                self.launchedByLCT = nil
            }
            self.status = .stopped
        }
    }

    private func waitForServiceAfterLaunch(watching process: (any OllamaServeProcess)? = nil) async throws {
        for attempt in 1...startupMaxAttempts {
            try await Task.sleep(nanoseconds: UInt64(startupPollInterval * 1_000_000_000))

            if await checkServiceStatus() {
                appLog("[OllamaGuardian] ✅ Service started successfully (poll \(attempt))")
                status = .running
                ollamaVersion = await getVersion()
                return
            }

            if let process, !process.isRunning {
                appLog("[OllamaGuardian] ❌ ollama serve exited during startup")
                status = .error("ollama serve exited during startup")
                throw OllamaGuardianError.startupFailed("ollama serve exited during startup")
            }
        }

        appLog("[OllamaGuardian] ❌ Startup timeout after \(startupMaxAttempts) polls")
        status = .error("Startup timeout")
        throw OllamaGuardianError.startupTimeout
    }

    /// Stop Ollama — but only a serve process LCT itself spawned. A service
    /// the user started (Ollama.app or their own `ollama serve`) is left
    /// running untouched.
    func stopService() async {
        guard launchedByLCT == .cli, let process = serveProcess else {
            appLog("[OllamaGuardian] stopService: no LCT-started serve process — leaving Ollama running")
            return
        }

        appLog("[OllamaGuardian] Stopping the ollama serve process started by LCT")
        await terminateProcess(process)
        serveProcess = nil
        launchedByLCT = nil
        if status == .running || status == .starting {
            status = .stopped
        }
    }

    /// SIGTERM, wait up to `stopGracePeriod`, then SIGKILL if still alive.
    private func terminateProcess(_ process: any OllamaServeProcess) async {
        guard process.isRunning else { return }
        process.terminate()
        let iterations = max(1, Int((stopGracePeriod / 0.05).rounded(.up)))
        for _ in 0..<iterations where process.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            appLog("[OllamaGuardian] ollama serve ignored SIGTERM — sending SIGKILL")
            process.forceKill()
        }
    }

    // MARK: - Installation Help

    /// Get installation instructions URL
    var installationURL: URL {
        URL(string: "https://ollama.com/download")!
    }

    /// Open Ollama download page
    func openInstallationPage() {
        NSWorkspace.shared.open(installationURL)
    }
}

// MARK: - Errors

enum OllamaGuardianError: Error, LocalizedError {
    case notInstalled
    case startupFailed(String)
    case startupTimeout
    case serviceError(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama is not installed. Please install it from https://ollama.com/download or configure a remote Ollama server."
        case .startupFailed(let message):
            return "Failed to start Ollama: \(message)"
        case .startupTimeout:
            return "Ollama startup timed out"
        case .serviceError(let message):
            return "Ollama service error: \(message)"
        }
    }
}
