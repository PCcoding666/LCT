import Foundation

/// Pure decision logic for the capture-time Ollama patrol. The view model
/// feeds it each probe's outcome and executes the returned step; the
/// controller owns only the restart bookkeeping (backoff, attempt cap,
/// recovery transitions) so it can be unit-tested without any network.
struct OllamaRecoveryController: Equatable {

    /// What the latest probe saw.
    enum ProbeOutcome: Equatable {
        /// Service reachable and the translation model is in memory.
        case healthy
        /// Service did not answer at all.
        case serviceUnreachable
        /// Service answers but the translation model is not loaded.
        case modelNotLoaded
    }

    /// What the patrol should do next.
    enum Step: Equatable {
        /// All good — keep probing on the normal interval.
        case probeAgain
        /// Wait `delay` seconds, then restart the service (attempt N of 3).
        case restartService(delay: TimeInterval, attempt: Int)
        /// Service is back after a restart sequence (or a give-up) — tell the
        /// user translation resumed.
        case announceRecovered
        /// The model fell out of memory — prewarm it again.
        case reloadModel
        /// Three restarts in a row failed — stop retrying, surface an error.
        /// The patrol keeps probing passively so a manual restart still leads
        /// to `announceRecovered`.
        case giveUp
    }

    static let maxRestartAttempts = 3

    private let baseBackoff: TimeInterval
    /// Restarts attempted in the current outage streak.
    private(set) var restartAttempts = 0
    /// True while an outage is being worked through (drives the recovered
    /// announcement when health returns).
    private(set) var isRecovering = false
    /// True after three failed restarts — no more automatic restarts.
    private(set) var gaveUp = false

    init(baseBackoff: TimeInterval = 10) {
        self.baseBackoff = baseBackoff
    }

    /// 10s → 20s → 40s for attempts 1…3.
    func backoff(forAttempt attempt: Int) -> TimeInterval {
        baseBackoff * pow(2, Double(max(attempt - 1, 0)))
    }

    mutating func step(for outcome: ProbeOutcome) -> Step {
        switch outcome {
        case .serviceUnreachable:
            guard !gaveUp else { return .probeAgain }
            if restartAttempts >= Self.maxRestartAttempts {
                gaveUp = true
                return .giveUp
            }
            restartAttempts += 1
            isRecovering = true
            return .restartService(delay: backoff(forAttempt: restartAttempts), attempt: restartAttempts)
        case .modelNotLoaded:
            return .reloadModel
        case .healthy:
            let wasRecovering = isRecovering || gaveUp
            restartAttempts = 0
            isRecovering = false
            gaveUp = false
            return wasRecovering ? .announceRecovered : .probeAgain
        }
    }
}
