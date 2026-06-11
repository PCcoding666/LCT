import Foundation

class CaptionSegmenter {
    private var currentTaskId: UUID?
    private var committedLength: Int = 0
    private var committedText: String = ""
    private var lastText: String = ""
    private var lastUpdateTime: Date = Date()
    
    /// Process incoming ASR text and returns newly finalized segments and the current live draft.
    func process(result: TranscriptionResult) -> (finalized: [String], liveDraft: String, didRollback: Bool) {
        var newlyFinalized: [String] = []
        
        if currentTaskId != result.id {
            currentTaskId = result.id
            committedLength = 0
            committedText = ""
            lastText = ""
            lastUpdateTime = Date()
        }
        
        let text = result.text
        
        if !committedText.isEmpty && !text.hasPrefix(committedText) {
            // SFSpeech can revise already-seen text. Invalidate prior commits for
            // this task so callers can cancel stale translations and reprocess.
            committedLength = 0
            committedText = ""
            lastText = text
            lastUpdateTime = Date()
            return ([], text, true)
        }
        
        let startIndex = text.index(text.startIndex, offsetBy: committedLength)
        let uncommittedText = String(text[startIndex...])
        
        var liveDraft = uncommittedText
        
        if result.isVolatile {
            let timeSinceUpdate = Date().timeIntervalSince(lastUpdateTime)
            let hasPunctuation = uncommittedText.contains(where: { ".!?。！？".contains($0) })
            let isTooLong = uncommittedText.count > 200 // Force cut if > 200 chars
            
            if isTooLong || (hasPunctuation && timeSinceUpdate > 1.5) {
                if let cutPos = findCutPosition(in: uncommittedText) {
                    let segment = String(uncommittedText.prefix(upTo: cutPos)).trimmingCharacters(in: .whitespaces)
                    if !segment.isEmpty {
                        newlyFinalized.append(segment)
                    }
                    
                    let offset = uncommittedText.distance(from: uncommittedText.startIndex, to: cutPos)
                    committedLength += offset
                    let committedEnd = text.index(text.startIndex, offsetBy: committedLength)
                    committedText = String(text[..<committedEnd])
                    liveDraft = String(uncommittedText[cutPos...]).trimmingCharacters(in: .whitespaces)
                }
            }
            
            if uncommittedText != lastText {
                lastText = uncommittedText
                lastUpdateTime = Date()
            }
        } else {
            // isFinal == true, commit the rest
            let segment = uncommittedText.trimmingCharacters(in: .whitespaces)
            if !segment.isEmpty {
                newlyFinalized.append(segment)
            }
            committedLength = text.count
            committedText = text
            liveDraft = ""
            lastText = ""
        }
        
        return (newlyFinalized, liveDraft, false)
    }
    
    func reset() {
        currentTaskId = nil
        committedLength = 0
        committedText = ""
        lastText = ""
    }
    
    private func findCutPosition(in text: String) -> String.Index? {
        if let lastPunc = text.lastIndex(where: { ".!?。！？".contains($0) }) {
            return text.index(after: lastPunc)
        }
        if text.count > 150 {
            if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
                return text.index(after: lastSpace)
            }
            if TextUtils.containsCJK(text) {
                return text.index(text.startIndex, offsetBy: min(150, text.count))
            }
        }
        return nil
    }
}
