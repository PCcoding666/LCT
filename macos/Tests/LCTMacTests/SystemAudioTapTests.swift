import XCTest
import AVFoundation
import AudioToolbox
import CoreAudio
@testable import LCTMac

/// Converter and lifecycle tests for `SystemAudioTap`. Lifecycle tests use a fake
/// `SystemAudioTapHardware`; they never create a real Core Audio tap.
final class SystemAudioTapTests: XCTestCase {

    // MARK: - Fake hardware

    /// Records every hardware call in order and can inject a per-step failure
    /// status. IDs are fabricated; no real audio objects are created.
    private final class FakeSystemAudioTapHardware: SystemAudioTapHardware, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedCalls: [String] = []
        /// Step name -> status to return instead of noErr.
        var statuses: [String: OSStatus] = [:]

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCalls
        }

        private func record(_ step: String) -> OSStatus {
            lock.lock()
            recordedCalls.append(step)
            let status = statuses[step] ?? noErr
            lock.unlock()
            return status
        }

        /// Matches the measured spike result: 48 kHz, 2 ch, 32-bit float, flags 9.
        static let tapASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 9,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        func translatePIDToProcessObject(_ pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID) {
            (record("translatePIDToProcessObject"), 100)
        }

        func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
            (record("createProcessTap"), 101)
        }

        func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, asbd: AudioStreamBasicDescription) {
            (record("tapFormat"), Self.tapASBD)
        }

        func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioObjectID) {
            (record("createAggregateDevice"), 102)
        }

        /// AudioDeviceIOProcID is a C function-pointer type; a non-capturing
        /// closure gives the fake a valid-looking, never-called proc ID.
        private let fakeIOProcID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }

        /// The block handed to `createIOProc`, so tests can play Core Audio
        /// and invoke the tap's IO callback themselves.
        private(set) var capturedIOBlock: AudioDeviceIOBlock?

        func createIOProc(deviceID: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) -> (status: OSStatus, procID: AudioDeviceIOProcID?) {
            let status = record("createIOProc")
            lock.lock()
            capturedIOBlock = block
            lock.unlock()
            return (status, status == noErr ? fakeIOProcID : nil)
        }

        func startDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus {
            record("startDevice")
        }

        func stopDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus {
            record("stopDevice")
        }

        func destroyIOProc(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID) -> OSStatus {
            record("destroyIOProc")
        }

        func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
            record("destroyAggregateDevice")
        }

        func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
            record("destroyProcessTap")
        }
    }

    // MARK: - Lifecycle

    func testSystemAudioTap_Start_InvokesStepsInOrder() {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertNoThrow(try tap.start())
        XCTAssertEqual(hardware.calls, [
            "translatePIDToProcessObject",
            "createProcessTap",
            "tapFormat",
            "createAggregateDevice",
            "createIOProc",
            "startDevice",
        ])
        tap.stop()
    }

    func testSystemAudioTap_StartTwice_SecondIsNoOp() {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertNoThrow(try tap.start())
        XCTAssertNoThrow(try tap.start())
        XCTAssertEqual(hardware.calls.filter { $0 == "createProcessTap" }.count, 1)
        tap.stop()
    }

    func testSystemAudioTap_StartStepFails_ThrowsStepAndStatusAndCleansUp() {
        let hardware = FakeSystemAudioTapHardware()
        hardware.statuses["createAggregateDevice"] = -50
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertThrowsError(try tap.start()) { error in
            guard let tapError = error as? SystemAudioTapError else {
                return XCTFail("expected SystemAudioTapError, got \(error)")
            }
            XCTAssertEqual(tapError.step, "AudioHardwareCreateAggregateDevice")
            XCTAssertEqual(tapError.status, -50)
            XCTAssertEqual(tapError.description, "AudioHardwareCreateAggregateDevice (OSStatus -50)")
        }
        XCTAssertEqual(hardware.calls, [
            "translatePIDToProcessObject",
            "createProcessTap",
            "tapFormat",
            "createAggregateDevice",
            "destroyProcessTap",
        ])

        // The tap is fully reset, so a later start can succeed.
        hardware.statuses.removeAll()
        XCTAssertNoThrow(try tap.start())
        tap.stop()
    }

    func testSystemAudioTap_Stop_DestroysInOrder() {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertNoThrow(try tap.start())
        tap.stop()
        XCTAssertEqual(hardware.calls, [
            "translatePIDToProcessObject",
            "createProcessTap",
            "tapFormat",
            "createAggregateDevice",
            "createIOProc",
            "startDevice",
            "stopDevice",
            "destroyIOProc",
            "destroyAggregateDevice",
            "destroyProcessTap",
        ])
    }

    func testSystemAudioTap_StopTwice_SecondIsNoOp() {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertNoThrow(try tap.start())
        tap.stop()
        tap.stop()
        XCTAssertEqual(hardware.calls.filter { $0 == "destroyProcessTap" }.count, 1)
    }

    func testSystemAudioTap_StopWithFailingStep_ContinuesCleanup() {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        XCTAssertNoThrow(try tap.start())
        hardware.statuses["stopDevice"] = -1
        hardware.statuses["destroyIOProc"] = -1
        tap.stop()
        XCTAssertEqual(hardware.calls, [
            "translatePIDToProcessObject",
            "createProcessTap",
            "tapFormat",
            "createAggregateDevice",
            "createIOProc",
            "startDevice",
            "stopDevice",
            "destroyIOProc",
            "destroyAggregateDevice",
            "destroyProcessTap",
        ])
    }

    // MARK: - First callback

    /// A lock-guarded counter for the @Sendable tap callbacks.
    private final class CallbackCounter: @unchecked Sendable {
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

    /// The first-callback signal — the watchdog's "authorized" proof — must
    /// fire exactly once, on the first IO callback, while every buffer still
    /// reaches the audio handler.
    func testSystemAudioTap_IOCallback_FiresFirstCallbackOnceAndDeliversEveryBuffer() throws {
        let hardware = FakeSystemAudioTapHardware()
        let tap = SystemAudioTap(hardware: hardware)
        let firstCallbacks = CallbackCounter()
        let buffers = CallbackCounter()
        tap.onFirstCallback = { firstCallbacks.increment() }
        tap.onAudioBuffer = { _ in buffers.increment() }
        try tap.start()

        let block = try XCTUnwrap(hardware.capturedIOBlock, "test setup: the IO block must be captured")
        let (bufferList, cleanup) = makeSineBufferList(frameCount: 480, interleaved: true)
        defer { cleanup() }
        var timestamp = AudioTimeStamp()
        let outputList = UnsafeMutablePointer(mutating: bufferList)
        block(&timestamp, bufferList, &timestamp, outputList, &timestamp)
        block(&timestamp, bufferList, &timestamp, outputList, &timestamp)

        XCTAssertEqual(firstCallbacks.value, 1, "onFirstCallback is one-shot, no matter how many IO callbacks follow")
        XCTAssertEqual(buffers.value, 2, "every IO callback still delivers its buffer")
        tap.stop()
    }

    // MARK: - Format conversion

    /// Same stream as the measured tap layout, but non-interleaved: one
    /// buffer per channel, so per-buffer sizes describe a single channel.
    private static let nonInterleavedASBD = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: 9 | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 32,
        mReserved: 0
    )

    private func makeConverter(asbd: AudioStreamBasicDescription) -> SystemAudioTapConverter {
        guard let converter = SystemAudioTapConverter(
            asbd: asbd,
            targetSampleRate: 16_000,
            targetChannels: 1
        ) else {
            fatalError("converter must accept the tap format")
        }
        return converter
    }

    /// Builds a 48 kHz stereo Float32 buffer list filled with a 440 Hz sine.
    /// `interleaved` mirrors the measured tap layout (flags 9, one buffer); the
    /// non-interleaved variant uses one buffer per channel.
    private func makeSineBufferList(frameCount: Int, interleaved: Bool) -> (UnsafePointer<AudioBufferList>, () -> Void) {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            let sample = sinf(2 * .pi * 440 * Float(frame) / 48_000) * 0.5
            left[frame] = sample
            right[frame] = sample * 0.8
        }

        let bufferCount = interleaved ? 1 : 2
        let byteCount = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(bufferCount)
        let buffers = UnsafeMutableAudioBufferListPointer(list)

        let dataByteSize = UInt32(frameCount * (interleaved ? 2 : 1) * MemoryLayout<Float>.size)
        if interleaved {
            let data = UnsafeMutableRawPointer.allocate(byteCount: Int(dataByteSize), alignment: MemoryLayout<Float>.alignment)
                .bindMemory(to: Float.self, capacity: frameCount * 2)
            for frame in 0..<frameCount {
                data[frame * 2] = left[frame]
                data[frame * 2 + 1] = right[frame]
            }
            buffers[0] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: dataByteSize,
                mData: UnsafeMutableRawPointer(data)
            )
        } else {
            for (index, channel) in [left, right].enumerated() {
                let data = UnsafeMutableRawPointer.allocate(byteCount: Int(dataByteSize), alignment: MemoryLayout<Float>.alignment)
                    .bindMemory(to: Float.self, capacity: frameCount)
                data.update(from: channel, count: frameCount)
                buffers[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: dataByteSize,
                    mData: UnsafeMutableRawPointer(data)
                )
            }
        }

        let cleanup = {
            for index in 0..<bufferCount { free(buffers[index].mData) }
            raw.deallocate()
        }
        return (UnsafePointer(list), cleanup)
    }

    private func assertConvertsToMono16k(
        asbd: AudioStreamBasicDescription,
        interleaved: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let converter = makeConverter(asbd: asbd)
        let (bufferList, cleanup) = makeSineBufferList(frameCount: 4800, interleaved: interleaved)
        defer { cleanup() }

        // First call: the sample-rate converter primes its filter, but the
        // format contract and signal level already hold.
        guard let first = converter.convert(bufferList) else {
            return XCTFail("converter produced no output", file: file, line: line)
        }
        XCTAssertEqual(first.format.sampleRate, 16_000, file: file, line: line)
        XCTAssertEqual(first.format.channelCount, 1, file: file, line: line)
        XCTAssertGreaterThan(rms(first), 0.05, "converted audio must carry the sine, not silence", file: file, line: line)

        // Steady state — what the live tap sees: ~1/3 of the input frames.
        guard let second = converter.convert(bufferList) else {
            return XCTFail("converter produced no output on the second buffer", file: file, line: line)
        }
        XCTAssertEqual(Double(second.frameLength), 1600, accuracy: 20, file: file, line: line)
        XCTAssertGreaterThan(rms(second), 0.05, file: file, line: line)
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[0][i] * data[0][i]
        }
        return sqrtf(sum / Float(buffer.frameLength))
    }

    func testSystemAudioTapConverter_InterleavedTapLayout_ConvertsToMono16k() {
        assertConvertsToMono16k(asbd: FakeSystemAudioTapHardware.tapASBD, interleaved: true)
    }

    func testSystemAudioTapConverter_NonInterleavedLayout_ConvertsToMono16k() {
        assertConvertsToMono16k(asbd: Self.nonInterleavedASBD, interleaved: false)
    }
}
