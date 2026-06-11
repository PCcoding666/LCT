import XCTest
@testable import LCTMac

final class CaptionSegmenterTests: XCTestCase {
    func testCJKLongVolatileTextCutsAtCharacterBoundary() {
        let segmenter = CaptionSegmenter()
        let text = String(repeating: "中", count: 201)

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertEqual(result.finalized.count, 1)
        XCTAssertEqual(result.finalized.first?.count, 150)
        XCTAssertEqual(result.liveDraft.count, 51)
        XCTAssertFalse(result.didRollback)
    }

    func testCJKLongVolatileTextDoesNotSplitExtendedGraphemeClusters() {
        let segmenter = CaptionSegmenter()
        let text = String(repeating: "中", count: 149) + "👨‍👩‍👧‍👦" + String(repeating: "文", count: 60)

        let result = segmenter.process(result: TranscriptionResult(
            text: text,
            isVolatile: true
        ))

        XCTAssertEqual(result.finalized.count, 1)
        XCTAssertEqual(result.finalized.first?.count, 150)
        XCTAssertTrue(result.finalized.first?.hasSuffix("👨‍👩‍👧‍👦") == true)
        XCTAssertEqual(result.liveDraft.count, 60)
    }

    func testASRRollbackInvalidatesCommittedText() {
        let segmenter = CaptionSegmenter()
        let taskId = UUID()
        let originalText = String(repeating: "中", count: 201)

        let firstResult = segmenter.process(result: TranscriptionResult(
            id: taskId,
            text: originalText,
            isVolatile: true
        ))
        XCTAssertEqual(firstResult.finalized.count, 1)
        XCTAssertFalse(firstResult.didRollback)

        let correctedText = String(repeating: "文", count: 80)
        let rollbackResult = segmenter.process(result: TranscriptionResult(
            id: taskId,
            text: correctedText,
            isVolatile: true
        ))

        XCTAssertTrue(rollbackResult.didRollback)
        XCTAssertTrue(rollbackResult.finalized.isEmpty)
        XCTAssertEqual(rollbackResult.liveDraft, correctedText)
    }
}
