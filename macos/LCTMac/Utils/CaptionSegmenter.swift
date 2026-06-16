import Foundation

class CaptionSegmenter {
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]

    /// Force a cut once the draft exceeds this many characters, even mid-sentence
    private let forceCutLength: Int
    /// Minimum completed-sentence length required to cut while speech continues
    private let eagerCutMinLength: Int
    /// Cut at a trailing sentence end once the draft has been quiet this long
    private let quietCutInterval: TimeInterval
    /// Fallback wrap point when force-cutting text that has no punctuation
    private let hardWrapLength: Int

    private var currentTaskId: UUID?
    private var committedLength: Int = 0
    private var committedText: String = ""
    /// End offset (in characters of the full ASR text) of each emitted segment,
    /// in order. Parallel to the segments the caller created for this task.
    private var committedSegmentEnds: [Int] = []
    private var lastText: String = ""
    private var lastUpdateTime: Date = Date()

    init(
        forceCutLength: Int = 120,
        eagerCutMinLength: Int = 40,
        quietCutInterval: TimeInterval = 0.8,
        hardWrapLength: Int = 100
    ) {
        self.forceCutLength = forceCutLength
        self.eagerCutMinLength = eagerCutMinLength
        self.quietCutInterval = quietCutInterval
        self.hardWrapLength = hardWrapLength
    }

    /// Process incoming ASR text. Returns newly finalized segments, the current
    /// live draft, and how many trailing previously-emitted segments were
    /// invalidated by an ASR revision (0 when no rollback happened).
    func process(result: TranscriptionResult) -> (finalized: [String], liveDraft: String, invalidatedTailCount: Int) {
        if currentTaskId != result.id {
            currentTaskId = result.id
            committedLength = 0
            committedText = ""
            committedSegmentEnds = []
            lastText = ""
            lastUpdateTime = Date()
        }

        let text = result.text

        if !committedText.isEmpty && !text.hasPrefix(committedText) {
            // SFSpeech revised already-committed text. Roll back only the
            // segments past the surviving common prefix instead of everything.
            return handleRollback(newText: text)
        }

        let startIndex = text.index(text.startIndex, offsetBy: committedLength)
        let uncommittedText = String(text[startIndex...])

        var newlyFinalized: [String] = []
        var liveDraft = uncommittedText

        if result.isVolatile {
            if shouldCut(uncommittedText), let cutPos = findCutPosition(in: uncommittedText) {
                let segment = String(uncommittedText.prefix(upTo: cutPos)).trimmingCharacters(in: .whitespaces)

                let offset = uncommittedText.distance(from: uncommittedText.startIndex, to: cutPos)
                committedLength += offset
                let committedEnd = text.index(text.startIndex, offsetBy: committedLength)
                committedText = String(text[..<committedEnd])
                liveDraft = String(uncommittedText[cutPos...]).trimmingCharacters(in: .whitespaces)

                if !segment.isEmpty {
                    newlyFinalized.append(segment)
                    committedSegmentEnds.append(committedLength)
                }
            }

            if uncommittedText != lastText {
                lastText = uncommittedText
                lastUpdateTime = Date()
            }
        } else {
            // isFinal == true, commit the rest
            let segment = uncommittedText.trimmingCharacters(in: .whitespaces)
            committedLength = text.count
            committedText = text
            liveDraft = ""
            lastText = ""

            if !segment.isEmpty {
                newlyFinalized.append(segment)
                committedSegmentEnds.append(committedLength)
            }
        }

        return (newlyFinalized, liveDraft, 0)
    }

    func reset() {
        currentTaskId = nil
        committedLength = 0
        committedText = ""
        committedSegmentEnds = []
        lastText = ""
    }

    // MARK: - Cut decision

    private func shouldCut(_ uncommitted: String) -> Bool {
        if uncommitted.count > forceCutLength {
            return true
        }

        guard let lastPunct = uncommitted.lastIndex(where: { Self.sentenceEnders.contains($0) }) else {
            return false
        }

        let afterPunct = uncommitted.index(after: lastPunct)
        let trailing = uncommitted[afterPunct...].trimmingCharacters(in: .whitespaces)

        if !trailing.isEmpty {
            // Speech has moved past a completed sentence — cut as soon as the
            // completed part is substantial, without waiting for a pause.
            let completedCount = uncommitted.distance(from: uncommitted.startIndex, to: afterPunct)
            if completedCount >= eagerCutMinLength {
                return true
            }
        }

        // Trailing or short sentence: wait for a brief quiet period so the ASR
        // has a chance to revise it before we commit.
        return Date().timeIntervalSince(lastUpdateTime) > quietCutInterval
    }

    private func findCutPosition(in text: String) -> String.Index? {
        if let lastPunc = text.lastIndex(where: { Self.sentenceEnders.contains($0) }) {
            return text.index(after: lastPunc)
        }
        if text.count > hardWrapLength {
            if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
                return text.index(after: lastSpace)
            }
            if TextUtils.containsCJK(text) {
                return text.index(text.startIndex, offsetBy: min(hardWrapLength, text.count))
            }
        }
        return nil
    }

    // MARK: - Rollback

    private func handleRollback(newText text: String) -> (finalized: [String], liveDraft: String, invalidatedTailCount: Int) {
        let prefixLength = commonPrefixLength(committedText, text)

        // Segments fully inside the unchanged prefix survive; the rest are stale
        let survivingEnds = committedSegmentEnds.prefix(while: { $0 <= prefixLength })
        let staleCount = committedSegmentEnds.count - survivingEnds.count

        committedSegmentEnds = Array(survivingEnds)
        committedLength = survivingEnds.last ?? 0
        let committedEnd = text.index(text.startIndex, offsetBy: committedLength)
        committedText = String(text[..<committedEnd])

        let liveDraft = String(text[committedEnd...]).trimmingCharacters(in: .whitespaces)
        lastText = liveDraft
        lastUpdateTime = Date()

        return ([], liveDraft, staleCount)
    }

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (ca, cb) in zip(a, b) {
            if ca != cb { break }
            count += 1
        }
        return count
    }
}
