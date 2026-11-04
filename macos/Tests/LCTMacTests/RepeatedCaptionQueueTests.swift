import XCTest
@testable import LCTMac

@MainActor
final class RepeatedCaptionQueueTests: XCTestCase {
    private final class Engine: TranslationEngine {
        var holdFirst = false
        private(set) var texts: [String] = []
        private var firstContinuation: CheckedContinuation<Void, Never>?
        func updateSettings(_ settings: AppSettings) {}
        func translate(text: String, context: [TranslationEntry]) async throws -> (String, Int) {
            texts.append(text)
            if holdFirst && texts.count == 1 {
                await withCheckedContinuation { firstContinuation = $0 }
            }
            return ("Translated: " + text, 1)
        }
        func translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int {
            let (translated, latency) = try await translate(text: text, context: context)
            onToken(translated)
            return latency
        }
        func releaseFirst() {
            firstContinuation?.resume()
            firstContinuation = nil
        }
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func testRepeatedFinalText_DistinctSegments_EachReceivesCompletedTranslation() async {
        for streaming in [true, false] {
            let engine = Engine()
            let queue = TranslationQueue(engine: engine)
            queue.useStreaming = streaming
            var results: [TranslationQueueResult] = []
            queue.onTranslationComplete = { results.append($0) }
            let first = UUID(), second = UUID()

            queue.enqueue(segmentId: first, text: "Thank you.")
            let firstCompleted = await waitFor { results.count == 1 }
            XCTAssertTrue(firstCompleted)
            queue.enqueue(segmentId: second, text: "Thank you.")
            let bothCompleted = await waitFor { results.count == 2 }

            XCTAssertTrue(bothCompleted, "Distinct caption IDs must both finish, including repeated speech")
            XCTAssertEqual(results.map(\.segmentId), [first, second])
            XCTAssertEqual(results.map(\.translatedText), ["Translated: Thank you.", "Translated: Thank you."])
            queue.cancelAll()
        }
    }

    func testPendingRepeatedText_SystemAndMicrophoneSegments_BothComplete() async {
        let engine = Engine()
        engine.holdFirst = true
        defer { engine.releaseFirst() }
        let queue = TranslationQueue(engine: engine)
        var completed: [UUID] = []
        queue.onTranslationComplete = { completed.append($0.segmentId) }
        let blockingID = UUID()
        let laneSegments: [(source: AudioSource, id: UUID)] = [(.system, UUID()), (.microphone, UUID())]
        queue.enqueue(segmentId: blockingID, text: "Earlier caption")
        let firstBegan = await waitFor { engine.texts.count == 1 }
        XCTAssertTrue(firstBegan)

        for segment in laneSegments { queue.enqueue(segmentId: segment.id, text: "Yes.") }
        XCTAssertEqual(queue.pendingCount, 2, "Equal words on different capture lanes are distinct captions")
        engine.releaseFirst()
        let allCompleted = await waitFor { completed.count == 3 }

        XCTAssertTrue(allCompleted)
        XCTAssertEqual(Set(completed), Set([blockingID] + laneSegments.map(\.id)))
        XCTAssertEqual(engine.texts, ["Earlier caption", "Yes.", "Yes."])
        queue.cancelAll()
    }

    func testSameSegmentDuplicate_WhilePendingAndAfterCompletion_TranslatesOnce() async {
        let engine = Engine()
        engine.holdFirst = true
        defer { engine.releaseFirst() }
        let queue = TranslationQueue(engine: engine)
        var completed: [UUID] = []
        queue.onTranslationComplete = { completed.append($0.segmentId) }
        let first = UUID(), duplicate = UUID()
        queue.enqueue(segmentId: first, text: "Earlier caption")
        let firstBegan = await waitFor { engine.texts.count == 1 }
        XCTAssertTrue(firstBegan)
        queue.enqueue(segmentId: duplicate, text: "Yes.")
        queue.enqueue(segmentId: duplicate, text: "Yes.")
        XCTAssertEqual(queue.pendingCount, 1)
        engine.releaseFirst()
        let finished = await waitFor { completed.count == 2 }
        XCTAssertTrue(finished)
        queue.enqueue(segmentId: duplicate, text: "Yes.")
        await Task.yield()
        XCTAssertEqual(completed, [first, duplicate])
        XCTAssertFalse(queue.isProcessing)
        queue.cancelAll()
    }
}
