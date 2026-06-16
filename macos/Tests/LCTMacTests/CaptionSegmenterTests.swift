import XCTest
@testable import LCTMac

final class CaptionSegmenterTests: XCTestCase {

    // MARK: - Force cut (no punctuation)

    func testCJKLongVolatileTextCutsAtCharacterBoundary() {
        let segmenter = CaptionSegmenter()
        let text = String(repeating: "中", count: 121)

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertEqual(result.finalized.count, 1)
        XCTAssertEqual(result.finalized.first?.count, 100)
        XCTAssertEqual(result.liveDraft.count, 21)
        XCTAssertEqual(result.invalidatedTailCount, 0)
    }

    func testCJKLongVolatileTextDoesNotSplitExtendedGraphemeClusters() {
        let segmenter = CaptionSegmenter()
        let text = String(repeating: "中", count: 99) + "👨‍👩‍👧‍👦" + String(repeating: "文", count: 60)

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertEqual(result.finalized.count, 1)
        XCTAssertEqual(result.finalized.first?.count, 100)
        XCTAssertTrue(result.finalized.first?.hasSuffix("👨‍👩‍👧‍👦") == true)
        XCTAssertEqual(result.liveDraft.count, 60)
    }

    // MARK: - Eager cut (completed sentence while speech continues)

    func testEagerCutAfterCompletedSentenceWithTrailingSpeech() {
        let segmenter = CaptionSegmenter()
        let sentence = "This is a complete sentence that is clearly over forty characters."
        let text = sentence + " And the speaker keeps"

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertEqual(result.finalized, [sentence],
                       "A completed sentence followed by new speech must be cut immediately")
        XCTAssertEqual(result.liveDraft, "And the speaker keeps")
    }

    func testNoEagerCutForShortSentence() {
        // Quiet interval set high so only the eager path could trigger
        let segmenter = CaptionSegmenter(quietCutInterval: 999)
        let text = "OK. And then we"

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertTrue(result.finalized.isEmpty,
                      "Short fragments must accumulate instead of becoming tiny segments")
        XCTAssertEqual(result.liveDraft, text)
    }

    func testNoCutWhilePunctuationIsTrailingAndDraftIsFresh() {
        let segmenter = CaptionSegmenter()
        let text = "This sentence just ended and might still be revised by the recognizer."

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertTrue(result.finalized.isEmpty,
                      "A sentence with trailing punctuation needs a quiet period before committing")
    }

    // MARK: - Quiet cut (pause in recognition updates)

    func testQuietCutAfterRecognitionPause() {
        let segmenter = CaptionSegmenter(quietCutInterval: 0.05)
        let taskId = UUID()
        let text = "This sentence ended and the speaker paused."

        let first = segmenter.process(result: TranscriptionResult(id: taskId, text: text, isVolatile: true))
        XCTAssertTrue(first.finalized.isEmpty)

        Thread.sleep(forTimeInterval: 0.1)

        let second = segmenter.process(result: TranscriptionResult(id: taskId, text: text, isVolatile: true))
        XCTAssertEqual(second.finalized, [text])
        XCTAssertEqual(second.liveDraft, "")
    }

    // MARK: - Rollback

    func testFullRollbackWhenAllCommittedTextRevised() {
        let segmenter = CaptionSegmenter()
        let taskId = UUID()
        let originalText = String(repeating: "中", count: 121)

        let firstResult = segmenter.process(result: TranscriptionResult(
            id: taskId,
            text: originalText,
            isVolatile: true
        ))
        XCTAssertEqual(firstResult.finalized.count, 1)
        XCTAssertEqual(firstResult.invalidatedTailCount, 0)

        let correctedText = String(repeating: "文", count: 80)
        let rollbackResult = segmenter.process(result: TranscriptionResult(
            id: taskId,
            text: correctedText,
            isVolatile: true
        ))

        XCTAssertEqual(rollbackResult.invalidatedTailCount, 1)
        XCTAssertTrue(rollbackResult.finalized.isEmpty)
        XCTAssertEqual(rollbackResult.liveDraft, correctedText)
    }

    func testPartialRollbackKeepsSegmentsInsideUnchangedPrefix() {
        let segmenter = CaptionSegmenter()
        let taskId = UUID()
        let s1 = "The first sentence is long enough to pass the eager threshold."
        let s2 = "The second sentence is also long enough to pass the threshold."

        // Commit S1 (eager cut: completed sentence + trailing speech)
        let r1 = segmenter.process(result: TranscriptionResult(
            id: taskId, text: s1 + " More", isVolatile: true
        ))
        XCTAssertEqual(r1.finalized, [s1])

        // Commit S2 the same way
        let r2 = segmenter.process(result: TranscriptionResult(
            id: taskId, text: s1 + " " + s2 + " Tail", isVolatile: true
        ))
        XCTAssertEqual(r2.finalized, [s2])

        // ASR revises only S2 — S1 must survive, exactly one segment revoked
        let r3 = segmenter.process(result: TranscriptionResult(
            id: taskId, text: s1 + " Completely different revision", isVolatile: true
        ))
        XCTAssertEqual(r3.invalidatedTailCount, 1,
                       "Only the segment containing the revision may be rolled back")
        XCTAssertTrue(r3.finalized.isEmpty)
        XCTAssertEqual(r3.liveDraft, "Completely different revision")

        // Pipeline must keep working after a partial rollback
        let r4 = segmenter.process(result: TranscriptionResult(
            id: taskId,
            text: s1 + " Completely different revision that has grown long enough to end. Next",
            isVolatile: true
        ))
        XCTAssertEqual(r4.finalized, ["Completely different revision that has grown long enough to end."])
        XCTAssertEqual(r4.invalidatedTailCount, 0)
    }
}
