import XCTest
import CoreAudio
@testable import LCTMac

/// Tests for AudioInputDevices' virtual-device detection heuristics.
final class AudioInputDevicesTests: XCTestCase {

    func testAudioInputDevice_KnownVirtualNames_Detected() {
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("BlackHole 2ch"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("blackhole 16ch"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("BLACKHOLE"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("Loopback Audio"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("Soundflower (2ch)"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("VB-Cable"))
        XCTAssertTrue(AudioInputDevices.isVirtualDeviceName("Aggregate Device"))
    }

    func testAudioInputDevice_PhysicalDeviceNames_NotVirtual() {
        XCTAssertFalse(AudioInputDevices.isVirtualDeviceName("MacBook Pro Microphone"))
        XCTAssertFalse(AudioInputDevices.isVirtualDeviceName("External Microphone"))
        XCTAssertFalse(AudioInputDevices.isVirtualDeviceName("USB Audio Device"))
        XCTAssertFalse(AudioInputDevices.isVirtualDeviceName("AirPods Pro"))
    }

    func testAudioInputDevice_VirtualTransportType_DetectedRegardlessOfName() {
        XCTAssertTrue(AudioInputDevices.isVirtualDevice(
            transportType: kAudioDeviceTransportTypeVirtual,
            name: "MacBook Pro Microphone"
        ))
    }

    func testAudioInputDevice_BuiltInTransportWithPhysicalName_NotVirtual() {
        XCTAssertFalse(AudioInputDevices.isVirtualDevice(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            name: "MacBook Pro Microphone"
        ))
    }

    func testAudioInputDevice_BuiltInTransportWithVirtualName_StillDetected() {
        XCTAssertTrue(AudioInputDevices.isVirtualDevice(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            name: "BlackHole 2ch"
        ))
    }
}
