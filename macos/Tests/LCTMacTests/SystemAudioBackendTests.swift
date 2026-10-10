import XCTest
import AVFoundation
@testable import LCTMac

/// Service-level tests for the Core Audio tap → ScreenCaptureKit fallback
/// decision in `AudioCaptureService`. All tests use a fake tap and stubbed
/// permission/stream closures: no real tap is created, no TCC prompt fires.
@MainActor
final class SystemAudioBackendTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var errorToThrow: Error?

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
        }

        func stop() {
            lock.lock()
            _stopCallCount += 1
            lock.unlock()
        }
    }

    private final class BufferRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [(AVAudioPCMBuffer, AudioSource)] = []

        var entries: [(AVAudioPCMBuffer, AudioSource)] {
            lock.lock()
            defer { lock.unlock() }
            return _entries
        }

        func append(_ buffer: AVAudioPCMBuffer, _ source: AudioSource) {
            lock.lock()
            _entries.append((buffer, source))
            lock.unlock()
        }
    }

    private static let tapError = SystemAudioTapError(step: "AudioHardwareCreateProcessTap", status: -50)

    // MARK: - Backend selection

    func testStartCapture_TapSucceeds_UsesCoreAudioTapWithoutScreenPermissionCheck() async throws {
        let tap = FakeSystemAudioTap()
        let service = AudioCaptureService(
            makeSystemAudioTap: { tap },
            screenPermissionChecker: {
                XCTFail("screen permission must not be checked while the tap works")
                return false
            },
            screenCaptureStreamStarter: {
                XCTFail("ScreenCaptureKit must not start while the tap works")
            }
        )

        try await service.startCapture()

        XCTAssertEqual(service.systemAudioBackend, .coreAudioTap)
        XCTAssertNil(service.systemAudioTapFailure)
        XCTAssertEqual(tap.startCallCount, 1)
        let systemLaneActive = await waitForCondition { service.activeSources == [.system] }
        XCTAssertTrue(systemLaneActive)

        await service.stopCapture()
    }

    func testStartCapture_TapFailsWithScreenPermission_FallsBackToScreenCaptureKit() async throws {
        let tap = FakeSystemAudioTap()
        tap.errorToThrow = Self.tapError

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return _value
            }
            func increment() {
                lock.lock()
                _value += 1
                lock.unlock()
            }
        }
        let checkerCalls = Counter()
        let starterCalls = Counter()

        let service = AudioCaptureService(
            makeSystemAudioTap: { tap },
            screenPermissionChecker: {
                checkerCalls.increment()
                return true
            },
            screenCaptureStreamStarter: {
                starterCalls.increment()
            }
        )

        try await service.startCapture()

        XCTAssertEqual(service.systemAudioBackend, .screenCaptureKit)
        XCTAssertEqual(service.systemAudioTapFailure, "AudioHardwareCreateProcessTap (OSStatus -50)")
        XCTAssertEqual(checkerCalls.value, 1, "the fallback path checks the screen permission exactly once")
        XCTAssertEqual(starterCalls.value, 1)
        XCTAssertEqual(tap.startCallCount, 1)

        await service.stopCapture()
    }

    func testStartCapture_TapFailsWithoutScreenPermission_ThrowsNoPermission() async {
        let tap = FakeSystemAudioTap()
        tap.errorToThrow = Self.tapError

        let service = AudioCaptureService(
            makeSystemAudioTap: { tap },
            screenPermissionChecker: { false },
            screenCaptureStreamStarter: {
                XCTFail("ScreenCaptureKit must not start without the screen permission")
            }
        )

        do {
            try await service.startCapture()
            XCTFail("expected AudioCaptureError.noPermission")
        } catch let error as AudioCaptureError {
            guard case .noPermission = error else {
                return XCTFail("expected .noPermission, got \(error)")
            }
        } catch {
            XCTFail("expected AudioCaptureError.noPermission, got \(error)")
        }

        XCTAssertEqual(service.systemAudioBackend, .none)
        XCTAssertNil(service.systemAudioTapFailure)
    }

    // MARK: - Stop

    func testStopCapture_StopsTapExactlyOnce() async throws {
        let tap = FakeSystemAudioTap()
        let service = AudioCaptureService(makeSystemAudioTap: { tap })

        try await service.startCapture()
        await service.stopCapture()

        XCTAssertEqual(tap.stopCallCount, 1)
        XCTAssertEqual(service.systemAudioBackend, .none)
        XCTAssertNil(service.systemAudioTapFailure)

        await service.stopCapture()
        XCTAssertEqual(tap.stopCallCount, 1, "a second stopCapture must not touch the already-destroyed tap")
    }

    // MARK: - Buffer delivery

    func testTapBuffer_ReachesSystemLaneCallback() async throws {
        let tap = FakeSystemAudioTap()
        let service = AudioCaptureService(makeSystemAudioTap: { tap })
        let recorder = BufferRecorder()
        service.onAudioBuffer = { buffer, source in
            recorder.append(buffer, source)
        }

        try await service.startCapture()

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        tap.onAudioBuffer?(buffer)

        let delivered = await waitForCondition { recorder.entries.count == 1 }
        XCTAssertTrue(delivered)
        XCTAssertEqual(recorder.entries.first?.1, .system)

        await service.stopCapture()
    }
}
