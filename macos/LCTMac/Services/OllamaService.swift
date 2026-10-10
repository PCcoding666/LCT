import Foundation

/// Ollama API error types
enum OllamaError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    case timeout
    case serverNotRunning
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Ollama API URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Ollama"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .timeout:
            return "Request timed out"
        case .serverNotRunning:
            return "Ollama server is not running"
        case .modelNotLoaded:
            return "Model not loaded"
        }
    }
}

/// Ollama API response structures
struct OllamaMessage: Codable {
    let role: String
    let content: String
}

struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let temperature: Double?
    let keepAlive: String?
    let think: Bool?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case keepAlive = "keep_alive"
        case think
    }
}

struct OllamaChatResponse: Codable {
    let message: OllamaMessage?
    let done: Bool
    let totalDuration: Int64?
    let loadDuration: Int64?
    let promptEvalCount: Int?
    let promptEvalDuration: Int64?
    let evalCount: Int?
    let evalDuration: Int64?

    enum CodingKeys: String, CodingKey {
        case message, done
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

struct OllamaHealthResponse: Codable {
    let status: String?
}

/// Body for loading a model into memory via /api/generate: no prompt, so no
/// inference runs — Ollama only maps the model into memory.
struct OllamaLoadRequest: Codable {
    let model: String
    let keepAlive: String

    enum CodingKeys: String, CodingKey {
        case model
        case keepAlive = "keep_alive"
    }
}

/// Body for unloading a model via /api/generate: `keep_alive: 0` is Ollama's
/// documented "unload immediately" form and runs no inference.
struct OllamaUnloadRequest: Codable {
    let model: String
    let keepAlive: Int

    enum CodingKeys: String, CodingKey {
        case model
        case keepAlive = "keep_alive"
    }
}

/// Response of `GET /api/ps` (models currently loaded in memory).
struct OllamaPSResponse: Decodable {
    struct Model: Decodable {
        let name: String?
        let model: String?
    }
    let models: [Model]
}

/// Service for interacting with local Ollama API
@MainActor
class OllamaService: ObservableObject {
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var isTranslating: Bool = false
    @Published private(set) var lastError: String?

    private var settings: AppSettings
    private var session: URLSession
    private let injectedSession: URLSession?

    /// Validated chat endpoint; nil when the configured endpoint is invalid or
    /// the remote opt-in is missing, so no request can be created.
    private var chatEndpointURL: URL? {
        settings.validatedOllamaEndpoint?.baseURL.appendingPathComponent("api/chat")
    }

    private var tagsEndpointURL: URL? {
        settings.validatedOllamaEndpoint?.baseURL.appendingPathComponent("api/tags")
    }

    private var generateEndpointURL: URL? {
        settings.validatedOllamaEndpoint?.baseURL.appendingPathComponent("api/generate")
    }

    private var psEndpointURL: URL? {
        settings.validatedOllamaEndpoint?.baseURL.appendingPathComponent("api/ps")
    }

    /// The `keep_alive` value every model-loading request shares, from settings.
    private var keepAliveValue: String {
        settings.modelKeepAlive.ollamaValue
    }

    init(settings: AppSettings = .load(), session: URLSession? = nil) {
        self.settings = settings
        self.injectedSession = session
        self.session = session ?? Self.makeSession(for: settings)
    }

    private static func makeSession(for settings: AppSettings) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(settings.ollamaTimeout)
        config.timeoutIntervalForResource = TimeInterval(settings.ollamaTimeout * 2)
        return URLSession(configuration: config)
    }

    /// Update settings
    func updateSettings(_ newSettings: AppSettings) {
        let shouldRebuildSession = settings.ollamaTimeout != newSettings.ollamaTimeout
        self.settings = newSettings

        guard shouldRebuildSession, injectedSession == nil else { return }

        session.invalidateAndCancel()
        session = Self.makeSession(for: newSettings)
    }

    /// Load the configured model before the first translation so the UI can show explicit progress.
    func prewarmModel() async throws -> Int {
        let startTime = Date()

        guard let url = chatEndpointURL else {
            throw OllamaError.invalidURL
        }

        let request = OllamaChatRequest(
            model: settings.ollamaModel,
            messages: [OllamaMessage(role: "user", content: "hi")],
            stream: false,
            temperature: 0.1,
            keepAlive: keepAliveValue,
            think: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = TimeInterval(max(settings.ollamaTimeout * 2, 60))

        do {
            let (_, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    throw OllamaError.modelNotLoaded
                }
                throw OllamaError.httpError(httpResponse.statusCode)
            }

            lastError = nil
            return Int(Date().timeIntervalSince(startTime) * 1000)
        } catch let error as OllamaError {
            lastError = error.localizedDescription
            throw error
        } catch let error as URLError {
            let mappedError = mapURLError(error)
            lastError = mappedError.localizedDescription
            throw mappedError
        } catch {
            lastError = error.localizedDescription
            throw OllamaError.networkError(error)
        }
    }

    /// Check if Ollama server is running
    func checkHealth() async -> Bool {
        guard let url = tagsEndpointURL else {
            return false
        }

        do {
            let (_, response) = try await session.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                isConnected = httpResponse.statusCode == 200
                return isConnected
            }
            return false
        } catch {
            // A health check is a probe, not a failure report: every caller
            // handles `false` itself (status indicator, launch prewarm,
            // start()'s own notice). Setting `lastError` here surfaced a
            // "Cannot connect to Ollama" error notice at launch while LCT was
            // already starting Ollama.
            isConnected = false
            return false
        }
    }

    /// Build messages for TranslateGemma model (uses ISO language codes, different format)
    private func buildTranslateGemmaMessages(text: String, context: [TranslationEntry]) -> [OllamaMessage] {
        // TranslateGemma expects a specific format: <2xx> where xx is the target language ISO code
        let targetCode = settings.targetLanguage.isoCode
        let prompt = "<2\(targetCode)> \(text)"
        return [OllamaMessage(role: "user", content: prompt)]
    }

    /// Build messages for standard chat models
    private func buildStandardMessages(text: String, context: [TranslationEntry]) -> [OllamaMessage] {
        var messages: [OllamaMessage] = [
            OllamaMessage(role: "system", content: settings.translationPrompt)
        ]

        // Add context from previous translations (if context-aware)
        if settings.contextAware {
            for entry in context.suffix(settings.maxContextEntries) {
                messages.append(OllamaMessage(role: "user", content: "🔤 \(entry.sourceText) 🔤"))
                messages.append(OllamaMessage(role: "assistant", content: entry.translatedText))
            }
        }

        // Add current text to translate
        messages.append(OllamaMessage(role: "user", content: "🔤 \(text) 🔤"))
        return messages
    }

    /// Translate text using Ollama
    func translate(text: String, context: [TranslationEntry] = []) async throws -> (String, Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("", 0)
        }

        let startTime = Date()
        isTranslating = true
        defer { isTranslating = false }

        guard let url = chatEndpointURL else {
            throw OllamaError.invalidURL
        }

        // Build messages based on model type
        let messages: [OllamaMessage]
        let isTranslateGemma = settings.ollamaModel.lowercased().contains("translategemma")
        let modelType = isTranslateGemma ? TranslationModelType.translateGemma : settings.translationModelType

        switch modelType {
        case .translateGemma:
            messages = buildTranslateGemmaMessages(text: text, context: context)
        case .standard:
            messages = buildStandardMessages(text: text, context: context)
        }

        let request = OllamaChatRequest(
            model: settings.ollamaModel,
            messages: messages,
            stream: false,
            temperature: settings.translationModelType == .translateGemma ? 0.1 : settings.ollamaTemperature,
            keepAlive: keepAliveValue,
            think: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw OllamaError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 404 {
                    throw OllamaError.modelNotLoaded
                }
                throw OllamaError.httpError(httpResponse.statusCode)
            }

            let ollamaResponse = try JSONDecoder().decode(OllamaChatResponse.self, from: data)

            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            var translatedText = ollamaResponse.message?.content ?? ""

            // Clean up the response - remove emoji markers if present
            translatedText = translatedText.replacingOccurrences(of: "🔤", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Remove any thinking/reasoning tags
            translatedText = removeThinkingTags(from: translatedText)

            lastError = nil
            return (translatedText, latencyMs)

        } catch is CancellationError {
            // Deliberate cancellation (pause, ASR rollback, preemption) — not a network failure
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            appLog("[OllamaService] ❌ OllamaError in translate: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw error
        } catch let error as URLError {
            let mappedError = mapURLError(error)
            appLog("[OllamaService] ❌ URLError in translate: \(mappedError.localizedDescription)")
            lastError = mappedError.localizedDescription
            throw mappedError
        } catch {
            appLog("[OllamaService] ❌ Unknown error in translate: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw OllamaError.networkError(error)
        }
    }

    /// Translate text using streaming for better UX (lower perceived latency)
    func translateStreaming(text: String, context: [TranslationEntry] = [], onToken: @escaping (String) -> Void) async throws -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }

        let startTime = Date()
        isTranslating = true
        defer { isTranslating = false }

        guard let url = chatEndpointURL else {
            throw OllamaError.invalidURL
        }

        // Build messages based on model type
        let messages: [OllamaMessage]
        let isTranslateGemma = settings.ollamaModel.lowercased().contains("translategemma")
        let modelType = isTranslateGemma ? TranslationModelType.translateGemma : settings.translationModelType

        switch modelType {
        case .translateGemma:
            messages = buildTranslateGemmaMessages(text: text, context: context)
        case .standard:
            messages = buildStandardMessages(text: text, context: context)
        }

        let request = OllamaChatRequest(
            model: settings.ollamaModel,
            messages: messages,
            stream: true,  // Enable streaming
            temperature: settings.translationModelType == .translateGemma ? 0.1 : settings.ollamaTemperature,
            keepAlive: keepAliveValue,
            think: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        do {
            let (asyncBytes, response) = try await session.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw OllamaError.invalidResponse
            }

            // Process streaming response
            for try await line in asyncBytes.lines {
                guard !Task.isCancelled else { break }

                guard let data = line.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
                    continue
                }

                if let content = chunk.message?.content, !content.isEmpty {
                    // Clean and emit token
                    let cleanContent = content.replacingOccurrences(of: "🔤", with: "")
                    if !cleanContent.isEmpty {
                        onToken(cleanContent)
                    }
                }

                if chunk.done {
                    break
                }
            }

            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
            lastError = nil
            return latencyMs

        } catch is CancellationError {
            // Deliberate cancellation (pause, ASR rollback, preemption) — not a network failure
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as OllamaError {
            appLog("[OllamaService] ❌ OllamaError in translateStreaming: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw error
        } catch let error as URLError {
            let mappedError = mapURLError(error)
            appLog("[OllamaService] ❌ URLError in translateStreaming: \(mappedError.localizedDescription)")
            lastError = mappedError.localizedDescription
            throw mappedError
        } catch {
            appLog("[OllamaService] ❌ Unknown error in translateStreaming: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw OllamaError.networkError(error)
        }
    }

    /// Unload a model from memory by name. Sends only the model name and
    /// `keep_alive: 0` — no prompt, no inference.
    func unloadModel(_ name: String) async throws {
        guard let url = generateEndpointURL else {
            throw OllamaError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(OllamaUnloadRequest(model: name, keepAlive: 0))
        urlRequest.timeoutInterval = 5

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse
        }
        appLog("[OllamaService] Model \(name) unloaded")
    }

    /// Load a model into memory by name without running inference. The
    /// `keep_alive` value comes from settings.
    func loadModel(_ name: String) async throws {
        guard let url = generateEndpointURL else {
            throw OllamaError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(OllamaLoadRequest(model: name, keepAlive: keepAliveValue))
        urlRequest.timeoutInterval = 120  // Loading can take time

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse
        }
    }

    /// Names of the models currently held in memory (`GET /api/ps`).
    func loadedModels() async throws -> [String] {
        guard let url = psEndpointURL else {
            throw OllamaError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse
        }

        return try Self.parseLoadedModels(from: data)
    }

    /// Parse a `/api/ps` response into model names. Accepts both the `name`
    /// and the `model` field spelling used by different Ollama versions.
    static func parseLoadedModels(from data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(OllamaPSResponse.self, from: data)
        return response.models.compactMap { $0.name ?? $0.model }
    }

    /// Remove thinking/reasoning tags from model output
    private func removeThinkingTags(from text: String) -> String {
        var result = text

        // Remove <think>...</think> tags
        let thinkPattern = #"<think>.*?</think>"#
        if let regex = try? NSRegularExpression(pattern: thinkPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove [thinking]...[/thinking] tags
        let bracketPattern = #"\[thinking\].*?\[/thinking\]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapURLError(_ error: URLError) -> OllamaError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return .serverNotRunning
        default:
            return .networkError(error)
        }
    }

    /// Get available models from Ollama
    func getAvailableModels() async throws -> [String] {
        guard let url = tagsEndpointURL else {
            throw OllamaError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse
        }

        struct TagsResponse: Codable {
            struct Model: Codable {
                let name: String
            }
            let models: [Model]
        }

        let tagsResponse = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tagsResponse.models.map { $0.name }
    }
}
