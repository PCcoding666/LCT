import XCTest
@testable import LCTMac

/// Guards the restart decision logic that broke the recognition death loop:
/// stale-generation callbacks are dropped, only the current task's callbacks
/// are processed, the no-speech backoff grows and caps, and a non-empty
/// transcript resets it.
final class RecognitionRestartPolicyTests: XCTestCase {

    // MARK: - Callback validity

    func testShouldProcessCallback_CurrentLaneAndGeneration_ReturnsTrue() {
        XCTAssertTrue(
            RecognitionRestartPolicy.shouldProcessCallback(laneIsCurrent: true, callbackGeneration: 3, currentGeneration: 3),
            "A callback from the lane's current task generation must be processed"
        )
    }

    func testShouldProcessCallback_StaleGeneration_ReturnsFalse() {
        XCTAssertFalse(
            RecognitionRestartPolicy.shouldProcessCallback(laneIsCurrent: true, callbackGeneration: 2, currentGeneration: 3),
            "A callback from a superseded task generation must be dropped"
        )
    }

    func testShouldProcessCallback_RemovedLane_ReturnsFalse() {
        XCTAssertFalse(
            RecognitionRestartPolicy.shouldProcessCallback(laneIsCurrent: false, callbackGeneration: 3, currentGeneration: 3),
            "A callback for a lane that is no longer active must be dropped"
        )
    }

    // MARK: - Backoff sequence

    func testNoSpeechBackoff_ConsecutiveRestarts_DoublesAndCapsAtMax() {
        var policy = RecognitionRestartPolicy()
        let expected: [TimeInterval] = [0.3, 0.6, 1.2, 2.4, 3.0, 3.0, 3.0]
        for (index, want) in expected.enumerated() {
            let got = policy.registerNoSpeechRestart()
            XCTAssertEqual(got, want, accuracy: 0.0001, "backoff step \(index)")
            XCTAssertEqual(policy.consecutiveNoSpeechRestarts, index + 1)
        }
    }

    func testNoSpeechBackoff_NonEmptyTranscript_ResetsToInitial() {
        var policy = RecognitionRestartPolicy()
        _ = policy.registerNoSpeechRestart()
        _ = policy.registerNoSpeechRestart()
        _ = policy.registerNoSpeechRestart()

        policy.noteNonEmptyTranscript()
        XCTAssertEqual(policy.consecutiveNoSpeechRestarts, 0, "a non-empty transcript must reset the backoff counter")

        XCTAssertEqual(policy.registerNoSpeechRestart(), RecognitionRestartPolicy.initialBackoff, accuracy: 0.0001,
                       "after a reset the backoff starts from the initial delay again")
    }

    func testNoSpeechBackoff_InitialState_HasNoRestarts() {
        XCTAssertEqual(RecognitionRestartPolicy().consecutiveNoSpeechRestarts, 0)
    }
}
