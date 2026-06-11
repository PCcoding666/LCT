import Foundation
import Combine

/// Model information from Ollama
struct OllamaModel: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    let modifiedAt: String?
    let size: Int64?
    let digest: String?
    let details: OllamaModelDetails?

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
    }

    /// Formatted size string
    var formattedSize: String {
        guard let size = size else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    /// Short name (without tag)
    var shortName: String {
        name.components(separatedBy: ":").first ?? name
    }

    /// Tag (version)
    var tag: String {
        let parts = name.components(separatedBy: ":")
        return parts.count > 1 ? parts[1] : "latest"
    }
}

struct OllamaModelDetails: Codable, Equatable {
    let format: String?
    let family: String?
    let parameterSize: String?
    let quantizationLevel: String?

    enum CodingKeys: String, CodingKey {
        case format
        case family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }
}

/// Response for listing models
struct OllamaModelsResponse: Codable {
    let models: [OllamaModel]
}

/// Pull progress information
struct OllamaPullProgress: Codable {
    let status: String
    let digest: String?
    let total: Int64?
    let completed: Int64?

    var progress: Double {
        guard let total = total, let completed = completed, total > 0 else {
            return 0
        }
        return Double(completed) / Double(total)
    }

    var isComplete: Bool {
        status == "success"
    }
}

/// Recommended models for translation
struct RecommendedModel {
    let name: String
    let displayName: String
    let description: String
    let size: String
    let sizeBytes: Int64
    let isDefault: Bool

    /// Default model for translation - MLX-optimized Qwen 4B
    static let defaultModel = RecommendedModel(
        name: "qwen3.5:4b-mlx",
        displayName: "Qwen3.5 4B MLX",
        description: "MLX-optimized 4B model for low-latency local translation",
        size: "~2.5GB",
        sizeBytes: 2_500_000_000,
        isDefault: true
    )

    static let all: [RecommendedModel] = [
        defaultModel,
        RecommendedModel(
            name: "translategemma:4b-it-q4_K_M",
            displayName: "TranslateGemma 4B",
            description: "Google's specialized translation model (55 languages)",
            size: "~3.3GB",
            sizeBytes: 3_300_000_000,
            isDefault: false
        ),
        RecommendedModel(
            name: "qwen2.5:3b",
            displayName: "Qwen 2.5 3B",
            description: "Fast and efficient, great for translation",
            size: "~2GB",
            sizeBytes: 2_000_000_000,
            isDefault: false
        ),
        RecommendedModel(
            name: "llama3.2:3b",
            displayName: "Llama 3.2 3B",
            description: "Meta's latest small model",
            size: "~2GB",
            sizeBytes: 2_000_000_000,
            isDefault: false
        )
    ]
}

/// Service for managing Ollama models
@MainActor
class OllamaModelManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var installedModels: [OllamaModel] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isPulling: Bool = false
    @Published private(set) var pullProgress: Double = 0
    @Published private(set) var pullStatus: String = ""
    @Published private(set) var currentPullingModel: String?
    @Published private(set) var lastError: String?

    // MARK: - Configuration

    private let baseURL: String
    private var pullTask: Task<Void, Never>?
    private static let modelDownloadFreeSpaceBufferBytes: Int64 = 2_000_000_000

    // MARK: - Initialization

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    // MARK: - Model Listing

    /// Fetch list of installed models
    func fetchInstalledModels() async {
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "\(baseURL)/api/tags") else {
            lastError = "Invalid API URL"
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                lastError = "Failed to fetch models"
                return
            }

            let modelsResponse = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            installedModels = modelsResponse.models.sorted { $0.name < $1.name }
            lastError = nil

        } catch {
            lastError = error.localizedDescription
            print("[OllamaModelManager] Error fetching models: \(error)")
        }
    }

    /// Check if a specific model is installed
    func isModelInstalled(_ modelName: String) -> Bool {
        installedModels.contains { $0.name == modelName || $0.name.hasPrefix("\(modelName):") }
    }

    /// Get installed model by name
    func getModel(_ modelName: String) -> OllamaModel? {
        installedModels.first { $0.name == modelName } ??
        installedModels.first { $0.name.hasPrefix("\(modelName):") }
    }

    // MARK: - Model Pulling

    /// Pull (download) a model
    func pullModel(_ modelName: String) async throws {
        guard !isPulling else {
            throw OllamaModelError.alreadyPulling
        }

        if let recommendedModel = RecommendedModel.all.first(where: { $0.name == modelName }) {
            try ensureSufficientDiskSpace(for: recommendedModel)
        }

        isPulling = true
        pullProgress = 0
        pullStatus = "Starting download..."
        currentPullingModel = modelName
        lastError = nil

        defer {
            isPulling = false
            currentPullingModel = nil
        }

        guard let url = URL(string: "\(baseURL)/api/pull") else {
            throw OllamaModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["name": modelName]
        request.httpBody = try JSONEncoder().encode(body)

        // Use streaming to get progress updates
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.pullFailed("Server returned error")
        }

        // Process streaming response
        for try await line in asyncBytes.lines {
            guard !Task.isCancelled else {
                throw CancellationError()
            }

            guard let data = line.data(using: .utf8),
                  let progress = try? JSONDecoder().decode(OllamaPullProgress.self, from: data) else {
                continue
            }

            pullStatus = progress.status
            pullProgress = progress.progress

            if progress.isComplete {
                pullProgress = 1.0
                pullStatus = "Download complete!"

                // Refresh model list
                await fetchInstalledModels()
                return
            }
        }
    }

    /// Cancel ongoing model pull
    func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPulling = false
        pullProgress = 0
        pullStatus = "Cancelled"
        currentPullingModel = nil
    }

    // MARK: - Model Deletion

    /// Delete a model
    func deleteModel(_ modelName: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/delete") else {
            throw OllamaModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["name": modelName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.deleteFailed("Server returned error")
        }

        // Refresh model list
        await fetchInstalledModels()
    }

    // MARK: - Model Loading

    /// Preload a model into memory
    func loadModel(_ modelName: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120  // Loading can take time

        // Send empty prompt to just load the model
        let body: [String: Any] = [
            "model": modelName,
            "prompt": "",
            "keep_alive": "5m"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.loadFailed("Failed to load model")
        }
    }

    /// Unload a model from memory
    func unloadModel(_ modelName: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaModelError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set keep_alive to 0 to unload immediately
        let body: [String: Any] = [
            "model": modelName,
            "prompt": "",
            "keep_alive": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.unloadFailed("Failed to unload model")
        }
    }

    // MARK: - Recommendations

    /// Get recommended models that are not yet installed
    func getRecommendedModelsToInstall() -> [RecommendedModel] {
        RecommendedModel.all.filter { !isModelInstalled($0.name) }
    }

    /// Check if any recommended model is installed
    func hasAnyRecommendedModel() -> Bool {
        RecommendedModel.all.contains { isModelInstalled($0.name) }
    }

    /// Check available disk capacity for the volume that stores the user's Ollama models.
    func availableDiskSpaceBytes() throws -> Int64 {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try homeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        if let importantUsage = values.volumeAvailableCapacityForImportantUsage {
            return importantUsage
        }

        if let availableCapacity = values.volumeAvailableCapacity {
            return Int64(availableCapacity)
        }

        throw OllamaModelError.diskSpaceUnavailable
    }

    func ensureSufficientDiskSpace(for model: RecommendedModel) throws {
        let availableBytes = try availableDiskSpaceBytes()
        let requiredBytes = model.sizeBytes + Self.modelDownloadFreeSpaceBufferBytes

        guard availableBytes >= requiredBytes else {
            throw OllamaModelError.insufficientDiskSpace(required: requiredBytes, available: availableBytes)
        }
    }
}

// MARK: - Errors

enum OllamaModelError: Error, LocalizedError {
    case invalidURL
    case pullFailed(String)
    case deleteFailed(String)
    case loadFailed(String)
    case unloadFailed(String)
    case alreadyPulling
    case modelNotFound
    case diskSpaceUnavailable
    case insufficientDiskSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama API URL"
        case .pullFailed(let message):
            return "Failed to pull model: \(message)"
        case .deleteFailed(let message):
            return "Failed to delete model: \(message)"
        case .loadFailed(let message):
            return "Failed to load model: \(message)"
        case .unloadFailed(let message):
            return "Failed to unload model: \(message)"
        case .alreadyPulling:
            return "Already pulling a model"
        case .modelNotFound:
            return "Model not found"
        case .diskSpaceUnavailable:
            return "Could not determine available disk space"
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space. Required: \(Self.formatBytes(required)), available: \(Self.formatBytes(available))"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
