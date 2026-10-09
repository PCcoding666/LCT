import Foundation

/// Pure mapping from SpeechTranscriber-style results to `TranscriptionResult`.
/// Deliberately free of any Speech-framework dependency (inputs are plain
/// values) so it compiles on every toolchain and can be unit-tested directly.
///
/// Segment-id policy: a lane's results form a stream of utterances. Volatile
/// (non-final) results refine the current utterance and keep its id; a final
/// result closes the utterance and the id rotates, so the next result starts
/// a fresh segment downstream (the CaptionSegmenter keys off these ids).
struct TranscriberResultMapper {
    private(set) var currentSegmentId: UUID
    private var lastEmittedText: String = ""

    init(segmentId: UUID = UUID()) {
        self.currentSegmentId = segmentId
    }

    /// Map one recognizer result. Returns nil when nothing should be emitted:
    /// - empty text (mirrors the legacy engine, which skips empty transcripts);
    /// - a volatile result identical to the last emitted one (dedup).
    ///
    /// An empty final also emits nothing but still rotates the segment id: the
    /// final marks the end of the current utterance, and keeping the id would
    /// merge the next utterance's volatile text into this one's segment
    /// downstream. A final whose text equals the last volatile is still
    /// emitted (as non-volatile) so the segment gets committed.
    mutating func map(
        text: String,
        isFinal: Bool,
        start: TimeInterval,
        end: TimeInterval,
        source: AudioSource
    ) -> TranscriptionResult? {
        defer {
            if isFinal {
                currentSegmentId = UUID()
                lastEmittedText = ""
            }
        }
        guard !text.isEmpty else { return nil }
        if !isFinal && text == lastEmittedText { return nil }
        lastEmittedText = text
        return TranscriptionResult(
            id: currentSegmentId,
            text: text,
            speaker: nil,
            startTime: start,
            endTime: end,
            isVolatile: !isFinal,
            confidence: nil,
            source: source
        )
    }
}
