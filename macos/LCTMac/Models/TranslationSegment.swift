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
    let source: AudioSource
    
    init(id: UUID = UUID(), timestamp: Date = Date(), sourceText: String, translatedText: String = "", state: TranslationState = .translating, latencyMs: Int = 0, source: AudioSource = .system) {
        self.id = id
        self.timestamp = timestamp
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.state = state
        self.latencyMs = latencyMs
        self.source = source
    }

    /// Tolerant decoding: segments persisted before `source` existed default to `.system`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        sourceText = try c.decode(String.self, forKey: .sourceText)
        translatedText = try c.decode(String.self, forKey: .translatedText)
        state = try c.decode(TranslationState.self, forKey: .state)
        latencyMs = try c.decode(Int.self, forKey: .latencyMs)
        source = try c.decodeIfPresent(AudioSource.self, forKey: .source) ?? .system
    }
}
