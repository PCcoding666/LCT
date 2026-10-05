import CoreAudio
import Foundation

/// One Core Audio input device as shown in the microphone picker.
struct AudioInputDevice: Equatable, Identifiable, Sendable {
    /// HAL device id — valid for this boot, used to point the input node at the device.
    let id: AudioDeviceID
    /// Persistent device UID — stored in settings.
    let uid: String
    let name: String
    let isVirtual: Bool
    let isSystemDefault: Bool
}

/// Enumerates Core Audio devices that can act as microphone input.
enum AudioInputDevices {

    // MARK: - Virtual-device heuristics (pure, testable)

    /// Name-based virtual sound card detection (BlackHole, Loopback, etc.).
    static func isVirtualDeviceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["blackhole", "loopback", "soundflower", "vb-cable", "aggregate"]
            .contains { lowered.contains($0) }
    }

    /// A device is virtual when the HAL says so, or when its name matches a
    /// known virtual driver (some drivers don't report the virtual transport).
    static func isVirtualDevice(transportType: UInt32, name: String) -> Bool {
        transportType == kAudioDeviceTransportTypeVirtual || isVirtualDeviceName(name)
    }

    // MARK: - Enumeration

    /// All devices with at least one input channel, sorted by name.
    static func listInputDevices() -> [AudioInputDevice] {
        let defaultID = systemDefaultInputDeviceID()
        return allDeviceIDs()
            .compactMap { deviceID -> AudioInputDevice? in
                guard inputChannelCount(deviceID) > 0,
                      let uid = copyStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                      let name = copyStringProperty(deviceID, selector: kAudioObjectPropertyName)
                else { return nil }
                let transport = uint32Property(deviceID, selector: kAudioDevicePropertyTransportType) ?? 0
                return AudioInputDevice(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    isVirtual: isVirtualDevice(transportType: transport, name: name),
                    isSystemDefault: deviceID == defaultID
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The current system default input device, if any.
    static func systemDefaultInputDevice() -> AudioInputDevice? {
        listInputDevices().first(where: { $0.isSystemDefault })
    }

    // MARK: - Core Audio helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown)
        else { return nil }
        return deviceID
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32Property(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func copyStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // Core Audio returns CF string properties retained; storing into this
        // ARC-managed var balances that retain when the var goes out of scope.
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
