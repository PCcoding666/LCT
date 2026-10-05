import Foundation

/// Outcome of feeding one RMS sample to a `SilenceDetector`.
enum SilenceEvent: Equatable {
    /// Nothing to report.
    case none
    /// The silent streak completed; fires at most once per capture session.
    case silenceDetected
    /// After firing, the lane delivered at least `recoveryDuration` of
    /// continuous audible RMS; reported at most once per capture session.
    case audioResumed
}

/// Pure-logic silence watchdog for a capture lane: fires once per capture
/// session when every buffer's RMS stays below `rmsThreshold` for
/// `requiredDuration` without interruption. A single buffer at or above the
/// threshold resets the streak. After firing, a continuous audible streak of
/// `recoveryDuration` reports `.audioResumed` once, so a recovered input
/// device can retract the warning.
struct SilenceDetector {
    let rmsThreshold: Float
    let requiredDuration: TimeInterval
    let recoveryDuration: TimeInterval

    private var silenceStart: Date?
    private var hasFired = false
    private var recoveryStart: Date?
    private var hasReportedRecovery = false

    init(rmsThreshold: Float = 1e-4, requiredDuration: TimeInterval = 6.0, recoveryDuration: TimeInterval = 1.0) {
        self.rmsThreshold = rmsThreshold
        self.requiredDuration = requiredDuration
        self.recoveryDuration = recoveryDuration
    }

    /// Start a new capture session, allowing the detector to fire (and report
    /// a recovery) once more.
    mutating func reset() {
        silenceStart = nil
        hasFired = false
        recoveryStart = nil
        hasReportedRecovery = false
    }

    /// Feed one buffer's RMS at its arrival time. Returns `.silenceDetected`
    /// exactly once per session: on the first call that completes an
    /// uninterrupted silent streak of `requiredDuration`. After that, returns
    /// `.audioResumed` exactly once: on the first call that completes an
    /// uninterrupted audible streak of `recoveryDuration`.
    mutating func process(rms: Float, at timestamp: Date) -> SilenceEvent {
        guard !hasFired else {
            return processPostFire(rms: rms, at: timestamp)
        }
        guard rms < rmsThreshold else {
            silenceStart = nil
            return .none
        }
        let start = silenceStart ?? timestamp
        silenceStart = start
        guard timestamp.timeIntervalSince(start) >= requiredDuration else { return .none }
        hasFired = true
        return .silenceDetected
    }

    private mutating func processPostFire(rms: Float, at timestamp: Date) -> SilenceEvent {
        guard !hasReportedRecovery else { return .none }
        guard rms >= rmsThreshold else {
            recoveryStart = nil
            return .none
        }
        let start = recoveryStart ?? timestamp
        recoveryStart = start
        guard timestamp.timeIntervalSince(start) >= recoveryDuration else { return .none }
        hasReportedRecovery = true
        return .audioResumed
    }
}
