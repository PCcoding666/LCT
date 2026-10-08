import XCTest
@testable import LCTMac

/// Guards the pure SpeechTranscriber→TranscriptionResult mapping: volatile
/// results refine the current segment id, finals close and rotate it, and
/// empty/duplicate results emit nothing.
final class TranscriberResultMapperTests: XCTestCase {

    private func makeMapper() -> TranscriberResultMapper {
        TranscriberResultMapper(segmentId: UUID())
    }

    // MARK: - Volatile results

    func testMapper_VolatileResults_KeepSegmentIdAndMarkVolatile() {
        var mapper = makeMapper()
        let first = mapper.map(text: "hel", isFinal: false, start: 0, end: 0.5, source: .system)
        let second = mapper.map(text: "hello", isFinal: false, start: 0, end: 1.0, source: .system)

        XCTAssertEqual(first?.isVolatile, true)
        XCTAssertEqual(second?.isVolatile, true)
        XCTAssertEqual(first?.id, second?.id,
                       "volatile results refine one utterance and must keep its segment id")
        XCTAssertEqual(second?.text, "hello")
    }

    func testMapper_DuplicateVolatile_ReturnsNil() {
        var mapper = makeMapper()
        let first = mapper.map(text: "hello", isFinal: false, start: 0, end: 1, source: .system)
        let duplicate = mapper.map(text: "hello", isFinal: false, start: 0, end: 1, source: .system)
        let changed = mapper.map(text: "hello world", isFinal: false, start: 0, end: 1.5, source: .system)

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate, "an unchanged volatile result carries no new information")
        XCTAssertEqual(changed?.id, first?.id,
                       "a duplicate must not consume or rotate the segment id")
    }

    func testMapper_EmptyVolatile_ReturnsNilAndKeepsSegmentId() {
        var mapper = makeMapper()
        let initialId = mapper.currentSegmentId

        XCTAssertNil(mapper.map(text: "", isFinal: false, start: 0, end: 1, source: .system))
        XCTAssertEqual(mapper.currentSegmentId, initialId,
                       "an empty volatile result must not rotate the segment id")
    }

    // MARK: - Final results

    func testMapper_FinalResult_EmitsNonVolatileAndRotatesSegmentId() {
        var mapper = makeMapper()
        let volatile = mapper.map(text: "hel", isFinal: false, start: 0, end: 0.5, source: .system)
        let final = mapper.map(text: "hello", isFinal: true, start: 0, end: 1.0, source: .system)
        let nextUtterance = mapper.map(text: "world", isFinal: false, start: 1.5, end: 2.0, source: .system)

        XCTAssertEqual(final?.isVolatile, false)
        XCTAssertEqual(final?.id, volatile?.id,
                       "the final closes the current utterance, so it keeps its id")
        XCTAssertNotEqual(nextUtterance?.id, final?.id,
                          "after a final, the next utterance must start a fresh segment")
    }

    func testMapper_FinalMatchingLastVolatile_StillEmitted() {
        var mapper = makeMapper()
        _ = mapper.map(text: "hello", isFinal: false, start: 0, end: 1, source: .system)
        let final = mapper.map(text: "hello", isFinal: true, start: 0, end: 1, source: .system)

        XCTAssertNotNil(final,
                        "a final equal to the last volatile must still be emitted so the segment commits")
        XCTAssertEqual(final?.isVolatile, false)
    }

    func testMapper_EmptyFinal_ReturnsNilButRotatesSegmentId() {
        var mapper = makeMapper()
        let volatile = mapper.map(text: "hello", isFinal: false, start: 0, end: 1, source: .system)

        XCTAssertNil(mapper.map(text: "", isFinal: true, start: 1, end: 1.5, source: .system),
                     "an empty final has nothing to emit")

        let nextUtterance = mapper.map(text: "world", isFinal: false, start: 2, end: 2.5, source: .system)
        XCTAssertNotEqual(nextUtterance?.id, volatile?.id,
                          "an empty final still ends the utterance, so the id must rotate")
    }

    // MARK: - Passthrough fields

    func testMapper_TimingAndSource_PassedThrough() {
        var mapper = makeMapper()
        let result = mapper.map(text: "hello", isFinal: false, start: 1.25, end: 2.5, source: .microphone)

        XCTAssertEqual(result?.startTime, 1.25)
        XCTAssertEqual(result?.endTime, 2.5)
        XCTAssertEqual(result?.source, .microphone)
    }
}
