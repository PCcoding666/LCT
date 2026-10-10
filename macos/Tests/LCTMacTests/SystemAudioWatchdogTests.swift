import XCTest
import AVFoundation
@testable import LCTMac

/// Service-level tests for the first-callback watchdog: a Core Audio tap that
/// delivers no IO callback within the authorization window means macOS
/// withheld the system-audio consent — the lane must be torn down without
/// ever touching the ScreenCaptureKit fallback. All tests use a fake tap and
/// a fraction-of-a-second window; no real tap, no TCC.
@MainActor
final class SystemAudioWatchdogTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onFirstCallback: (@Sendable () -> Void)?

        private let lock = NSLock()
        private var _startCallCount = 0
        private var _stopCallCount = 0

        var startCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _startCallCount
        }

        var stopCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _stopCallCount
        }

        func start() throws {
            lock.lock()
            _startCallCount += 1
            lock.unlock()
        }

        func stop() {
            lock.lock()
            _stopCallCount += 1
            lock.unlock()
        }
    }

    private func makeService(
        tap: FakeSystemAudioTap,
        timeout: TimeInterval,
        onDenied: (@MainActor (Bool) -> Void)? = nil
    ) -> AudioCaptureService {
        makeService(makeTap: { tap }, timeout: timeout, onDenied: onDenied)
    }

    private func makeService(
        makeTap: @escaping () -> any SystemAudioTapping,
        timeout: TimeInterval,
        onDenied: (@MainActor (Bool) -> Void)? = nil
    ) -> AudioCaptureService {
        let service = AudioCaptureService(
            makeSystemAudioTap: makeTap,
            screenPermissionChecker: {
                XCTFail("a silent tap is a denial, not a setup failure — the ScreenCaptureKit fallback must stay untouched")
                return false
            },
            screenCaptureStreamStarter: {
                XCTFail("a silent tap is a denial, not a setup failure — the ScreenCaptureKit fallback must stay untouched")
            },
            systemAudioAuthorizationTimeout: timeout
        )
        service.onSystemAudioAuthorizationDenied = onDenied
        return service
    }

    // MARK: - Watchdog verdicts

    /// An authorized tap calls back promptly: the watchdog stays quiet, the
    /// lane keeps running, and only the user's stop tears the tap down.
    func testSystemAudioWatchdog_FirstCallbackWithinWindow_KeepsLaneRunning() async throws {
        let tap = FakeSystemAudioTap()
        var denialReports: [Bool] = []
        let service = makeService(tap: tap, timeout: 0.2, onDenied: { denialReports.append($0) })

        try await service.startCapture()
        tap.onFirstCallback?()

        // Give the watchdog's window ample time to expire.
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(denialReports.isEmpty, "a tap that called back must not be reported as denied")
        XCTAssertFalse(service.systemAudioAuthorizationDenied)
        XCTAssertEqual(service.systemAudioBackend, .coreAudioTap)
        XCTAssertEqual(tap.stopCallCount, 0, "an authorized tap must keep running")
        let laneActive = await waitForCondition { service.activeSources == [.system] }
        XCTAssertTrue(laneActive)

        await service.stopCapture()
        XCTAssertEqual(tap.stopCallCount, 1)
    }

    /// No callback within the window: denial. The tap is stopped and dropped,
    /// the fallback is never consulted, capture ends (system-only session),
    /// and the ViewModel callback fires with captureContinues == false.
    func testSystemAudioWatchdog_NoCallback_DeniesStopsTapWithoutFallback() async throws {
        let tap = FakeSystemAudioTap()
        var denialReports: [Bool] = []
        let service = makeService(tap: tap, timeout: 0.1, onDenied: { denialReports.append($0) })

        try await service.startCapture()
        XCTAssertEqual(service.systemAudioBackend, .coreAudioTap)

        let denialReported = await waitForCondition { denialReports.count == 1 }
        XCTAssertTrue(denialReported, "the denial must reach the ViewModel callback")
        XCTAssertEqual(tap.startCallCount, 2, "a silent tap is rebuilt once before it counts as denied")
        XCTAssertEqual(tap.stopCallCount, 2, "both silent taps must be stopped")

        // The MainActor denial block ran (it fired the callback), so its
        // state updates are already visible.
        XCTAssertEqual(denialReports, [false], "a system-only session does not continue capturing")
        XCTAssertTrue(service.systemAudioAuthorizationDenied)
        XCTAssertEqual(service.systemAudioBackend, .none)
        XCTAssertEqual(service.activeSources, [])
        XCTAssertFalse(service.isCapturing)
    }

    /// Real-Mac regression: a tap created while the consent prompt was on
    /// screen stayed silent after the user clicked Allow; a fresh tap worked.
    /// The watchdog must rebuild the tap instead of reporting a denial.
    func testSystemAudioWatchdog_FirstTapSilentRebuiltTapDelivers_NoDenial() async throws {
        let silentTap = FakeSystemAudioTap()
        let workingTap = FakeSystemAudioTap()
        var handedOut = 0
        var denialReports: [Bool] = []
        let service = makeService(
            makeTap: {
                handedOut += 1
                return handedOut == 1 ? silentTap : workingTap
            },
            timeout: 0.1,
            onDenied: { denialReports.append($0) }
        )

        try await service.startCapture()

        let rebuilt = await waitForCondition { workingTap.startCallCount == 1 }
        XCTAssertTrue(rebuilt, "the silent tap must be replaced by a fresh one")
        XCTAssertEqual(silentTap.stopCallCount, 1, "the silent tap is stopped before the rebuild")
        workingTap.onFirstCallback?()

        // Let the second window expire.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(denialReports.isEmpty, "a rebuilt tap that calls back must not be reported as denied")
        XCTAssertFalse(service.systemAudioAuthorizationDenied)
        XCTAssertEqual(service.systemAudioBackend, .coreAudioTap)
        XCTAssertEqual(workingTap.stopCallCount, 0, "the working tap keeps running")

        await service.stopCapture()
        XCTAssertEqual(workingTap.stopCallCount, 1)
    }

    /// A stop that lands before the window expires cancels the watchdog:
    /// the tap is stopped exactly once and no denial is reported.
    func testSystemAudioWatchdog_StopBeforeTimeout_WatchdogStaysOut() async throws {
        let tap = FakeSystemAudioTap()
        var denialReports: [Bool] = []
        let service = makeService(tap: tap, timeout: 0.1, onDenied: { denialReports.append($0) })

        try await service.startCapture()
        await service.stopCapture()

        // Well past the window: a leaked watchdog would have fired by now.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(tap.stopCallCount, 1, "only the user's stop may tear the tap down")
        XCTAssertTrue(denialReports.isEmpty)
        XCTAssertFalse(service.systemAudioAuthorizationDenied)
        XCTAssertEqual(service.systemAudioBackend, .none)
    }
}
