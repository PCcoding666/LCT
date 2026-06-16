import Foundation

/// State of a translation segment
enum TranslationState: String, Codable, Equatable {
    case recognizing = "recognizing" // (Not used directly if we only create it when finalized, but useful)
    case pending = "pending" // Finalized while paused; will be enqueued on resume
    case translating = "translating"
    case translated = "translated"
    case failed = "failed"
}

/// A finalized transcript segment and its translation
struct TranslationSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let sourceText: String
    var translatedText: String
    var state: TranslationState
    var latencyMs: Int
    
    init(id: UUID = UUID(), timestamp: Date = Date(), sourceText: String, translatedText: String = "", state: TranslationState = .translating, latencyMs: Int = 0) {
        self.id = id
        self.timestamp = timestamp
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.state = state
        self.latencyMs = latencyMs
    }
}
