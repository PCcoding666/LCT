import Foundation

/// Translation task priority
enum TranslationPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2

    static func < (lhs: TranslationPriority, rhs: TranslationPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Translation task
struct TranslationTask: Identifiable {
    let id: UUID = UUID()
    let segmentId: UUID
    let text: String
    let context: [TranslationEntry]
    let priority: TranslationPriority
    let timestamp: Date = Date()
    let isFinal: Bool  // Whether this is a final (non-volatile) transcription

    init(segmentId: UUID, text: String, context: [TranslationEntry] = [], priority: TranslationPriority = .normal, isFinal: Bool = true) {
        self.segmentId = segmentId
        self.text = text
        self.context = context
        self.priority = priority
        self.isFinal = isFinal
    }
}

/// Translation result
struct TranslationQueueResult {
    let taskId: UUID
    let segmentId: UUID
    let originalText: String
    let translatedText: String
    let latencyMs: Int
    let success: Bool
    let error: Error?

    init(taskId: UUID = UUID(), segmentId: UUID, originalText: String, translatedText: String, latencyMs: Int, success: Bool, error: Error? = nil) {
        self.taskId = taskId
        self.segmentId = segmentId
        self.originalText = originalText
        self.translatedText = translatedText
        self.latencyMs = latencyMs
        self.success = success
        self.error = error
    }
}

/// Translation queue service with debouncing, streaming, and task management
@MainActor
class TranslationQueue: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var pendingCount: Int = 0
    @Published private(set) var droppedCount: Int = 0
    @Published private(set) var lastResult: TranslationQueueResult?
    @Published private(set) var streamingText: String = ""  // Current streaming output

    // MARK: - Callbacks
    var onTranslationComplete: ((TranslationQueueResult) -> Void)?
    var onStreamingUpdate: ((UUID, String) -> Void)?  // Called on each token during streaming

    // MARK: - Configuration
    private let debounceInterval: TimeInterval
    private let maxRetries: Int
    private let maxPendingTasks: Int
    private let maxTaskAge: TimeInterval
    private let shortTextMergeCharacterLimit: Int
    private let shortTextMergeWindow: TimeInterval
    private let ollamaService: OllamaService
    var useStreaming: Bool = true  // Enable streaming by default

    // MARK: - Private Properties
    private var pendingTasks: [TranslationTask] = []
    private var currentTask: TranslationTask?
    private var processingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastProcessedText: String = ""

    /// Generation counter to prevent stale streaming tokens from polluting the UI.
    /// Incremented on each new task. Captured by the onToken closure so that
    /// tokens arriving after a cancellation/new-task are silently discarded.
    private var generation: UInt64 = 0

    // MARK: - Initialization

    init(
        ollamaService: OllamaService,
        debounceInterval: TimeInterval = 0.3,
        maxRetries: Int = 2,
        maxPendingTasks: Int = 20,
        maxTaskAge: TimeInterval = 12,
        shortTextMergeCharacterLimit: Int = 24,
        shortTextMergeWindow: TimeInterval = 0.8
    ) {
        self.ollamaService = ollamaService
        self.debounceInterval = debounceInterval
        self.maxRetries = maxRetries
        self.maxPendingTasks = max(1, maxPendingTasks)
        self.maxTaskAge = maxTaskAge
        self.shortTextMergeCharacterLimit = shortTextMergeCharacterLimit
        self.shortTextMergeWindow = shortTextMergeWindow
    }

    // MARK: - Public Methods

    /// Enqueue a translation task
    /// If the text is volatile (partial result), it will be debounced
    /// If the text is final, it will be processed immediately
    func enqueue(segmentId: UUID, text: String, context: [TranslationEntry] = [], priority: TranslationPriority = .normal, isFinal: Bool = true) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Skip if same as last processed text
        if trimmedText == lastProcessedText && isFinal {
            return
        }

        let task = TranslationTask(segmentId: segmentId, text: trimmedText, context: context, priority: priority, isFinal: isFinal)

        if isFinal {
            // Final results are processed immediately with high priority
            cancelPendingDebounce()

            // Preempt in-progress volatile translation: if we're currently processing
            // a non-final (volatile) task, cancel it immediately so the final text
            // gets translated with minimal delay instead of waiting.
            if let current = currentTask, !current.isFinal, isProcessing {
                processingTask?.cancel()
                processingTask = nil
                currentTask = nil
                isProcessing = false
                streamingText = ""
            }

            enqueueTask(task)
        } else {
            // Volatile results are debounced
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.enqueueTask(task)
            }
        }
    }

    /// Cancel all pending tasks
    func cancelAll() {
        debounceTask?.cancel()
        processingTask?.cancel()
        pendingTasks.removeAll()
        currentTask = nil
        pendingCount = 0
        isProcessing = false
        streamingText = ""
        // Reset the dedup baseline: canceled work may be re-enqueued with the
        // same text later (e.g. resume after pause) and must not be skipped
        lastProcessedText = ""
        // Bump generation so any in-flight token dispatches are discarded
        generation &+= 1
    }

    /// Cancel queued or in-flight work for specific UI segments.
    func cancel(segmentIds: Set<UUID>) {
        guard !segmentIds.isEmpty else { return }

        pendingTasks.removeAll { segmentIds.contains($0.segmentId) }
        pendingCount = pendingTasks.count

        if let currentTask, segmentIds.contains(currentTask.segmentId) {
            processingTask?.cancel()
            processingTask = nil
            self.currentTask = nil
            isProcessing = false
            streamingText = ""
            generation &+= 1
        }

        processNextIfNeeded()
    }

    /// Cancel pending debounce (for immediate processing)
    func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Private Methods

    private func enqueueTask(_ task: TranslationTask) {
        pruneStalePendingTasks()
        let taskToQueue = coalesceShortPendingTask(task)

        // Remove any pending task with the same text (deduplication)
        pendingTasks.removeAll { $0.text == taskToQueue.text }

        // Add new task
        pendingTasks.append(taskToQueue)

        // Sort by priority (higher priority first) and timestamp (older first for same priority)
        pendingTasks.sort {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.timestamp < $1.timestamp
        }
        enforcePendingLimit()

        pendingCount = pendingTasks.count

        // Start processing if not already running
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        pruneStalePendingTasks()
        pendingCount = pendingTasks.count

        guard !isProcessing, !pendingTasks.isEmpty else { return }

        guard let task = pendingTasks.first else { return }
        pendingTasks.removeFirst()
        pendingCount = pendingTasks.count

        currentTask = task
        isProcessing = true
        streamingText = ""

        // Bump generation for this new task
        generation &+= 1
        let taskGeneration = generation

        processingTask = Task {
            if useStreaming {
                await processTaskStreaming(task, generation: taskGeneration)
            } else {
                await processTask(task, generation: taskGeneration)
            }
        }
    }

    private func pruneStalePendingTasks() {
        guard maxTaskAge > 0 else { return }

        let now = Date()
        let beforeCount = pendingTasks.count
        pendingTasks.removeAll { now.timeIntervalSince($0.timestamp) > maxTaskAge }
        let removedCount = beforeCount - pendingTasks.count
        if removedCount > 0 {
            droppedCount += removedCount
        }
    }

    private func enforcePendingLimit() {
        while pendingTasks.count > maxPendingTasks {
            guard let dropIndex = pendingTasks.indices.min(by: { lhs, rhs in
                let lhsTask = pendingTasks[lhs]
                let rhsTask = pendingTasks[rhs]

                if lhsTask.priority != rhsTask.priority {
                    return lhsTask.priority < rhsTask.priority
                }

                return lhsTask.timestamp < rhsTask.timestamp
            }) else {
                return
            }

            pendingTasks.remove(at: dropIndex)
            droppedCount += 1
        }
    }

    private func coalesceShortPendingTask(_ task: TranslationTask) -> TranslationTask {
        guard !task.isFinal,
              shortTextMergeCharacterLimit > 0,
              task.text.count <= shortTextMergeCharacterLimit,
              let existingIndex = pendingTasks.lastIndex(where: {
                  !$0.isFinal
                      && $0.segmentId == task.segmentId
                      && $0.priority == task.priority
                      && $0.text.count <= shortTextMergeCharacterLimit
                      && Date().timeIntervalSince($0.timestamp) <= shortTextMergeWindow
              }) else {
            return task
        }

        let existingTask = pendingTasks.remove(at: existingIndex)
        let mergedText: String
        if task.text.hasPrefix(existingTask.text) {
            mergedText = task.text
        } else {
            mergedText = TextUtils.concatenateSentences([existingTask.text, task.text])
        }

        return TranslationTask(
            segmentId: task.segmentId,
            text: mergedText,
            context: task.context.isEmpty ? existingTask.context : task.context,
            priority: task.priority,
            isFinal: false
        )
    }

    /// Process task with streaming for better UX
    private func processTaskStreaming(_ task: TranslationTask, generation taskGeneration: UInt64, retryCount: Int = 0) async {
        let startTime = Date()
        streamingText = ""

        do {
            let latencyMs = try await ollamaService.translateStreaming(
                text: task.text,
                context: task.context
            ) { [weak self] token in
                guard let self = self else { return }
                Task { @MainActor in
                    // Check generation: if a newer task has started, discard this stale token
                    guard self.generation == taskGeneration else { return }
                    self.streamingText += token
                    self.onStreamingUpdate?(task.segmentId, self.streamingText)
                }
            }

            guard !Task.isCancelled else { return }
            // Double-check generation hasn't changed during processing
            guard generation == taskGeneration else { return }

            // Only final translations update the dedup baseline. Volatile draft
            // text is transient and must not suppress the final segment that
            // happens to share the same text.
            if task.isFinal {
                lastProcessedText = task.text
            }

            let result = TranslationQueueResult(
                taskId: task.id,
                segmentId: task.segmentId,
                originalText: task.text,
                translatedText: streamingText,
                latencyMs: latencyMs,
                success: true,
                error: nil
            )

            lastResult = result
            onTranslationComplete?(result)

        } catch {
            guard !Task.isCancelled else { return }
            guard generation == taskGeneration else { return }

            // Retry if possible
            if retryCount < maxRetries {
                let delay = pow(2.0, Double(retryCount)) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                guard !Task.isCancelled else { return }
                guard generation == taskGeneration else { return }
                await processTaskStreaming(task, generation: taskGeneration, retryCount: retryCount + 1)
                return
            }

            // Report failure
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let result = TranslationQueueResult(
                taskId: task.id,
                segmentId: task.segmentId,
                originalText: task.text,
                translatedText: "[ERROR] \(error.localizedDescription)",
                latencyMs: latencyMs,
                success: false,
                error: error
            )

            lastResult = result
            onTranslationComplete?(result)
        }

        // Mark as done and process next
        isProcessing = false
        currentTask = nil
        processNextIfNeeded()
    }

    /// Process task without streaming (fallback)
    private func processTask(_ task: TranslationTask, generation taskGeneration: UInt64, retryCount: Int = 0) async {
        let startTime = Date()

        do {
            let (translatedText, latencyMs) = try await ollamaService.translate(
                text: task.text,
                context: task.context
            )

            guard !Task.isCancelled else { return }
            guard generation == taskGeneration else { return }

            if task.isFinal {
                lastProcessedText = task.text
            }

            let result = TranslationQueueResult(
                taskId: task.id,
                segmentId: task.segmentId,
                originalText: task.text,
                translatedText: translatedText,
                latencyMs: latencyMs,
                success: true,
                error: nil
            )

            lastResult = result
            onTranslationComplete?(result)

        } catch {
            guard !Task.isCancelled else { return }
            guard generation == taskGeneration else { return }

            // Retry if possible
            if retryCount < maxRetries {
                // Exponential backoff
                let delay = pow(2.0, Double(retryCount)) * 0.5
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                guard !Task.isCancelled else { return }
                guard generation == taskGeneration else { return }
                await processTask(task, generation: taskGeneration, retryCount: retryCount + 1)
                return
            }

            // Report failure
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let result = TranslationQueueResult(
                taskId: task.id,
                segmentId: task.segmentId,
                originalText: task.text,
                translatedText: "[ERROR] \(error.localizedDescription)",
                latencyMs: latencyMs,
                success: false,
                error: error
            )

            lastResult = result
            onTranslationComplete?(result)
        }

        // Mark as done and process next
        isProcessing = false
        currentTask = nil
        processNextIfNeeded()
    }
}
