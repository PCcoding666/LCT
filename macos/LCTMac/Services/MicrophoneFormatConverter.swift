@preconcurrency import AVFoundation

/// Converts microphone input buffers from the device's native format (any
/// sample rate / channel count) to the pipeline's speech format: 16 kHz mono
/// Float32, non-interleaved. One instance is reused across a capture session so
/// the sample-rate converter's filter state stays continuous between buffers.
final class MicrophoneFormatConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat, targetSampleRate: Double = 16000, targetChannels: Int = 1) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: targetSampleRate,
                  channels: AVAudioChannelCount(targetChannels),
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// Convert one input buffer. Returns nil for empty input or on converter
    /// error — a dropped buffer is preferable to killing the realtime tap.
    func convert(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard inputBuffer.frameLength > 0 else { return nil }

        // Output capacity: input frames scaled by the rate ratio, rounded up so
        // the converter never runs out of room mid-buffer.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = max(AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)), 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let input = SingleShotInput(buffer: inputBuffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            // Hand the input block over exactly once. A second pull answers
            // .noDataNow so the same samples are never delivered twice.
            guard !input.consumed else {
                outStatus.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            outStatus.pointee = .haveData
            return input.buffer
        }

        guard error == nil, outputBuffer.frameLength > 0 else { return nil }
        return outputBuffer
    }
}

/// One input buffer handed to AVAudioConverter's pull block. The block runs
/// synchronously inside convert(to:error:withInputFrom:), so this unchecked
/// Sendable box is never touched concurrently.
private final class SingleShotInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
