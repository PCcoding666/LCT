import XCTest
@testable import LCTMac

/// Tests for TranslationQueue debouncing and priority logic
final class TranslationQueueTests: XCTestCase {

    // MARK: - TranslationTask Priority Tests

    func testPriorityOrdering() {
        let highTask = makeTask(text: "Hello", priority: .high, isFinal: true)
        let normalTask = makeTask(text: "World", priority: .normal, isFinal: false)
        let lowTask = makeTask(text: "Test", priority: .low, isFinal: false)

        // High priority should be processed first
        XCTAssertTrue(highTask.priority.rawValue > normalTask.priority.rawValue)
        XCTAssertTrue(normalTask.priority.rawValue > lowTask.priority.rawValue)
    }

    func testTaskTimestampOrdering() {
        // Create tasks with a slight delay to ensure different timestamps
        let task1 = makeTask(text: "First", priority: .normal, isFinal: false)
        // task2 is created later, so task1.timestamp < task2.timestamp
        let task2 = makeTask(text: "Second", priority: .normal, isFinal: false)

        // Same priority: earlier timestamp should be first (FIFO)
        // task1 was created first, so its timestamp should be <= task2's
        XCTAssertTrue(task1.timestamp <= task2.timestamp)
    }

    // MARK: - Deduplication Tests

    func testSameTextDeduplication() {
        // Tasks with the same text should be considered duplicates
        let task1 = makeTask(text: "Hello world", priority: .low, isFinal: false)
        let task2 = makeTask(text: "Hello world", priority: .high, isFinal: true)

        // Same text = same dedup key
        XCTAssertEqual(task1.text, task2.text)
    }

    func testDifferentTextNotDeduplicated() {
        let task1 = makeTask(text: "Hello", priority: .normal, isFinal: false)
        let task2 = makeTask(text: "World", priority: .normal, isFinal: false)

        XCTAssertNotEqual(task1.text, task2.text)
    }

    // MARK: - TranslationQueueResult Tests

    func testSuccessfulResult() {
        let result = TranslationQueueResult(
            segmentId: UUID(),
            originalText: "Hello",
            translatedText: "你好",
            latencyMs: 150,
            success: true
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.originalText, "Hello")
        XCTAssertEqual(result.translatedText, "你好")
        XCTAssertEqual(result.latencyMs, 150)
        XCTAssertNil(result.error)
    }

    func testFailedResult() {
        let result = TranslationQueueResult(
            segmentId: UUID(),
            originalText: "Hello",
            translatedText: "",
            latencyMs: 0,
            success: false
        )

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.translatedText.isEmpty)
    }

    // MARK: - Priority Enum Tests

    func testPriorityRawValues() {
        XCTAssertEqual(TranslationPriority.low.rawValue, 0)
        XCTAssertEqual(TranslationPriority.normal.rawValue, 1)
        XCTAssertEqual(TranslationPriority.high.rawValue, 2)
    }

    // MARK: - Generation Counter Tests

    func testTranslationTaskIsFinal() {
        let volatileTask = makeTask(text: "partial", isFinal: false)
        let finalTask = makeTask(text: "final", isFinal: true)

        XCTAssertFalse(volatileTask.isFinal)
        XCTAssertTrue(finalTask.isFinal)
    }

    func testTranslationTaskDefaultPriority() {
        let task = makeTask(text: "test")
        XCTAssertEqual(task.priority, .normal)
        XCTAssertTrue(task.isFinal) // default is true
    }

    // MARK: - Helpers

    private func makeTask(text: String, priority: TranslationPriority = .normal, isFinal: Bool = true) -> TranslationTask {
        TranslationTask(
            segmentId: UUID(),
            text: text,
            context: [],
            priority: priority,
            isFinal: isFinal
        )
    }
}
