import Foundation

/// Represents a single transcription segment from speech recognition
struct TranscriptionResult: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let speaker: String?           // Speaker identifier (e.g., "Speaker 1")
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isVolatile: Bool           // Whether this is a temporary/interim result
    let confidence: Float?         // Recognition confidence (0.0 - 1.0)
    let source: AudioSource        // Which capture lane produced this result
    
    init(
        id: UUID = UUID(),
        text: String,
        speaker: String? = nil,
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 0,
        isVolatile: Bool = false,
        confidence: Float? = nil,
        source: AudioSource = .system
    ) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.isVolatile = isVolatile
        self.confidence = confidence
        self.source = source
    }

    /// Tolerant decoding: results persisted before `source` existed default to `.system`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        startTime = try c.decode(TimeInterval.self, forKey: .startTime)
        endTime = try c.decode(TimeInterval.self, forKey: .endTime)
        isVolatile = try c.decode(Bool.self, forKey: .isVolatile)
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence)
        source = try c.decodeIfPresent(AudioSource.self, forKey: .source) ?? .system
    }
    
    /// Duration of this segment in seconds
    var duration: TimeInterval {
        endTime - startTime
    }
    
    /// Formatted speaker label for display
    var speakerLabel: String {
        speaker ?? "Unknown"
    }
}

/// Collection of transcription results with utility methods
struct TranscriptionSession: Identifiable {
    let id: UUID
    var segments: [TranscriptionResult]
    let startedAt: Date
    var endedAt: Date?
    
    init(id: UUID = UUID(), segments: [TranscriptionResult] = [], startedAt: Date = Date()) {
        self.id = id
        self.segments = segments
        self.startedAt = startedAt
    }
    
    /// Get all unique speakers in this session
    var speakers: [String] {
        Array(Set(segments.compactMap { $0.speaker })).sorted()
    }
    
    /// Get full transcript as a single string
    var fullTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }
    
    /// Get transcript with speaker labels
    var formattedTranscript: String {
        segments.map { segment in
            if let speaker = segment.speaker {
                return "[\(speaker)] \(segment.text)"
            }
            return segment.text
        }.joined(separator: "\n")
    }
}
