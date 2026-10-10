import XCTest
import AVFoundation
@testable import LCTMac

/// Tests for `SystemAudioPermissionProbe`, `FirstCallbackLatch`, and
/// `SystemAudioAuthorizationStore`. Every test uses a fake tap — no real tap
/// is ever created, so no TCC prompt can appear.
final class SystemAudioPermissionProbeTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onFirstCallback: (@Sendable () -> Void)?
        var errorToThrow: Error?
        /// When true, start() simulates an authorized tap by reporting the
        /// first IO callback right away (a granted tap calls back even in
        /// silence; a denied one never calls back).
        var deliversCallbacks = false

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
            if let errorToThrow { throw errorToThrow }
            if deliversCallbacks { onFirstCallback?() }
        }

        func stop() {
            lock.lock()
            _stopCallCount += 1
            lock.unlock()
        }
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SystemAudioPermissionProbeTests-\(UUID().uuidString)")!
    }

    // MARK: - Probe

    func testSystemAudioPermissionProbe_CallbackArrives_ReturnsGrantedAndStopsTap() async {
        let tap = FakeSystemAudioTap()
        tap.deliversCallbacks = true
        let defaults = freshDefaults()

        let result = await SystemAudioPermissionProbe.run(makeTap: { tap }, timeout: 5, defaults: defaults)

        XCTAssertEqual(result, .granted)
        XCTAssertEqual(tap.startCallCount, 1)
        XCTAssertEqual(tap.stopCallCount, 1, "the probe must always stop the tap it started")
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .granted)
    }

    func testSystemAudioPermissionProbe_NoCallback_ReturnsDeniedAndStopsTap() async {
        let tap = FakeSystemAudioTap()
        let defaults = freshDefaults()

        let result = await SystemAudioPermissionProbe.run(makeTap: { tap }, timeout: 0.1, defaults: defaults)

        XCTAssertEqual(result, .denied)
        XCTAssertEqual(tap.startCallCount, 2, "a silent tap is rebuilt once before the probe reports denied")
        XCTAssertEqual(tap.stopCallCount, 2, "the probe must stop every tap it started, even when nothing came back")
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .denied)
    }

    /// Real-Mac regression: the tap created while the consent prompt was on
    /// screen stayed silent after the user clicked Allow; a fresh tap worked.
    /// The probe must report granted, not denied.
    func testSystemAudioPermissionProbe_FirstTapSilentSecondDelivers_ReturnsGranted() async {
        let silentTap = FakeSystemAudioTap()
        let workingTap = FakeSystemAudioTap()
        workingTap.deliversCallbacks = true
        let taps = TapSequence([silentTap, workingTap])
        let defaults = freshDefaults()

        let result = await SystemAudioPermissionProbe.run(makeTap: { taps.next() }, timeout: 0.1, defaults: defaults)

        XCTAssertEqual(result, .granted)
        XCTAssertEqual(silentTap.stopCallCount, 1, "the silent tap is stopped before the retry")
        XCTAssertEqual(workingTap.startCallCount, 1)
        XCTAssertEqual(workingTap.stopCallCount, 1)
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .granted)
    }

    /// Hands out fake taps in order (thread-safe; the probe's factory is @Sendable).
    private final class TapSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var taps: [FakeSystemAudioTap]
        init(_ taps: [FakeSystemAudioTap]) { self.taps = taps }
        func next() -> FakeSystemAudioTap {
            lock.lock()
            defer { lock.unlock() }
            return taps.count > 1 ? taps.removeFirst() : taps[0]
        }
    }

    func testSystemAudioPermissionProbe_StartThrows_ReturnsDeniedAndStopsTap() async {
        let tap = FakeSystemAudioTap()
        tap.errorToThrow = SystemAudioTapError(step: "AudioHardwareCreateProcessTap", status: -50)
        let defaults = freshDefaults()

        let result = await SystemAudioPermissionProbe.run(makeTap: { tap }, timeout: 0.1, defaults: defaults)

        XCTAssertEqual(result, .denied, "a tap that cannot be created reports denied — the remediation is the same")
        XCTAssertEqual(tap.stopCallCount, 1)
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .denied)
    }

    // MARK: - Latch

    func testFirstCallbackLatch_FiredBeforeWait_ReturnsTrue() async {
        let latch = FirstCallbackLatch()
        latch.fire()
        let fired = await latch.wait(timeout: 1)
        XCTAssertTrue(fired)
    }

    func testFirstCallbackLatch_NeverFired_TimesOutReturningFalse() async {
        let latch = FirstCallbackLatch()
        let start = Date()
        let fired = await latch.wait(timeout: 0.1)
        XCTAssertFalse(fired)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09, "the wait must actually span the timeout")
    }

    func testFirstCallbackLatch_FiredDuringWait_ReturnsTrueEarly() async {
        let latch = FirstCallbackLatch()
        Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            latch.fire()
        }
        let start = Date()
        let fired = await latch.wait(timeout: 5)
        XCTAssertTrue(fired)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a fired latch must not wait out the full timeout")
    }

    // MARK: - Store

    func testSystemAudioAuthorizationStore_RecordThenRead_ReturnsLastResult() {
        let defaults = freshDefaults()
        XCTAssertNil(SystemAudioAuthorizationStore.lastResult(defaults: defaults), "unknown before the first observation")
        SystemAudioAuthorizationStore.record(.granted, defaults: defaults)
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .granted)
        SystemAudioAuthorizationStore.record(.denied, defaults: defaults)
        XCTAssertEqual(SystemAudioAuthorizationStore.lastResult(defaults: defaults), .denied)
    }
}
