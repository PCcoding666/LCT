import Combine
import Foundation

enum EmbeddedTranslationState: Equatable {
    case notDownloaded, downloading, verifying, downloaded, loading, ready, failed(String)
}

@MainActor
final class EmbeddedTranslationService: ObservableObject, TranslationEngine {
    static let shared = EmbeddedTranslationService()
    static let modelName = "Qwen2.5 1.5B"
    static let modelSizeBytes = LocalTranslationModel.qwen.byteCount
    @Published private(set) var state: EmbeddedTranslationState
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadedBytes: Int64 = 0

    private let store: LocalModelStore
    private let runtime: LlamaTranslationRuntime
    private var settings = AppSettings()
    private var downloadTask: Task<Void, Error>?
    private var loadTask: Task<Void, Error>?
    private var operationID: UUID?
    private var translating = false
    var isReady: Bool { state == .ready }
    var isModelDownloaded: Bool { store.modelFileExists }

    init(store: LocalModelStore = LocalModelStore(), runtime: LlamaTranslationRuntime = LlamaTranslationRuntime()) {
        self.store = store
        self.runtime = runtime
        // Deliberately no tasks, network probes, model loading, or auto-download.
        state = store.modelFileExists ? .downloaded : .notDownloaded
    }

    func updateSettings(_ settings: AppSettings) { self.settings = settings }

    func downloadModel() async throws {
        guard downloadTask == nil, loadTask == nil, !translating, !isReady else { throw LocalModelError.busy }
        let id = UUID()
        operationID = id
        state = .downloading
        downloadedBytes = 0
        downloadProgress = 0
        let store = self.store
        let task = Task { [weak self] in
            try await store.download(progress: { [weak self] bytes, total in
                Task { @MainActor in
                    guard let self, self.operationID == id, self.state == .downloading else { return }
                    self.downloadedBytes = bytes
                    self.downloadProgress = min(1, max(0, Double(bytes) / Double(total > 0 ? total : Self.modelSizeBytes)))
                }
            }, verifying: { [weak self] in
                Task { @MainActor in
                    guard let self, self.operationID == id else { return }
                    self.state = .verifying
                }
            })
        }
        downloadTask = task
        defer { downloadTask = nil; operationID = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            state = .downloaded
            downloadedBytes = Self.modelSizeBytes
            downloadProgress = 1
        } catch is CancellationError {
            state = store.modelFileExists ? .downloaded : .notDownloaded
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    /// Normal termination waits for URLSession to produce resume data and the
    /// store to persist it. The caller may still enforce a separate quit timeout.
    func cancelDownloadAndWait() async {
        guard let task = downloadTask else { return }
        task.cancel()
        _ = try? await task.value
    }

    func loadModel() async throws {
        if isReady { return }
        if let loadTask { try await loadTask.value; return }
        guard downloadTask == nil else { throw LocalModelError.busy }
        state = .loading
        let store = self.store
        let runtime = self.runtime
        let task = Task {
            let url = try await store.verifiedModelURL()
            try Task.checkCancellation()
            try await runtime.load(at: url)
        }
        loadTask = task
        defer { loadTask = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            state = .ready
        } catch is CancellationError {
            state = store.modelFileExists ? .downloaded : .notDownloaded
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func unloadModel() async {
        state = store.modelFileExists ? .downloaded : .notDownloaded
        loadTask?.cancel()
        if let loadTask { _ = try? await loadTask.value }
        await runtime.unload()
        state = store.modelFileExists ? .downloaded : .notDownloaded
    }

    func translate(text: String, context: [TranslationEntry] = []) async throws -> (String, Int) {
        var result = ""
        let latency = try await translateStreaming(text: text, context: context) { result += $0 }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), latency)
    }

    func translateStreaming(text: String, context: [TranslationEntry] = [], onToken: @escaping @MainActor (String) -> Void) async throws -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        guard isReady else { throw LocalRuntimeError.notLoaded }
        guard !translating else { throw LocalModelError.busy }
        translating = true
        defer { translating = false }
        let start = ContinuousClock.now
        var messages = [LocalTranslationMessage(role: "system", content: settings.translationPrompt)]
        if settings.contextAware {
            // Bound history so a long session cannot grow the model context indefinitely.
            for entry in context.suffix(max(0, settings.maxContextEntries)) {
                messages.append(.init(role: "user", content: entry.sourceText))
                messages.append(.init(role: "assistant", content: entry.translatedText))
            }
        }
        messages.append(.init(role: "user", content: "🔤 \(text) 🔤"))
        for try await chunk in runtime.stream(messages: messages, temperature: Float(settings.ollamaTemperature)) {
            try Task.checkCancellation()
            onToken(chunk)
        }
        try Task.checkCancellation()
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }
}
