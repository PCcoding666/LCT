import Foundation
import llama

struct LocalTranslationMessage: Sendable {
    let role: String
    let content: String
}

enum LocalRuntimeError: LocalizedError {
    case notLoaded, loadFailed, contextFailed, invalidUTF8, promptTooLong, inferenceFailed(Int32), invalidTemplate
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The translation model is not loaded. Captions remain available."
        case .loadFailed: return "The local translation model could not be loaded."
        case .contextFailed: return "Not enough memory to prepare local translation."
        case .invalidUTF8: return "The translation engine returned invalid text."
        case .promptTooLong: return "This caption is too long to translate in the available context."
        case .inferenceFailed(let code): return "Local translation failed (\(code))."
        case .invalidTemplate: return "The model's conversation template is unsupported."
        }
    }
}

/// Token pieces can end inside a Unicode scalar. Never replace an unfinished
/// scalar with U+FFFD or hand an invalid fragment to SwiftUI.
struct UTF8TokenDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) throws -> String {
        pending.append(contentsOf: bytes)
        var offset = 0
        while offset < pending.count {
            let first = pending[offset]
            let width: Int
            switch first {
            case 0...0x7f: width = 1
            case 0xc2...0xdf: width = 2
            case 0xe0...0xef: width = 3
            case 0xf0...0xf4: width = 4
            default: throw LocalRuntimeError.invalidUTF8
            }
            guard offset + width <= pending.count else { break }
            let scalar = Array(pending[offset..<(offset + width)])
            guard String(bytes: scalar, encoding: .utf8) != nil else { throw LocalRuntimeError.invalidUTF8 }
            offset += width
        }
        let text = String(decoding: pending.prefix(offset), as: UTF8.self)
        pending.removeFirst(offset)
        return text
    }

    mutating func finish() throws -> String {
        guard pending.isEmpty else { throw LocalRuntimeError.invalidUTF8 }
        return ""
    }
}

private enum LlamaBackend {
    static let initialized: Void = { llama_backend_init() }()
}

/// Owned only by the runtime actor. This wrapper also releases C allocations
/// when a test or a window-scoped service is deallocated without explicit unload.
private final class LlamaResources: @unchecked Sendable {
    let model: OpaquePointer
    let context: OpaquePointer
    init(model: OpaquePointer, context: OpaquePointer) {
        self.model = model
        self.context = context
    }
    deinit {
        llama_free(context)
        llama_model_free(model)
    }
}

/// All C pointers remain on this actor. Load/generate/free contain no suspension
/// points, so unload cannot interleave with a kernel that still uses the context.
actor LlamaTranslationRuntime {
    private var resources: LlamaResources?
    private let contextSize: UInt32 = 2_048
    private let outputLimit = 256

    func load(at url: URL) throws {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalModelError.missing }
        if resources != nil { return }
        _ = LlamaBackend.initialized
        var modelParameters = llama_model_default_params()
        #if arch(arm64)
        modelParameters.n_gpu_layers = -1
        #else
        modelParameters.n_gpu_layers = 0
        #endif
        modelParameters.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParameters.progress_callback = { _, _ in !Task<Never, Never>.isCancelled }
        guard let loadedModel = llama_model_load_from_file(url.path, modelParameters) else {
            try Task.checkCancellation()
            throw LocalRuntimeError.loadFailed
        }
        do { try Task.checkCancellation() }
        catch { llama_model_free(loadedModel); throw error }
        var parameters = llama_context_default_params()
        parameters.n_ctx = contextSize
        parameters.n_batch = 256
        parameters.n_ubatch = 64
        parameters.n_threads = Int32(max(1, min(ProcessInfo.processInfo.activeProcessorCount - 2, 6)))
        parameters.n_threads_batch = parameters.n_threads
        guard let loadedContext = llama_init_from_model(loadedModel, parameters) else {
            llama_model_free(loadedModel)
            throw LocalRuntimeError.contextFailed
        }
        resources = LlamaResources(model: loadedModel, context: loadedContext)
        if Task.isCancelled { unload(); throw CancellationError() }
    }

    func unload() {
        resources = nil
    }

    nonisolated func stream(messages: [LocalTranslationMessage], temperature: Float = 0) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    try await self.generate(messages: messages, temperature: temperature) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func generate(messages: [LocalTranslationMessage], temperature: Float, yield: @Sendable (String) -> Void) throws {
        try Task.checkCancellation()
        guard let resources else { throw LocalRuntimeError.notLoaded }
        let model = resources.model
        let context = resources.context
        guard let vocab = llama_model_get_vocab(model) else { throw LocalRuntimeError.loadFailed }
        var boundedMessages = messages
        var tokens: [llama_token] = []
        while true {
            let prompt = try formattedPrompt(messages: boundedMessages, model: model)
            tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
            let count = llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), true, true)
            guard count > 0 else { throw LocalRuntimeError.promptTooLong }
            tokens.removeSubrange(Int(count)..<tokens.count)
            if tokens.count + outputLimit <= Int(contextSize) { break }
            guard boundedMessages.count > 2 else { throw LocalRuntimeError.promptTooLong }
            boundedMessages.removeSubrange(1..<min(3, boundedMessages.count - 1))
        }
        llama_memory_clear(llama_get_memory(context), true)
        defer { llama_memory_clear(llama_get_memory(context), true) }
        // Small prefill batches bound Metal cancellation latency; CPU abort callbacks
        // cannot stop an in-flight Metal kernel.
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            var part = Array(tokens[offset..<min(offset + 64, tokens.count)])
            let code = part.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard code == 0 else { throw LocalRuntimeError.inferenceFailed(code) }
            offset += part.count
        }
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw LocalRuntimeError.contextFailed }
        defer { llama_sampler_free(sampler) }
        if temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(min(2, temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))
        }
        var decoder = UTF8TokenDecoder()
        for _ in 0..<outputLimit {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            var piece = [CChar](repeating: 0, count: 256)
            var size = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if size < 0 {
                piece = [CChar](repeating: 0, count: Int(-size))
                size = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            guard size >= 0 else { throw LocalRuntimeError.invalidUTF8 }
            let text = try decoder.append(piece.prefix(Int(size)).map { UInt8(bitPattern: $0) })
            if !text.isEmpty { yield(text) }
            let code = llama_decode(context, llama_batch_get_one(&token, 1))
            guard code == 0 else { throw LocalRuntimeError.inferenceFailed(code) }
        }
        try Task.checkCancellation()
        let tail = try decoder.finish()
        if !tail.isEmpty { yield(tail) }
    }

    private func formattedPrompt(messages: [LocalTranslationMessage], model: OpaquePointer) throws -> String {
        let allocations = messages.flatMap { [strdup($0.role), strdup($0.content)] }
        defer { allocations.forEach { free($0) } }
        guard allocations.allSatisfy({ $0 != nil }) else { throw LocalRuntimeError.contextFailed }
        let chat = messages.indices.map { index in
            llama_chat_message(role: UnsafePointer(allocations[index * 2]), content: UnsafePointer(allocations[index * 2 + 1]))
        }
        guard let template = llama_model_chat_template(model, nil) else { throw LocalRuntimeError.invalidTemplate }
        var buffer = [CChar](repeating: 0, count: 4_096)
        var size = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        if size > buffer.count {
            buffer = [CChar](repeating: 0, count: Int(size) + 1)
            size = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard size > 0, size <= buffer.count else { throw LocalRuntimeError.invalidTemplate }
        return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
