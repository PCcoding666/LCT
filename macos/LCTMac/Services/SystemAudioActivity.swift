import Foundation
import CoreAudio
@preconcurrency import AVFoundation

/// Whether any audio output device on the Mac is currently running IO.
///
/// A Core Audio process tap only calls back while some tapped process is
/// actually playing: with nothing playing, an authorized tap is as silent as
/// a denied one. "No callbacks" therefore only means "not authorized" while
/// output is running somewhere — this probe answers that.
protocol SystemOutputActivityProbing: Sendable {
    func isAnyOutputRunning() -> Bool
}

/// Live implementation: any device with output streams that is running in
/// some *other* process (`kAudioDevicePropertyDeviceIsRunningSomewhere` set,
/// `kAudioDevicePropertyDeviceIsRunning` — this process — clear). The capture
/// tap excludes LCT itself, so LCT's own IO (e.g. its microphone engine) must
/// not count as "something is playing". LCT's private tap aggregates have no
/// output streams and are skipped by UID as well.
struct CoreAudioOutputActivity: SystemOutputActivityProbing {
    func isAnyOutputRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return false
        }
        return devices.contains { device in
            Self.hasOutputStreams(device)
                && !Self.isLCTTapAggregate(device)
                && Self.flag(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device)
                && !Self.flag(kAudioDevicePropertyDeviceIsRunning, of: device)
        }
    }

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func flag(_ selector: AudioObjectPropertySelector, of device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func isLCTTapAggregate(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return false }
        return (value as String).hasPrefix("com.lct.mac.tap.")
    }
}

/// Plays a short stretch of digital silence from LCT itself, so a tap on
/// LCT's own process has audio to deliver during the permission probe —
/// independent of whether anything else on the Mac is playing.
protocol SilencePlaying: AnyObject {
    func start() throws
    func stop()
}

/// AVAudioEngine-based silence player (no audible output, no permission).
final class SilencePlayer: SilencePlaying {
    private var engine: AVAudioEngine?

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Two seconds of zeros, looped: the probe stops it well before then.
        let frames = AVAudioFrameCount(max(format.sampleRate, 1) * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        // Allocation does not guarantee zeroed memory — clear it explicitly.
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                memset(channels[channel], 0, Int(frames) * MemoryLayout<Float>.size)
            }
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
    }
}
