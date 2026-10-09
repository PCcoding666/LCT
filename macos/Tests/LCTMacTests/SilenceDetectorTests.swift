import XCTest
@testable import LCTMac

/// Tests for SilenceDetector, the mic-lane no-signal watchdog.
final class SilenceDetectorTests: XCTestCase {

    func testSilenceDetector_UnderSixSeconds_DoesNotFire() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {  // 0.0s … 5.9s in 100ms steps
            XCTAssertEqual(
                detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)),
                .none,
                "must not fire before 6s of continuous silence (t=\(Double(i) * 0.1))"
            )
        }
    }

    func testSilenceDetector_SixSecondsOfSilence_Fires() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {
            XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)), .none)
        }
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)
    }

    func testSilenceDetector_SoundResetsStreak() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        for i in 0...59 {  // 5.9s of silence
            _ = detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        // Sound at t=6.0 resets the streak just before it would fire.
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(6.0)), .none)
        // Another 5.9s of silence (t=6.0…11.9) still must not fire.
        for i in 60...119 {
            XCTAssertEqual(
                detector.process(rms: 1e-5, at: t0.addingTimeInterval(Double(i) * 0.1)),
                .none,
                "streak restarted at t=6.0, must not fire at t=\(Double(i) * 0.1)"
            )
        }
        // Completing the new 6s streak fires.
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)), .silenceDetected)
    }

    func testSilenceDetector_FiresOnlyOncePerSession() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.1)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)), .none)
    }

    func testSilenceDetector_Reset_AllowsFiringAgain() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)

        detector.reset()

        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(12.0)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(18.0)), .silenceDetected)
    }

    func testSilenceDetector_ThresholdBoundary_NotBelowThresholdCountsAsSound() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // integer epoch: exact double arithmetic at the 6.0s boundary
        _ = detector.process(rms: 1e-5, at: t0)
        // Exactly at the threshold (1e-4) is not "below" → streak resets.
        XCTAssertEqual(detector.process(rms: 1e-4, at: t0.addingTimeInterval(3.0)), .none)
        // New streak starts at t=3.1; 5.9s later it must not have fired yet.
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(3.1)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(9.0)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(9.1)), .silenceDetected)
    }

    // MARK: - Recovery reporting

    func testRecovery_OneSecondOfSoundAfterFiring_ReportsAudioResumed() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)

        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(6.5)), .none)
        XCTAssertEqual(
            detector.process(rms: 0.5, at: t0.addingTimeInterval(7.5)),
            .audioResumed,
            "1s of continuous audible RMS after firing must report recovery"
        )
    }

    func testRecovery_UnderOneSecondOfSound_DoesNotReport() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)

        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(6.5)), .none)
        XCTAssertEqual(
            detector.process(rms: 0.5, at: t0.addingTimeInterval(7.4)),
            .none,
            "0.9s of audible RMS is not enough to report recovery"
        )
    }

    func testRecovery_SilenceDipResetsRecoveryStreak() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)

        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(6.5)), .none)
        // A dip back below the threshold restarts the recovery streak.
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(7.0)), .none)
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(7.5)), .none)
        XCTAssertEqual(
            detector.process(rms: 0.5, at: t0.addingTimeInterval(7.9)),
            .none,
            "only 0.4s of audible RMS since the dip — no recovery yet"
        )
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(8.5)), .audioResumed)
    }

    func testRecovery_ReportsOnlyOnce() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = detector.process(rms: 1e-5, at: t0)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0)), .silenceDetected)
        _ = detector.process(rms: 0.5, at: t0.addingTimeInterval(6.5))
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(7.5)), .audioResumed)

        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(8.5)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(9.0)), .none)
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(10.5)), .none)
    }

    func testRecovery_WithoutPriorSilenceDetection_NeverReports() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0...30 {  // 3s of continuous loud audio, detector never fired
            XCTAssertEqual(
                detector.process(rms: 0.5, at: t0.addingTimeInterval(Double(i) * 0.1)),
                .none,
                "audioResumed requires a prior silenceDetected"
            )
        }
    }

    func testRecovery_Reset_AllowsReportingAgain() {
        var detector = SilenceDetector()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = detector.process(rms: 1e-5, at: t0)
        _ = detector.process(rms: 1e-5, at: t0.addingTimeInterval(6.0))
        _ = detector.process(rms: 0.5, at: t0.addingTimeInterval(6.5))
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(7.5)), .audioResumed)

        detector.reset()

        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(8.0)), .none)
        XCTAssertEqual(detector.process(rms: 1e-5, at: t0.addingTimeInterval(14.0)), .silenceDetected)
        _ = detector.process(rms: 0.5, at: t0.addingTimeInterval(14.5))
        XCTAssertEqual(detector.process(rms: 0.5, at: t0.addingTimeInterval(15.5)), .audioResumed)
    }
}
