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
    let text: String
    let context: [TranslationEntry]
    let priority: TranslationPriority
    let timestamp: Date = Date()
    let isFinal: Bool  // Whether this is a final (non-volatile) transcription
    
    init(text: String, context: [TranslationEntry] = [], priority: TranslationPriority = .normal, isFinal: Bool = true) {
        self.text = text
        self.context = context
        self.priority = priority
        self.isFinal = isFinal
    }
}

/// Translation result
struct TranslationQueueResult {
    let taskId: UUID
    let originalText: String
    let translatedText: String
    let latencyMs: Int
    let success: Bool
    let error: Error?
    
    init(taskId: UUID = UUID(), originalText: String, translatedText: String, latencyMs: Int, success: Bool, error: Error? = nil) {
        self.taskId = taskId
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
    @Published private(set) var lastResult: TranslationQueueResult?
    @Published private(set) var streamingText: String = ""  // Current streaming output
    
    // MARK: - Callbacks
    var onTranslationComplete: ((TranslationQueueResult) -> Void)?
    var onStreamingUpdate: ((String) -> Void)?  // Called on each token during streaming
    
    // MARK: - Configuration
    private let debounceInterval: TimeInterval
    private let maxRetries: Int
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
    
    init(ollamaService: OllamaService, debounceInterval: TimeInterval = 0.3, maxRetries: Int = 2) {
        self.ollamaService = ollamaService
        self.debounceInterval = debounceInterval
        self.maxRetries = maxRetries
    }
    
    // MARK: - Public Methods
    
    /// Enqueue a translation task
    /// If the text is volatile (partial result), it will be debounced
    /// If the text is final, it will be processed immediately
    func enqueue(text: String, context: [TranslationEntry] = [], priority: TranslationPriority = .normal, isFinal: Bool = true) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // Skip if same as last processed text
        if trimmedText == lastProcessedText && isFinal {
            return
        }
        
        let task = TranslationTask(text: trimmedText, context: context, priority: priority, isFinal: isFinal)
        
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
        // Bump generation so any in-flight token dispatches are discarded
        generation &+= 1
    }
    
    /// Cancel pending debounce (for immediate processing)
    func cancelPendingDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }
    
    // MARK: - Private Methods
    
    private func enqueueTask(_ task: TranslationTask) {
        // Remove any pending task with the same text (deduplication)
        pendingTasks.removeAll { $0.text == task.text }
        
        // Add new task
        pendingTasks.append(task)
        
        // Sort by priority (higher priority first) and timestamp (older first for same priority)
        pendingTasks.sort { 
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.timestamp < $1.timestamp
        }
        
        pendingCount = pendingTasks.count
        
        // Start processing if not already running
        processNextIfNeeded()
    }
    
    private func processNextIfNeeded() {
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
                    self.onStreamingUpdate?(self.streamingText)
                }
            }
            
            guard !Task.isCancelled else { return }
            // Double-check generation hasn't changed during processing
            guard generation == taskGeneration else { return }
            
            lastProcessedText = task.text
            
            let result = TranslationQueueResult(
                taskId: task.id,
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
            
            lastProcessedText = task.text
            
            let result = TranslationQueueResult(
                taskId: task.id,
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
