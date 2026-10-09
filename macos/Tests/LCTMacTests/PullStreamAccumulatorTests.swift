import XCTest
@testable import LCTMac

final class PullStreamAccumulatorTests: XCTestCase {

    func testIngest_MultiLayerStream_ProgressIsMonotonic() throws {
        var accumulator = PullStreamAccumulator()
        let lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":10}"#,
            #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":50}"#,
            // A second layer appears: the naive fraction would drop to 0.125.
            #"{"status":"downloading","digest":"sha256:bbb","total":300,"completed":0}"#,
            #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":100}"#,
            #"{"status":"downloading","digest":"sha256:bbb","total":300,"completed":150}"#,
            #"{"status":"verifying sha256 digest"}"#,
            #"{"status":"writing manifest"}"#,
            #"{"status":"success"}"#,
        ]

        var previous = 0.0
        for line in lines {
            guard let snapshot = try accumulator.ingest(line: line) else {
                XCTFail("every valid line must produce a snapshot")
                return
            }
            XCTAssertGreaterThanOrEqual(snapshot.overallProgress, previous,
                                        "progress must never decrease (line: \(line))")
            previous = snapshot.overallProgress
        }
        XCTAssertEqual(previous, 1.0)
        XCTAssertNoThrow(try accumulator.finish())
    }

    func testIngest_ByteTotals_SumAcrossLayers() throws {
        var accumulator = PullStreamAccumulator()
        _ = try accumulator.ingest(line: #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":60}"#)
        let snapshot = try XCTUnwrap(
            try accumulator.ingest(line: #"{"status":"downloading","digest":"sha256:bbb","total":300,"completed":150}"#)
        )
        XCTAssertEqual(snapshot.completedBytes, 210)
        XCTAssertEqual(snapshot.totalBytes, 400)
    }

    func testIngest_SameLayerRegressing_KeepsHighestCompleted() throws {
        var accumulator = PullStreamAccumulator()
        _ = try accumulator.ingest(line: #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":80}"#)
        let snapshot = try XCTUnwrap(
            try accumulator.ingest(line: #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":30}"#)
        )
        XCTAssertEqual(snapshot.completedBytes, 80, "a retransmitted stale line must not rewind the layer")
    }

    func testIngest_ErrorLine_ThrowsWithMessage() {
        var accumulator = PullStreamAccumulator()
        XCTAssertThrowsError(
            try accumulator.ingest(line: #"{"error":"pull model manifest: file does not exist"}"#)
        ) { error in
            guard case OllamaModelError.pullFailed(let message) = error else {
                return XCTFail("expected pullFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("file does not exist"), message)
        }
    }

    func testIngest_BlankAndNonJSONLines_AreSkipped() throws {
        var accumulator = PullStreamAccumulator()
        XCTAssertNil(try accumulator.ingest(line: ""))
        XCTAssertNil(try accumulator.ingest(line: "   "))
        XCTAssertNil(try accumulator.ingest(line: "this is not json"))
        XCTAssertNil(try accumulator.ingest(line: #"[1, 2, 3]"#))
    }

    func testIngest_SuccessLine_CompletesAndSetsFullProgress() throws {
        var accumulator = PullStreamAccumulator()
        let snapshot = try XCTUnwrap(try accumulator.ingest(line: #"{"status":"success"}"#))
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.overallProgress, 1.0)
        XCTAssertEqual(snapshot.status, "success")
    }

    func testFinish_WithoutSuccess_ThrowsEndedBeforeCompleting() throws {
        var accumulator = PullStreamAccumulator()
        _ = try accumulator.ingest(line: #"{"status":"downloading","digest":"sha256:aaa","total":100,"completed":100}"#)
        XCTAssertThrowsError(try accumulator.finish()) { error in
            guard case OllamaModelError.pullFailed(let message) = error else {
                return XCTFail("expected pullFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("ended before completing"), message)
        }
    }

    func testFinish_EmptyStream_Throws() {
        let accumulator = PullStreamAccumulator()
        XCTAssertThrowsError(try accumulator.finish())
    }
}
