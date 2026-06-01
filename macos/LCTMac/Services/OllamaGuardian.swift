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

/// Service for managing Ollama installation and lifecycle
@MainActor
class OllamaGuardian: ObservableObject {
    // MARK: - Published Properties
    
    @Published private(set) var status: OllamaStatus = .stopped
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var ollamaVersion: String?
    
    // MARK: - Configuration
    
    private let ollamaPath: String
    private let ollamaURL: String
    private var healthCheckTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    
    // MARK: - Singleton
    
    static let shared = OllamaGuardian()
    
    // MARK: - Initialization
    
    init(ollamaPath: String? = nil, ollamaURL: String = "http://localhost:11434") {
        // Dynamically resolve path if not explicitly provided
        self.ollamaPath = ollamaPath ?? OllamaGuardian.findOllamaPath() ?? "/usr/local/bin/ollama"
        self.ollamaURL = ollamaURL
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
    
    // MARK: - Installation Check
    
    /// Check if Ollama is installed
    func checkInstallation() async -> Bool {
        // Check common installation paths (file existence checks are fast, OK on MainActor)
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/usr/bin/ollama",
            "\(NSHomeDirectory())/bin/ollama"
        ]
        
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        // Run `which ollama` on a background queue to avoid blocking the main thread.
        // Process.waitUntilExit() is synchronous and can hang for seconds if PATH
        // resolution involves network drives or broken shell config.
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
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
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
        guard let url = URL(string: "\(ollamaURL)/api/tags") else {
            return false
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
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
        guard let url = URL(string: "\(ollamaURL)/api/version") else {
            return nil
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
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
        
        // Check installation first
        if !(await checkInstallation()) {
            status = .notInstalled
            return
        }
        
        // Check if service is running
        let isRunning = await checkServiceStatus()
        if isRunning {
            status = .running
            ollamaVersion = await getVersion()
        } else {
            status = .installed
        }
    }
    
    // MARK: - Service Control
    
    /// Start Ollama service
    func startService() async throws {
        print("[OllamaGuardian] startService() called")
        
        guard await checkInstallation() else {
            print("[OllamaGuardian] ❌ Ollama not installed")
            throw OllamaGuardianError.notInstalled
        }
        
        // Check if already running
        print("[OllamaGuardian] Checking if service is already running...")
        if await checkServiceStatus() {
            print("[OllamaGuardian] ✅ Service already running")
            status = .running
            return
        }
        
        status = .starting
        
        guard let ollamaPath = getOllamaPath() else {
            print("[OllamaGuardian] ❌ Cannot find Ollama path")
            throw OllamaGuardianError.notInstalled
        }
        
        print("[OllamaGuardian] Starting Ollama from: \(ollamaPath)")
        
        // Start Ollama serve in background
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["serve"]
        
        // Redirect output to prevent terminal spam
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            print("[OllamaGuardian] Process started, waiting for service...")
            
            // Wait for service to be ready (with timeout)
            let maxAttempts = 15  // 15 seconds timeout (reduced from 30)
            for attempt in 1...maxAttempts {
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                
                if await checkServiceStatus() {
                    print("[OllamaGuardian] ✅ Service started successfully after \(attempt)s")
                    status = .running
                    ollamaVersion = await getVersion()
                    return
                }
                
                // Update status to show progress
                print("[OllamaGuardian] Waiting for Ollama to start... (\(attempt)s)")
            }
            
            // Timeout reached
            print("[OllamaGuardian] ❌ Startup timeout after \(maxAttempts)s")
            status = .error("Startup timeout")
            throw OllamaGuardianError.startupTimeout
            
        } catch let error as OllamaGuardianError {
            throw error
        } catch {
            print("[OllamaGuardian] ❌ Startup failed: \(error)")
            status = .error(error.localizedDescription)
            throw OllamaGuardianError.startupFailed(error.localizedDescription)
        }
    }
    
    /// Stop Ollama service (if we started it)
    func stopService() async {
        // Ollama doesn't have a direct stop command via API
        // The service will stop when the process is terminated
        status = .stopped
    }
    
    // MARK: - Auto-Start
    
    /// Ensure Ollama is running, starting it if necessary
    func ensureRunning() async throws {
        await checkStatus()
        
        switch status {
        case .running:
            return  // Already running
        case .installed, .stopped:
            try await startService()
        case .notInstalled:
            throw OllamaGuardianError.notInstalled
        case .starting:
            // Wait for startup to complete
            try await waitForStartup()
        case .error(let message):
            throw OllamaGuardianError.serviceError(message)
        }
    }
    
    private func waitForStartup() async throws {
        let maxAttempts = 30
        for _ in 1...maxAttempts {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            if status == .running {
                return
            }
            
            if case .error(let message) = status {
                throw OllamaGuardianError.serviceError(message)
            }
        }
        
        throw OllamaGuardianError.startupTimeout
    }
    
    // MARK: - Health Monitoring
    
    /// Start periodic health checks
    func startHealthMonitoring(interval: TimeInterval = 30) {
        stopHealthMonitoring()
        
        healthCheckTask = Task {
            while !Task.isCancelled {
                await checkStatus()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
    
    /// Stop health monitoring
    func stopHealthMonitoring() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }
    
    // MARK: - Installation Help
    
    /// Get installation instructions URL
    var installationURL: URL {
        URL(string: "https://ollama.ai/download")!
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
            return "Ollama is not installed. Please install it from https://ollama.ai"
        case .startupFailed(let message):
            return "Failed to start Ollama: \(message)"
        case .startupTimeout:
            return "Ollama startup timed out"
        case .serviceError(let message):
            return "Ollama service error: \(message)"
        }
    }
}
