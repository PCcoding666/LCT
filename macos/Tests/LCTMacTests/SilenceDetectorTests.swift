import XCTest
@testable import LCTMac

/// Tests for SilenceDetector, the mic-lane no-signal watchdog.
final class SilenceDetectorTests: XCTestCase {

    func testSilenceDetector_UnderSixSeconds_DoesNotFire() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {  // 0.0s … 5.9s in 100ms steps
            XCTAssertFalse(
                detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)),
                "must not fire before 6s of continuous silence (t=\(Double(i) * 0.1))"
            )
        }
    }

    func testSilenceDetector_SixSecondsOfSilence_Fires() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {
            XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)))
        }
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)))
    }

    func testSilenceDetector_SoundResetsStreak() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {  // 5.9s of silence
            _ = detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        // Sound at t=6.0 resets the streak just before it would fire.
        XCTAssertFalse(detector.process(rms: 0.5, at: t0.addingTimeInterval(6.0)))
        // Another 5.9s of silence (t=6.0…11.9) still must not fire.
        for i in 60...119 {
            XCTAssertFalse(
                detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)),
                "streak restarted at t=6.0, must not fire at t=\(Double(i) * 0.1)"
            )
        }
        // Completing the new 6s streak fires.
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)))
    }

    func testSilenceDetector_FiresOnlyOncePerSession() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        XCTAssertFalse(detector.process(rms: 1e-5, at: t0))
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)))
        XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.1)))
        XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)))
    }

    func testSilenceDetector_Reset_AllowsFiringAgain() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)))

        detector.reset()

        XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)))
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(18.0)))
    }

    func testSilenceDetector_ThresholdBoundary_NotBelowThresholdCountsAsSound() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        _ = detector.process(rms: 1e-5, at: t0)
        // Exactly at the threshold (1e-4) is not "below" → streak resets.
        XCTAssertFalse(detector.process(rms: 1e-4, at: t0.addingTimeInterval(3.0)))
        // New streak starts at t=3.1; 5.9s later it must not have fired yet.
        XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(3.1)))
        XCTAssertFalse(detector.process(rms: 1e-5, at: t0.addingTimeInterval(9.0)))
        XCTAssertTrue(detector.process(rms: 1e-5, at: t0.addingTimeInterval(9.1)))
    }
}
