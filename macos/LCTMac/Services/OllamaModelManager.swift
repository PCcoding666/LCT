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

/// Pure NDJSON parsing for `/api/pull` streams. Ollama reports progress per
/// layer (digest) and each layer restarts `completed` at zero, so a naive
/// read makes the progress bar jump backwards; here per-layer totals are
/// accumulated and a high-water mark keeps the overall fraction monotonic.
struct PullStreamAccumulator {
    struct Snapshot: Equatable, Sendable {
        var overallProgress: Double
        var completedBytes: Int64
        var totalBytes: Int64
        var status: String
        var isComplete: Bool
    }

    private struct Layer: Equatable {
        var total: Int64
        var completed: Int64
    }

    private struct Line: Decodable {
        let status: String?
        let digest: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    private var layers: [String: Layer] = [:]
    private var status: String = ""
    private var peakProgress: Double = 0
    private var sawSuccess = false

    /// Feed one NDJSON line. Returns a state snapshot, or nil for blank and
    /// unparseable lines. Throws when the stream carries an `error` object.
    mutating func ingest(line rawLine: String) throws -> Snapshot? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Line.self, from: data) else {
            return nil
        }

        if let error = parsed.error, !error.isEmpty {
            throw OllamaModelError.pullFailed(error)
        }

        if let status = parsed.status {
            self.status = status
        }

        if let digest = parsed.digest {
            var layer = layers[digest] ?? Layer(total: 0, completed: 0)
            if let total = parsed.total {
                layer.total = max(layer.total, total)
            }
            if let completed = parsed.completed {
                layer.completed = max(layer.completed, completed)
            }
            layers[digest] = layer
        }

        if parsed.status == "success" {
            sawSuccess = true
            peakProgress = 1.0
        }

        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        for layer in layers.values {
            completedBytes += layer.completed
            totalBytes += layer.total
        }
        if totalBytes > 0 {
            peakProgress = max(peakProgress, min(Double(completedBytes) / Double(totalBytes), 1.0))
        }

        return Snapshot(
            overallProgress: peakProgress,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            status: status,
            isComplete: sawSuccess
        )
    }

    /// Validate the stream once it ends. A pull that never reported
    /// `{"status": "success"}` did not finish, whatever the HTTP status said.
    func finish() throws {
        guard sawSuccess else {
            throw OllamaModelError.pullFailed("Download ended before completing")
        }
    }
}

/// Service for managing Ollama models
@MainActor
class OllamaModelManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var installedModels: [OllamaModel] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isPulling: Bool = false
    @Published private(set) var pullProgress: Double = 0
    @Published private(set) var pullCompletedBytes: Int64 = 0
    @Published private(set) var pullTotalBytes: Int64 = 0
    @Published private(set) var pullStatus: String = ""
    @Published private(set) var currentPullingModel: String?
    @Published private(set) var lastError: String?

    // MARK: - Configuration

    var endpoint: OllamaEndpoint
    private let session: URLSession
    private var pullTask: Task<Void, Error>?
    private static let modelDownloadFreeSpaceBufferBytes: Int64 = 2_000_000_000

    // MARK: - Initialization

    init(endpoint: OllamaEndpoint = .local, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    private func apiURL(_ path: String) -> URL {
        endpoint.baseURL.appendingPathComponent(path)
    }

    // MARK: - Model Listing

    /// Fetch list of installed models
    func fetchInstalledModels() async {
        isLoading = true
        defer { isLoading = false }

        let url = apiURL("api/tags")

        do {
            let (data, response) = try await session.data(from: url)

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

    /// Pull (download) a model. Streams progress into the published pull
    /// properties; throws `CancellationError` after `cancelPull()`, a
    /// `pullFailed` error when the stream reports one or ends early.
    func pullModel(_ modelName: String) async throws {
        guard !isPulling else {
            throw OllamaModelError.alreadyPulling
        }

        // The disk-space check only applies to catalog models whose download
        // size is known; a hand-typed model name skips it.
        if let entry = ModelCatalog.entry(named: modelName) {
            try ensureSufficientDiskSpace(for: entry)
        }

        isPulling = true
        pullProgress = 0
        pullCompletedBytes = 0
        pullTotalBytes = 0
        pullStatus = "Starting download..."
        currentPullingModel = modelName
        lastError = nil

        // The download runs in a task the manager owns so cancelPull() can
        // actually stop it — the caller's task alone is not enough.
        let task = Task { try await performPull(modelName) }
        pullTask = task

        defer {
            pullTask = nil
            isPulling = false
            currentPullingModel = nil
        }

        do {
            try await task.value
            pullProgress = 1.0
            pullStatus = "Download complete!"

            // Refresh model list
            await fetchInstalledModels()
        } catch is CancellationError {
            pullStatus = "Cancelled"
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            pullStatus = "Cancelled"
            throw CancellationError()
        } catch {
            pullStatus = "Download failed"
            lastError = error.localizedDescription
            throw error
        }
    }

    private func performPull(_ modelName: String) async throws {
        let url = apiURL("api/pull")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["name": modelName]
        request.httpBody = try JSONEncoder().encode(body)

        // Use streaming to get progress updates
        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.pullFailed("Server returned error")
        }

        var accumulator = PullStreamAccumulator()
        for try await line in asyncBytes.lines {
            try Task.checkCancellation()

            if let snapshot = try accumulator.ingest(line: line) {
                pullProgress = snapshot.overallProgress
                pullCompletedBytes = snapshot.completedBytes
                pullTotalBytes = snapshot.totalBytes
                pullStatus = snapshot.status

                if snapshot.isComplete {
                    break
                }
            }
        }
        try accumulator.finish()
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
        let url = apiURL("api/delete")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["name": modelName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OllamaModelError.deleteFailed("Server returned error")
        }

        // Refresh model list
        await fetchInstalledModels()
    }

    // MARK: - Model Loading

    /// Preload a model into memory. Forwards to OllamaService, the single
    /// implementation of the load/unload requests; `keep_alive` comes from
    /// the user's saved settings.
    func loadModel(_ modelName: String) async throws {
        try await makeLifecycleService().loadModel(modelName)
    }

    /// Unload a model from memory. Forwards to OllamaService, the single
    /// implementation of the load/unload requests.
    func unloadModel(_ modelName: String) async throws {
        try await makeLifecycleService().unloadModel(modelName)
    }

    /// An OllamaService pointed at this manager's endpoint, using the saved
    /// settings for everything else (keep_alive, timeouts).
    private func makeLifecycleService() -> OllamaService {
        var settings = AppSettings.load()
        settings.ollamaHost = endpoint.host
        settings.ollamaPort = endpoint.port
        settings.remoteOllamaOptIn = !endpoint.isLoopback
        return OllamaService(settings: settings, session: .shared)
    }

    // MARK: - Disk Space

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

    func ensureSufficientDiskSpace(for model: TranslationModelInfo) throws {
        let availableBytes = try availableDiskSpaceBytes()
        let requiredBytes = model.downloadBytes + Self.modelDownloadFreeSpaceBufferBytes

        guard availableBytes >= requiredBytes else {
            throw OllamaModelError.insufficientDiskSpace(required: requiredBytes, available: availableBytes)
        }
    }
}

// MARK: - Errors

enum OllamaModelError: Error, LocalizedError {
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
