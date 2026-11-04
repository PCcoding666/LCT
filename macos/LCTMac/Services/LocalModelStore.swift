import CryptoKit
import Foundation

struct LocalTranslationModel: Sendable {
    let id: String
    let filename: String
    let downloadURL: URL
    let byteCount: Int64
    let sha256: String

    static let qwen = LocalTranslationModel(
        id: "qwen2.5-1.5b-instruct-q4_k_m",
        filename: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/dd26da440ef0330c47919d1ecae0966d24022222/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        byteCount: 1_117_320_736,
        sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
    )
}

enum LocalModelError: LocalizedError {
    case missing, invalidSize, invalidChecksum, invalidFormat, http(Int), busy, insufficientDisk
    var errorDescription: String? {
        switch self {
        case .missing: return "Download the translation model first. Captions remain available."
        case .invalidSize: return "The model download is incomplete. Please retry."
        case .invalidChecksum: return "The model failed its integrity check. Please download it again."
        case .invalidFormat: return "The selected file is not a supported GGUF model."
        case .http(let code): return "Model download failed (HTTP \(code)). Please retry."
        case .busy: return "A model operation is already in progress."
        case .insufficientDisk: return "There is not enough free disk space for the translation model."
        }
    }
}

struct ModelDownloadArtifact: Sendable {
    let url: URL
    let statusCode: Int
}

struct ModelDownloadFailure: Error, Sendable {
    let message: String
    let resumeData: Data?
    let cancelled: Bool
}

protocol ModelDownloadTransport: Sendable {
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> ModelDownloadArtifact
}

/// Files are never handed to the runtime until size, GGUF magic, and SHA-256 pass.
/// Actor isolation keeps installation and verification away from the UI executor.
actor LocalModelStore {
    nonisolated let directory: URL
    nonisolated let model: LocalTranslationModel
    private let transport: any ModelDownloadTransport
    private var downloading = false

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LCT/Models", isDirectory: true)
    }

    init(directory: URL = LocalModelStore.defaultDirectory, model: LocalTranslationModel = .qwen,
         transport: any ModelDownloadTransport = URLSessionModelTransport()) {
        self.directory = directory
        self.model = model
        self.transport = transport
    }

    nonisolated var modelURL: URL { directory.appendingPathComponent(model.filename) }
    nonisolated var modelFileExists: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }
    private var resumeURL: URL { directory.appendingPathComponent("resume.data") }

    func verifiedModelURL() throws -> URL {
        try Self.verify(modelURL, model: model)
        return modelURL
    }

    func download(progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                  verifying: @escaping @Sendable () -> Void = {}) async throws {
        guard !downloading else { throw LocalModelError.busy }
        downloading = true
        defer { downloading = false }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, capacity < model.byteCount + 64 * 1_024 * 1_024 {
            throw LocalModelError.insufficientDisk
        }
        var resumeData = try? Data(contentsOf: resumeURL)
        var artifact: ModelDownloadArtifact
        do {
            do {
                artifact = try await transport.download(from: model.downloadURL, resumeData: resumeData, progress: progress)
            } catch {
                let cancelled = Task.isCancelled || (error as? ModelDownloadFailure)?.cancelled == true
                    || (error as? URLError)?.code == .cancelled || error is CancellationError
                guard resumeData != nil, !cancelled else { throw error }
                // A removed temporary file or changed remote resource invalidates resume data.
                try? FileManager.default.removeItem(at: resumeURL)
                resumeData = nil
                try Task.checkCancellation()
                artifact = try await transport.download(from: model.downloadURL, resumeData: nil, progress: progress)
            }
        } catch let error as ModelDownloadFailure {
            if let data = error.resumeData { try? data.write(to: resumeURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: resumeURL) }
            if error.cancelled || Task.isCancelled { throw CancellationError() }
            throw NSError(domain: "LCT.ModelDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        defer { try? FileManager.default.removeItem(at: artifact.url) }
        try Task.checkCancellation()
        guard artifact.statusCode == 200 || (artifact.statusCode == 206 && resumeData != nil) else {
            try? FileManager.default.removeItem(at: resumeURL)
            throw LocalModelError.http(artifact.statusCode)
        }
        verifying()
        do { try Self.verify(artifact.url, model: model) }
        catch { try? FileManager.default.removeItem(at: resumeURL); throw error }
        try Task.checkCancellation()
        // Move into the destination volume before atomic replacement; a failed download
        // never removes an already valid installed model.
        let staging = directory.appendingPathComponent(".verified-\(UUID().uuidString).gguf")
        try FileManager.default.moveItem(at: artifact.url, to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        if modelFileExists {
            _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: modelURL)
        }
        try? FileManager.default.removeItem(at: resumeURL)
    }

    private static func verify(_ url: URL, model: LocalTranslationModel) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalModelError.missing }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == model.byteCount else { throw LocalModelError.invalidSize }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else { throw LocalModelError.invalidFormat }
        try file.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let bytes = try file.read(upToCount: 1_048_576) ?? Data()
            if bytes.isEmpty { break }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == model.sha256 else { throw LocalModelError.invalidChecksum }
    }
}

struct URLSessionModelTransport: ModelDownloadTransport {
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> ModelDownloadArtifact {
        let operation = ModelDownloadOperation(progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.start(url: url, resumeData: resumeData)
        } onCancel: { operation.cancel() }
    }
}

/// URLSession invokes delegates on a serial queue; the lock also protects the
/// cancellation callback and the Swift task's cancellation handler.
private final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ModelDownloadArtifact, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var finished = false
    private let progress: @Sendable (Int64, Int64) -> Void

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func start(url: URL, resumeData: Data?) async throws -> ModelDownloadArtifact {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task: URLSessionDownloadTask
            if let resumeData { task = session.downloadTask(withResumeData: resumeData) }
            else { task = session.downloadTask(with: url) }
            self.task = task
            task.resume()
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard !finished, !cancelled else { lock.unlock(); return }
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel { [self] data in
            finish(.failure(ModelDownloadFailure(message: "Download cancelled", resumeData: data, cancelled: true)))
        }
    }

    private func finish(_ result: Result<ModelDownloadArtifact, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            if case .success(let artifact) = result { try? FileManager.default.removeItem(at: artifact.url) }
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        guard !cancelled else { return }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LCT-model-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(ModelDownloadArtifact(url: destination,
                statusCode: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let cancelled = self.cancelled; lock.unlock()
        if cancelled { return } // cancel(byProducingResumeData:) owns completion in this case.
        let nsError = error as NSError
        finish(.failure(ModelDownloadFailure(message: error.localizedDescription,
            resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
            cancelled: nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue)))
    }
}
