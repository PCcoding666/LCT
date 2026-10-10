import Foundation

/// The observed system-audio authorization verdict. macOS has no preflight
/// API for the Core Audio tap's TCC consent: a denied tap reports success on
/// every setup step and simply never delivers an IO callback, while an
/// authorized tap calls back continuously — even when the system is silent.
enum SystemAudioAuthorization: String, Equatable {
    case granted
    case denied
}

/// Thread-safe one-shot flag for "the tap delivered its first IO callback".
/// Shared by the capture-time watchdog and the onboarding probe.
final class FirstCallbackLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    func fire() {
        lock.lock()
        hasFired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasFired
    }

    /// Poll until fired, the timeout passes, or the task is cancelled.
    /// Returns whether the latch fired in time.
    func wait(timeout: TimeInterval, pollInterval: TimeInterval = 0.01) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !fired, !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return fired
    }
}

/// Last observed system-audio authorization verdict, persisted so the
/// diagnostics report can state it across relaunches. Status only.
enum SystemAudioAuthorizationStore {
    static let key = "systemAudioAuthorizationResult"

    static func record(_ result: SystemAudioAuthorization, defaults: UserDefaults = .standard) {
        defaults.set(result.rawValue, forKey: key)
    }

    static func lastResult(defaults: UserDefaults = .standard) -> SystemAudioAuthorization? {
        defaults.string(forKey: key).flatMap(SystemAudioAuthorization.init(rawValue:))
    }
}

/// Probes the system-audio authorization once by starting a tap and watching
/// for its first IO callback. Used by onboarding (and any future settings
/// page) so the user meets the TCC prompt there instead of mid-capture.
///
/// `start()` blocks for as long as the system prompt is on screen — callers
/// must keep this off the main thread.
enum SystemAudioPermissionProbe {
    /// Start a fresh tap, wait up to `timeout` (counted from `start()`
    /// returning) for the first IO callback, then always stop the tap.
    /// A tap that cannot even be created reports `.denied` — the user-facing
    /// remediation (the Settings pane) is the same either way.
    static func run(
        makeTap: @Sendable () -> any SystemAudioTapping = { SystemAudioTap() },
        timeout: TimeInterval = 3.0,
        defaults: UserDefaults = .standard
    ) async -> SystemAudioAuthorization {
        let tap = makeTap()
        let latch = FirstCallbackLatch()
        tap.onFirstCallback = { latch.fire() }
        do {
            try tap.start()
        } catch {
            appLog("[SystemAudioPermissionProbe] ⚠️ Tap could not start (\(error)); reporting denied")
            tap.stop()
            SystemAudioAuthorizationStore.record(.denied, defaults: defaults)
            return .denied
        }
        let fired = await latch.wait(timeout: timeout)
        tap.stop()
        let result: SystemAudioAuthorization = fired ? .granted : .denied
        appLog("[SystemAudioPermissionProbe] Probe result: \(result.rawValue)")
        SystemAudioAuthorizationStore.record(result, defaults: defaults)
        return result
    }
}
