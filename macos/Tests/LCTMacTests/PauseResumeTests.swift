import XCTest
@testable import LCTMac

/// Tests for pause/resume translation lifecycle:
/// segments must never dangle in .translating after a pause.
@MainActor
final class PauseResumeTests: XCTestCase {

    // MARK: - TranslationState.pending model tests

    func testPendingStateCodableRoundTrip() throws {
        let segment = TranslationSegment(sourceText: "Hello", state: .pending)

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranslationSegment.self, from: data)

        XCTAssertEqual(decoded.state, .pending)
        XCTAssertEqual(decoded.sourceText, "Hello")
    }

    // MARK: - ViewModel pause/resume tests

    func testPauseMarksTranslatingSegmentsAsPending() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = [
            TranslationSegment(sourceText: "Done", translatedText: "完成", state: .translated),
            TranslationSegment(sourceText: "In flight", translatedText: "部分流式输出", state: .translating),
            TranslationSegment(sourceText: "Queued", state: .translating),
            TranslationSegment(sourceText: "Failed", translatedText: "Error: x", state: .failed),
        ]

        XCTAssertFalse(viewModel.isPaused)
        viewModel.togglePause()
        XCTAssertTrue(viewModel.isPaused)

        XCTAssertEqual(viewModel.segments[0].state, .translated, "Completed segments must be untouched")
        XCTAssertEqual(viewModel.segments[1].state, .pending, "In-flight segment must become pending")
        XCTAssertEqual(viewModel.segments[1].translatedText, "", "Partial streaming output must be discarded")
        XCTAssertEqual(viewModel.segments[2].state, .pending, "Queued segment must become pending")
        XCTAssertEqual(viewModel.segments[3].state, .failed, "Failed segments must be untouched")
    }

    func testResumeReEnqueuesPendingSegments() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = [
            TranslationSegment(sourceText: "Hello world", state: .translating),
        ]

        viewModel.togglePause()
        XCTAssertEqual(viewModel.segments[0].state, .pending)

        viewModel.togglePause()
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(
            viewModel.segments[0].state, .translating,
            "Pending segment must return to translating (re-enqueued) on resume"
        )
    }

    func testNoSegmentLeftPendingAfterResume() {
        let viewModel = TranscriptionViewModel()
        viewModel.segments = (0..<5).map {
            TranslationSegment(sourceText: "Segment \($0)", state: .translating)
        }

        viewModel.togglePause()
        XCTAssertTrue(viewModel.segments.allSatisfy { $0.state == .pending })

        viewModel.togglePause()
        XCTAssertFalse(
            viewModel.segments.contains { $0.state == .pending },
            "No segment may remain pending after resume"
        )
    }
}
