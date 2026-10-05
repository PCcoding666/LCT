import Foundation

/// Pure-logic silence watchdog for a capture lane: fires once per capture
/// session when every buffer's RMS stays below `rmsThreshold` for
/// `requiredDuration` without interruption. A single buffer at or above the
/// threshold resets the streak.
struct SilenceDetector {
    let rmsThreshold: Float
    let requiredDuration: TimeInterval

    private var silenceStart: Date?
    private var hasFired = false

    init(rmsThreshold: Float = 1e-4, requiredDuration: TimeInterval = 6.0) {
        self.rmsThreshold = rmsThreshold
        self.requiredDuration = requiredDuration
    }

    /// Start a new capture session, allowing the detector to fire once more.
    mutating func reset() {
        silenceStart = nil
        hasFired = false
    }

    /// Feed one buffer's RMS at its arrival time. Returns true exactly once per
    /// session: on the first call that completes an uninterrupted silent streak
    /// of `requiredDuration`.
    mutating func process(rms: Float, at timestamp: Date) -> Bool {
        guard !hasFired else { return false }
        guard rms < rmsThreshold else {
            silenceStart = nil
            return false
        }
        let start = silenceStart ?? timestamp
        silenceStart = start
        guard timestamp.timeIntervalSince(start) >= requiredDuration else { return false }
        hasFired = true
        return true
    }
}
