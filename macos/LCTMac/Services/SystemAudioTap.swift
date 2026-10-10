import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation

/// A Core Audio setup step failed. Carries the step name and the raw OSStatus
/// so logs and notices can show both without inventing text.
struct SystemAudioTapError: Error, Equatable, CustomStringConvertible {
    let step: String
    let status: OSStatus

    var description: String { "\(step) (OSStatus \(status))" }
}

/// System-audio capture backend that needs no screen-recording permission.
/// The production implementation is a Core Audio process tap (macOS 14.2+);
/// tests substitute a fake so they never record the machine's real output.
protocol SystemAudioTapping: AnyObject, Sendable {
    /// Delivers converted buffers (16 kHz mono Float32) on the tap's serial IO
    /// queue. Assign before `start()`; the value current at start is the one
    /// the IO callback captures.
    var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }

    /// One-shot fired by the FIRST IO callback after `start()`, on the tap's
    /// IO queue. macOS answers a denied system-audio tap with silence — every
    /// setup step succeeds but no callback ever arrives — while an authorized
    /// tap calls back continuously, even when the system is silent. So the
    /// first callback is the only reliable "authorized" signal. Like
    /// `onAudioBuffer`, the value current at `start()` is the one captured.
    var onFirstCallback: (@Sendable () -> Void)? { get set }

    /// Create the tap and start the audio device. Idempotent: a second call
    /// while running is a no-op. Throws `SystemAudioTapError` when a Core
    /// Audio step fails.
    func start() throws

    /// Stop the device and destroy every created object. Idempotent, and a
    /// failing destroy step never skips the remaining cleanup.
    func stop()
}

/// The Core Audio system calls `SystemAudioTap` depends on, one method per
/// call, so tests can verify step ordering and failure handling with a fake —
/// a real tap must never be created from tests.
protocol SystemAudioTapHardware {
    func translatePIDToProcessObject(_ pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID)
    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID)
    func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, asbd: AudioStreamBasicDescription)
    func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioObjectID)
    func createIOProc(deviceID: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) -> (status: OSStatus, procID: AudioDeviceIOProcID?)
    func startDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus
    func stopDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus
    func destroyIOProc(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID) -> OSStatus
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
}

/// Live Core Audio implementation of `SystemAudioTapHardware`.
struct CoreAudioTapHardware: SystemAudioTapHardware {
    func translatePIDToProcessObject(_ pid: pid_t) -> (status: OSStatus, objectID: AudioObjectID) {
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &objectID
        )
        return (status, objectID)
    }

    func createProcessTap(_ description: CATapDescription) -> (status: OSStatus, tapID: AudioObjectID) {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        return (status, tapID)
    }

    func tapFormat(_ tapID: AudioObjectID) -> (status: OSStatus, asbd: AudioStreamBasicDescription) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        return (status, asbd)
    }

    func createAggregateDevice(_ description: [String: Any]) -> (status: OSStatus, deviceID: AudioObjectID) {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        return (status, deviceID)
    }

    func createIOProc(deviceID: AudioObjectID, queue: DispatchQueue, block: @escaping AudioDeviceIOBlock) -> (status: OSStatus, procID: AudioDeviceIOProcID?) {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue, block)
        return (status, procID)
    }

    func startDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStart(deviceID, procID)
    }

    func stopDevice(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStop(deviceID, procID)
    }

    func destroyIOProc(_ deviceID: AudioObjectID, procID: AudioDeviceIOProcID) -> OSStatus {
        AudioDeviceDestroyIOProcID(deviceID, procID)
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// Converts tap-format Core Audio buffer lists to the pipeline's speech
/// format (16 kHz mono Float32) via `MicrophoneFormatConverter`. One instance
/// per capture session so the sample-rate converter's filter state stays
/// continuous between buffers. Only ever touched on the tap's serial IO queue.
final class SystemAudioTapConverter {
    let inputFormat: AVAudioFormat
    private let converter: MicrophoneFormatConverter

    init?(asbd: AudioStreamBasicDescription, targetSampleRate: Double = 16000, targetChannels: Int = 1) {
        var asbd = asbd
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let converter = MicrophoneFormatConverter(
                  inputFormat: format,
                  targetSampleRate: targetSampleRate,
                  targetChannels: targetChannels
              )
        else { return nil }
        self.inputFormat = format
        self.converter = converter
    }

    /// Wrap one input buffer list without copying and convert it. Must run
    /// synchronously inside the IO callback: the wrapped storage is owned by
    /// Core Audio and only valid for the callback's duration. A dropped
    /// buffer (nil) is preferable to killing the realtime thread.
    func convert(_ bufferList: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        if let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList) {
            return converter.convert(pcm)
        }
        return copyAndConvert(bufferList)
    }

    /// `bufferListNoCopy` rejects multi-buffer (non-interleaved) lists, so
    /// those are copied channel-by-channel into an owned buffer first.
    private func copyAndConvert(_ bufferList: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        guard inputFormat.commonFormat == .pcmFormatFloat32 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let bytesPerFrame = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
        let channelCount = Int(inputFormat.channelCount)
        guard bytesPerFrame > 0, buffers.count >= channelCount,
              let first = buffers.first, first.mDataByteSize > 0
        else { return nil }
        let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount),
              let dst = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = frameCount
        for channel in 0..<channelCount {
            guard let src = buffers[channel].mData else { return nil }
            memcpy(dst[channel], src, Int(first.mDataByteSize))
        }
        return converter.convert(pcm)
    }
}

/// Captures system audio with a Core Audio process tap: a private global
/// stereo tap (excluding LCT's own playback) inside a private aggregate
/// device, read through an IO proc on a dedicated serial queue. Requires
/// macOS 14.2+ and — unlike ScreenCaptureKit — no screen-recording permission.
final class SystemAudioTap: SystemAudioTapping, @unchecked Sendable {
    private let hardware: any SystemAudioTapHardware
    private let targetSampleRate: Double
    private let targetChannels: Int
    private let ioQueue = DispatchQueue(label: "com.lct.systemAudioTap.io", qos: .userInitiated)

    /// Created-object IDs, guarded by `lock` so a stop racing a failed start
    /// can never double-destroy or leak.
    private let lock = NSLock()
    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var ioProcID: AudioDeviceIOProcID?
    /// Set under `lock` once the IO callback has delivered a buffer since the
    /// last `start()` — the one-shot guard for `onFirstCallback`.
    private var didFireFirstCallback = false

    nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    nonisolated(unsafe) var onFirstCallback: (@Sendable () -> Void)?

    /// Which processes the tap records.
    enum Target: Equatable {
        /// Everything the Mac plays except LCT itself — the capture lane.
        case systemExcludingSelf
        /// Only LCT's own output — the permission probe, which plays a short
        /// silence itself so the tap has audio to deliver even when nothing
        /// else on the Mac is playing.
        case ownProcessOnly
    }

    private let target: Target

    init(hardware: any SystemAudioTapHardware = CoreAudioTapHardware(),
         target: Target = .systemExcludingSelf,
         targetSampleRate: Double = 16000,
         targetChannels: Int = 1) {
        self.hardware = hardware
        self.target = target
        self.targetSampleRate = targetSampleRate
        self.targetChannels = targetChannels
    }

    func start() throws {
        lock.lock()
        let alreadyRunning = tapID != nil || aggregateDeviceID != nil || ioProcID != nil
        if !alreadyRunning {
            didFireFirstCallback = false
        }
        lock.unlock()
        guard !alreadyRunning else { return }

        var createdTapID: AudioObjectID?
        var createdDeviceID: AudioObjectID?
        var createdProcID: AudioDeviceIOProcID?

        do {
            // 1. Our own process object, so LCT's own playback is excluded.
            let own = hardware.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
            try Self.check(own.status, "translatePIDToProcessObject")

            // 2. Private stereo tap: everything except ourselves, or (probe)
            // only ourselves.
            let tapUUID = UUID()
            let description: CATapDescription
            switch target {
            case .systemExcludingSelf:
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [own.objectID])
            case .ownProcessOnly:
                description = CATapDescription(stereoMixdownOfProcesses: [own.objectID])
            }
            description.uuid = tapUUID
            description.name = "LCT system audio tap"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            let tap = hardware.createProcessTap(description)
            try Self.check(tap.status, "AudioHardwareCreateProcessTap")
            createdTapID = tap.tapID

            // 3. Tap format → sample-rate converter.
            let format = hardware.tapFormat(tap.tapID)
            try Self.check(format.status, "kAudioTapPropertyFormat")
            guard let converter = SystemAudioTapConverter(
                asbd: format.asbd,
                targetSampleRate: targetSampleRate,
                targetChannels: targetChannels
            ) else {
                throw SystemAudioTapError(step: "converter", status: OSStatus(kAudioFormatUnsupportedDataFormatError))
            }

            // 4. Private aggregate device that contains only the tap.
            let aggregate = hardware.createAggregateDevice(Self.aggregateDeviceDescription(tapUUID: tapUUID))
            try Self.check(aggregate.status, "AudioHardwareCreateAggregateDevice")
            createdDeviceID = aggregate.deviceID

            // 5. IO proc on a dedicated serial queue.
            let handler = onAudioBuffer
            let firstCallback = onFirstCallback
            let block = Self.makeIOBlock(converter: converter) { [weak self] buffer in
                self?.fireFirstCallbackOnce(firstCallback)
                handler?(buffer)
            }
            let proc = hardware.createIOProc(deviceID: aggregate.deviceID, queue: ioQueue, block: block)
            try Self.check(proc.status, "AudioDeviceCreateIOProcIDWithBlock")
            createdProcID = proc.procID

            // 6. Start the device (the aggregate taps auto-start).
            try Self.check(hardware.startDevice(aggregate.deviceID, procID: createdProcID), "AudioDeviceStart")
        } catch {
            // Best-effort cleanup of whatever was created before the failure.
            Self.teardown(hardware: hardware, deviceID: createdDeviceID, procID: createdProcID, tapID: createdTapID)
            throw error
        }

        lock.lock()
        tapID = createdTapID
        aggregateDeviceID = createdDeviceID
        ioProcID = createdProcID
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let deviceID = aggregateDeviceID
        let procID = ioProcID
        let tap = tapID
        tapID = nil
        aggregateDeviceID = nil
        ioProcID = nil
        lock.unlock()

        guard deviceID != nil || tap != nil else { return }
        Self.teardown(hardware: hardware, deviceID: deviceID, procID: procID, tapID: tap)
    }

    /// Fires `handler` on the first IO callback after `start()` only. The IO
    /// queue is serial, but `lock` keeps the flag correct against a racing
    /// stop/start on another thread.
    private func fireFirstCallbackOnce(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        let isFirst = !didFireFirstCallback
        didFireFirstCallback = true
        lock.unlock()
        if isFirst { handler?() }
    }

    /// Stop → destroy IO proc → destroy aggregate device → destroy tap.
    /// Every step runs even when an earlier one failed; statuses go to the log.
    private static func teardown(hardware: any SystemAudioTapHardware,
                                 deviceID: AudioObjectID?,
                                 procID: AudioDeviceIOProcID?,
                                 tapID: AudioObjectID?) {
        if let deviceID, let procID {
            appLog("[SystemAudioTap] AudioDeviceStop: \(hardware.stopDevice(deviceID, procID: procID))")
        }
        if let deviceID, let procID {
            appLog("[SystemAudioTap] AudioDeviceDestroyIOProcID: \(hardware.destroyIOProc(deviceID, procID: procID))")
        }
        if let deviceID {
            appLog("[SystemAudioTap] AudioHardwareDestroyAggregateDevice: \(hardware.destroyAggregateDevice(deviceID))")
        }
        if let tapID {
            appLog("[SystemAudioTap] AudioHardwareDestroyProcessTap: \(hardware.destroyProcessTap(tapID))")
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        appLog("[SystemAudioTap] \(step): \(status)")
        guard status == noErr else { throw SystemAudioTapError(step: step, status: status) }
    }

    private static func aggregateDeviceDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "LCT System Audio Tap",
            kAudioAggregateDeviceUIDKey: "com.lct.mac.tap.\(tapUUID.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
    }

    /// Built as a nonisolated static: Core Audio invokes the block on its own
    /// IO thread, and a closure formed inside a @MainActor context would
    /// inherit MainActor isolation and trap on the runtime isolation check.
    /// The converter is captured strongly so it lives as long as the proc.
    nonisolated private static func makeIOBlock(
        converter: SystemAudioTapConverter,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AudioDeviceIOBlock {
        return { _, inInputData, _, _, _ in
            guard let converted = converter.convert(inInputData) else { return }
            onBuffer(converted)
        }
    }
}
