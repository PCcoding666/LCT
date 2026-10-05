import XCTest
@preconcurrency import AVFoundation
@testable import LCTMac

/// Guards the thread-safety contract of the lock-protected lane registry:
/// appendAudioBuffer must be a safe no-op for unknown/inactive lanes, even
/// when called concurrently with stop() from audio threads.
@MainActor
final class SpeechAnalyzerServiceTests: XCTestCase {

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320)!
        buffer.frameLength = 320
        return buffer
    }

    func testAppendAudioBuffer_UnknownSource_IsDroppedSafely() {
        let service = SpeechAnalyzerService(language: .english)
        let buffer = makeBuffer()

        // No lanes were started: appends for both sources must be no-ops.
        service.appendAudioBuffer(buffer, source: .system)
        service.appendAudioBuffer(buffer, source: .microphone)

        XCTAssertFalse(service.anyLaneRunning)
        XCTAssertTrue(service.statsSnapshot().isEmpty)
    }

    func testStop_WithoutStart_IsSafeAndKeepsStatsEmpty() {
        let service = SpeechAnalyzerService(language: .english)
        service.stop()
        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(service.statsSnapshot().isEmpty)
    }

    func testAppendAudioBuffer_ConcurrentWithStop_DoesNotCrash() {
        let service = SpeechAnalyzerService(language: .english)
        let buffer = makeBuffer()

        // Hammer appendAudioBuffer from background queues (like real audio
        // threads) while stop() mutates the registry on MainActor. With the
        // registry lock this must be crash-free.
        let group = DispatchGroup()
        for _ in 0 ..< 4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< 1_000 {
                    service.appendAudioBuffer(buffer, source: .system)
                    service.appendAudioBuffer(buffer, source: .microphone)
                }
            }
        }
        service.stop()
        group.wait()

        XCTAssertFalse(service.anyLaneRunning)
        XCTAssertTrue(service.statsSnapshot().isEmpty)
    }
}
