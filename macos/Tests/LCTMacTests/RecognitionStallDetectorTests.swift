import XCTest
@testable import LCTMac

/// Tests for RecognitionStallDetector, the "hearing audio but recognizing
/// nothing" watchdog (typically a wrong recognition language).
final class RecognitionStallDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic

    func testRecognitionStall_UnderEightSecondsAudible_DoesNotFire() {
        var detector = RecognitionStallDetector()
        XCTAssertFalse(detector.process(level: 0.5, for: .system, at: t0))
        XCTAssertFalse(
            detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(7.9)),
            "7.9s of accumulated audible time must not fire"
        )
    }

    func testRecognitionStall_EightSecondsAudible_Fires() {
        var detector = RecognitionStallDetector()
        XCTAssertFalse(detector.process(level: 0.5, for: .system, at: t0))
        XCTAssertTrue(
            detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)),
            "8s of accumulated audible time with no result must fire"
        )
    }

    func testRecognitionStall_AccumulatesAcrossManySamples() {
        var detector = RecognitionStallDetector()
        // 0.5s ticks from t=0 to t=7.5 → 7.5s accumulated, still below 8s.
        for i in 0...15 {
            XCTAssertFalse(
                detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(Double(i) * 0.5)),
                "only \(Double(i) * 0.5)s accumulated"
            )
        }
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)))
    }

    func testRecognitionStall_LowLevelDoesNotAccumulate() {
        var detector = RecognitionStallDetector()
        XCTAssertFalse(detector.process(level: 0.1, for: .system, at: t0))
        for i in 1...20 {  // 20s below the 0.25 threshold
            XCTAssertFalse(
                detector.process(level: 0.1, for: .system, at: t0.addingTimeInterval(Double(i))),
                "samples at/below the level threshold must not accumulate"
            )
        }
    }

    func testRecognitionStall_ThresholdBoundary_ExactlyAtThresholdDoesNotCount() {
        var detector = RecognitionStallDetector()
        XCTAssertFalse(detector.process(level: 0.25, for: .system, at: t0))
        XCTAssertFalse(
            detector.process(level: 0.25, for: .system, at: t0.addingTimeInterval(8.0)),
            "level exactly at the threshold is not 'above' and must not accumulate"
        )
    }

    func testRecognitionStall_ResultResetsAccumulation() {
        var detector = RecognitionStallDetector()
        _ = detector.process(level: 0.5, for: .system, at: t0)
        XCTAssertFalse(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(7.0)))

        detector.registerResult(for: .system)

        _ = detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(7.5))
        XCTAssertFalse(
            detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(15.4)),
            "a result resets the lane's accumulation — 7.9s since the result must not fire"
        )
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(15.5)))
    }

    func testRecognitionStall_FiresOnlyOncePerLanePerSession() {
        var detector = RecognitionStallDetector()
        _ = detector.process(level: 0.5, for: .system, at: t0)
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)))

        detector.registerResult(for: .system)
        XCTAssertFalse(
            detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(16.0)),
            "an already-fired lane must never fire again in the same session"
        )
        XCTAssertFalse(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(24.0)))
    }

    func testRecognitionStall_LanesAreIndependent() {
        var detector = RecognitionStallDetector()
        _ = detector.process(level: 0.5, for: .system, at: t0)
        _ = detector.process(level: 0.5, for: .microphone, at: t0)

        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)))
        detector.registerResult(for: .microphone)
        XCTAssertFalse(
            detector.process(level: 0.5, for: .microphone, at: t0.addingTimeInterval(8.0)),
            "the mic lane's accumulation was reset by its own result"
        )
        XCTAssertTrue(
            detector.process(level: 0.5, for: .microphone, at: t0.addingTimeInterval(16.0)),
            "the mic lane fires on its own 8s accumulation"
        )
    }

    func testRecognitionStall_Reset_AllowsFiringAgain() {
        var detector = RecognitionStallDetector()
        _ = detector.process(level: 0.5, for: .system, at: t0)
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)))

        detector.reset()

        XCTAssertFalse(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(9.0)))
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(17.0)))
    }

    func testRecognitionStall_ResetLane_AllowsOnlyThatLaneToFireAgain() {
        var detector = RecognitionStallDetector()
        _ = detector.process(level: 0.5, for: .system, at: t0)
        _ = detector.process(level: 0.5, for: .microphone, at: t0)
        XCTAssertTrue(detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(8.0)))
        XCTAssertTrue(detector.process(level: 0.5, for: .microphone, at: t0.addingTimeInterval(8.0)))

        // A language switch on the mic lane resets only that lane's budget.
        detector.resetLane(.microphone)

        XCTAssertFalse(
            detector.process(level: 0.5, for: .system, at: t0.addingTimeInterval(16.0)),
            "the untouched lane already fired this session and stays fired"
        )
        XCTAssertFalse(
            detector.process(level: 0.5, for: .microphone, at: t0.addingTimeInterval(9.0)),
            "the reset lane accumulates from scratch"
        )
        XCTAssertTrue(
            detector.process(level: 0.5, for: .microphone, at: t0.addingTimeInterval(17.0)),
            "the reset lane may fire once more"
        )
    }
}
