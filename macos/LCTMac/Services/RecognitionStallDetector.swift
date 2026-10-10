import Foundation

/// Pure-logic watchdog for a capture lane that is hearing audio but producing
/// no speech-recognition results — typically a wrong recognition language.
///
/// Fed with meter-level samples (0…1, -60…0 dB normalized) per lane. Time
/// between consecutive samples accumulates while the level is above
/// `levelThreshold`; when a lane's accumulated audible time reaches
/// `requiredAudibleDuration` without any recognition result on that lane, the
/// detector fires once. A result resets the lane's accumulation. Each lane
/// fires at most once per session (`reset()` starts a new session).
struct RecognitionStallDetector {
    /// Meter level above which a sample interval counts as audible (~-45 dB).
    let levelThreshold: Float
    /// Accumulated audible seconds with zero results that triggers a stall.
    let requiredAudibleDuration: TimeInterval

    private struct LaneState {
        var audibleSeconds: TimeInterval = 0
        var lastSampleAt: Date?
        var hasFired = false
    }
    private var lanes: [AudioSource: LaneState] = [:]

    init(levelThreshold: Float = 0.25, requiredAudibleDuration: TimeInterval = 8.0) {
        self.levelThreshold = levelThreshold
        self.requiredAudibleDuration = requiredAudibleDuration
    }

    /// Start a new capture session, allowing every lane to fire once more.
    mutating func reset() {
        lanes.removeAll()
    }

    /// Give one lane a fresh stall budget (e.g. after its recognition language
    /// changed): its accumulation clears and it may fire once more.
    mutating func resetLane(_ source: AudioSource) {
        lanes[source] = nil
    }

    /// Feed one meter-level sample for a lane at its sampling time. Returns
    /// true exactly once per lane per session: on the first sample that pushes
    /// the lane's accumulated audible time to `requiredAudibleDuration`.
    mutating func process(level: Float, for source: AudioSource, at timestamp: Date) -> Bool {
        var state = lanes[source] ?? LaneState()
        defer { lanes[source] = state }

        if let last = state.lastSampleAt {
            let interval = timestamp.timeIntervalSince(last)
            if interval > 0, level > levelThreshold {
                state.audibleSeconds += interval
            }
        }
        state.lastSampleAt = timestamp

        guard !state.hasFired, state.audibleSeconds >= requiredAudibleDuration else { return false }
        state.hasFired = true
        return true
    }

    /// Notify that the lane produced a recognition result; its audible-time
    /// accumulation starts over from the next sample (an already-fired lane
    /// stays fired).
    mutating func registerResult(for source: AudioSource) {
        lanes[source]?.audibleSeconds = 0
        lanes[source]?.lastSampleAt = nil
    }
}
