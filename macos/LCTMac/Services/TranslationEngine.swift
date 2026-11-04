import Foundation

/// Translation boundary. Token callbacks run in order on the MainActor and
/// finish before the async call returns. Implementations must honor cancellation.
@MainActor
protocol TranslationEngine: AnyObject {
    func updateSettings(_ settings: AppSettings)
    func translate(text: String, context: [TranslationEntry]) async throws -> (String, Int)
    func translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int
}

// Kept for existing transport/queue regression fixtures only. Production
// view models create EmbeddedTranslationService, never this legacy provider.
extension OllamaService: TranslationEngine {}
