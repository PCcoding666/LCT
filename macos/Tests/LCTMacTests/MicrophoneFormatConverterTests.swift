import XCTest
import AVFoundation
@testable import LCTMac

/// Tests for MicrophoneFormatConverter: native mic formats → 16kHz mono Float32.
final class MicrophoneFormatConverterTests: XCTestCase {

    private func makeSineBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        frequency: Double = 440,
        amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
            }
        }
        return buffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += data[0][i] * data[0][i]
        }
        return sqrt(sum / Float(buffer.frameLength))
    }

    func testMicrophoneFormatConverter_Stereo48kSine_ConvertsTo16kMono() throws {
        let input = try XCTUnwrap(makeSineBuffer(sampleRate: 48000, channels: 2, frames: 4800))
        let converter = try XCTUnwrap(MicrophoneFormatConverter(inputFormat: input.format))

        // First call: the sample-rate converter primes its filter and holds a
        // few frames back, but the format contract and signal level already hold.
        let first = try XCTUnwrap(converter.convert(input))
        XCTAssertEqual(first.format.sampleRate, 16000)
        XCTAssertEqual(first.format.channelCount, 1)
        XCTAssertFalse(first.format.isInterleaved)
        XCTAssertGreaterThan(rms(first), 0.05, "converted audio must carry the sine, not silence")

        // Steady state — what the live tap sees: ~1/3 of the input frames.
        let second = try XCTUnwrap(converter.convert(input))
        XCTAssertEqual(Double(second.frameLength), 1600, accuracy: 20)
        XCTAssertGreaterThan(rms(second), 0.05)
    }

    func testMicrophoneFormatConverter_Mono44100Sine_ConvertsTo16kMono() throws {
        let input = try XCTUnwrap(makeSineBuffer(sampleRate: 44100, channels: 1, frames: 4410))
        let converter = try XCTUnwrap(MicrophoneFormatConverter(inputFormat: input.format))

        let first = try XCTUnwrap(converter.convert(input))
        XCTAssertEqual(first.format.sampleRate, 16000)
        XCTAssertEqual(first.format.channelCount, 1)
        XCTAssertGreaterThan(rms(first), 0.05, "converted audio must carry the sine, not silence")

        // 4410 frames @44.1kHz ≈ 1600 frames @16kHz in steady state.
        let second = try XCTUnwrap(converter.convert(input))
        XCTAssertEqual(Double(second.frameLength), 1600, accuracy: 20)
        XCTAssertGreaterThan(rms(second), 0.05)
    }

    func testMicrophoneFormatConverter_EmptyInput_ReturnsNil() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ))
        let converter = try XCTUnwrap(MicrophoneFormatConverter(inputFormat: format))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        empty.frameLength = 0

        XCTAssertNil(converter.convert(empty))
    }

    func testMicrophoneFormatConverter_InvalidInputFormat_ReturnsNilInit() {
        let format = AVAudioFormat()
        XCTAssertNil(MicrophoneFormatConverter(inputFormat: format))
    }
}
