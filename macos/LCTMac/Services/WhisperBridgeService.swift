import Foundation

/// Error types for WhisperBridge
enum WhisperBridgeError: Error, LocalizedError {
    case engineNotRunning
    case invalidResponse
    case transcriptionFailed(String)
    case networkError(Error)
    case pythonNotFound
    case modelNotDownloaded
    
    var errorDescription: String? {
        switch self {
        case .engineNotRunning:
            return "WhisperEngine is not running"
        case .invalidResponse:
            return "Invalid response from WhisperEngine"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .pythonNotFound:
            return "Python not found at specified path"
        case .modelNotDownloaded:
            return "Whisper model not downloaded"
        }
    }
}

/// Response structures for WhisperEngine
struct WhisperHealthResponse: Codable {
    let status: String
    let whisperLoaded: Bool
    let diarizationLoaded: Bool
    
    enum CodingKeys: String, CodingKey {
        case status
        case whisperLoaded = "whisper_loaded"
        case diarizationLoaded = "diarization_loaded"
    }
}

struct WhisperTranscriptionResponse: Codable {
    let success: Bool
    let text: String?
    let language: String?
    let segments: [WhisperSegment]?
    let speakers: [String]?
    let error: String?
}

struct WhisperSegment: Codable, Identifiable {
    var id: String { "\(start)-\(end)" }
    let text: String
    let start: Double
    let end: Double
    let speaker: String?
    let confidence: Float?
}

/// Service for communicating with Python WhisperEngine
@MainActor
class WhisperBridgeService: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isEngineRunning: Bool = false
    @Published private(set) var isTranscribing: Bool = false
    @Published private(set) var lastError: String?
    
    // MARK: - Configuration
    private var settings: AppSettings
    private let enginePort: Int = 5678
    private let engineHost: String = "127.0.0.1"
    
    // MARK: - Private Properties
    private var engineProcess: Process?
    private let session: URLSession
    private var healthCheckTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(settings: AppSettings = .load()) {
        self.settings = settings
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }
    
    deinit {
        stopEngine()
    }
    
    // MARK: - Engine Control
    
    /// Start the WhisperEngine Python process
    func startEngine() async throws {
        guard !isEngineRunning else { return }
        
        let pythonPath = settings.pythonPath
        
        // Check if Python exists
        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw WhisperBridgeError.pythonNotFound
        }
        
        // Get WhisperEngine path
        let enginePath = Bundle.main.resourcePath.map { "\($0)/../WhisperEngine/main.py" }
            ?? getDefaultEnginePath()
        
        guard FileManager.default.fileExists(atPath: enginePath) else {
            lastError = "WhisperEngine not found at \(enginePath)"
            throw WhisperBridgeError.engineNotRunning
        }
        
        // Build command arguments
        var arguments = [
            enginePath,
            "--port", String(enginePort),
            "--host", engineHost,
            "--model", settings.whisperModelSize.rawValue
        ]
        
        if !settings.huggingFaceToken.isEmpty {
            arguments.append(contentsOf: ["--hf-token", settings.huggingFaceToken])
        }
        
        if !settings.enableDiarization {
            arguments.append("--no-diarization")
        }
        
        // Create and start process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        
        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Log output
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            if let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty {
                print("[WhisperEngine] \(output)")
            }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if let output = String(data: handle.availableData, encoding: .utf8), !output.isEmpty {
                print("[WhisperEngine ERROR] \(output)")
            }
        }
        
        do {
            try process.run()
            self.engineProcess = process
            
            // Wait for engine to be ready
            try await waitForEngineReady()
            
            isEngineRunning = true
            lastError = nil
            
            // Start health check loop
            startHealthCheck()
            
            print("WhisperEngine started successfully")
            
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    /// Stop the WhisperEngine process
    func stopEngine() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        
        if let process = engineProcess, process.isRunning {
            // Try graceful shutdown first
            Task {
                try? await unloadModels()
            }
            
            process.terminate()
            process.waitUntilExit()
        }
        
        engineProcess = nil
        isEngineRunning = false
        
        print("WhisperEngine stopped")
    }
    
    /// Wait for engine to be ready
    private func waitForEngineReady(timeout: TimeInterval = 60) async throws {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            if await checkHealth() {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        throw WhisperBridgeError.engineNotRunning
    }
    
    /// Start periodic health checks
    private func startHealthCheck() {
        healthCheckTask = Task {
            while !Task.isCancelled {
                let healthy = await checkHealth()
                if !healthy && isEngineRunning {
                    await MainActor.run {
                        isEngineRunning = false
                        lastError = "WhisperEngine stopped unexpectedly"
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }
    }
    
    // MARK: - API Methods
    
    /// Check engine health
    func checkHealth() async -> Bool {
        guard let url = URL(string: "http://\(engineHost):\(enginePort)/health") else {
            return false
        }
        
        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }
            
            let healthResponse = try JSONDecoder().decode(WhisperHealthResponse.self, from: data)
            return healthResponse.status == "ok"
            
        } catch {
            return false
        }
    }
    
    /// Transcribe audio data
    func transcribe(
        audioData: Data,
        sampleRate: Int = 16000,
        language: String? = nil,
        enableDiarization: Bool = true
    ) async throws -> WhisperTranscriptionResponse {
        guard isEngineRunning else {
            throw WhisperBridgeError.engineNotRunning
        }
        
        isTranscribing = true
        defer { isTranscribing = false }
        
        guard let url = URL(string: "http://\(engineHost):\(enginePort)/transcribe") else {
            throw WhisperBridgeError.invalidResponse
        }
        
        let requestBody: [String: Any] = [
            "audio_base64": audioData.base64EncodedString(),
            "sample_rate": sampleRate,
            "language": language as Any,
            "enable_diarization": enableDiarization && settings.enableDiarization
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WhisperBridgeError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                throw WhisperBridgeError.transcriptionFailed("HTTP \(httpResponse.statusCode)")
            }
            
            let transcription = try JSONDecoder().decode(WhisperTranscriptionResponse.self, from: data)
            
            if !transcription.success, let error = transcription.error {
                throw WhisperBridgeError.transcriptionFailed(error)
            }
            
            return transcription
            
        } catch let error as WhisperBridgeError {
            throw error
        } catch {
            throw WhisperBridgeError.networkError(error)
        }
    }
    
    /// Unload models to free memory
    func unloadModels() async throws {
        guard let url = URL(string: "http://\(engineHost):\(enginePort)/unload") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        _ = try? await session.data(for: request)
    }
    
    // MARK: - Helpers
    
    private func getDefaultEnginePath() -> String {
        // Try to find WhisperEngine in common locations
        let possiblePaths = [
            // Development path
            FileManager.default.currentDirectoryPath + "/macos/WhisperEngine/main.py",
            // Installed path
            Bundle.main.bundlePath + "/Contents/Resources/WhisperEngine/main.py",
            // Home directory
            NSHomeDirectory() + "/.lct/WhisperEngine/main.py"
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return possiblePaths[0]
    }
    
    /// Update settings
    func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
    }
    
    /// Convert transcription response to app models
    func convertToTranscriptionResults(_ response: WhisperTranscriptionResponse) -> [TranscriptionResult] {
        guard let segments = response.segments else {
            if let text = response.text, !text.isEmpty {
                return [TranscriptionResult(text: text)]
            }
            return []
        }
        
        return segments.map { segment in
            TranscriptionResult(
                text: segment.text,
                speaker: segment.speaker,
                startTime: segment.start,
                endTime: segment.end,
                isVolatile: false,
                confidence: segment.confidence
            )
        }
    }
}
