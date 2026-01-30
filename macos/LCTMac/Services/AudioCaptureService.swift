import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

/// Audio capture error types
enum AudioCaptureError: Error, LocalizedError {
    case noPermission
    case noDisplaysAvailable
    case captureSetupFailed(String)
    case audioProcessingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Screen recording permission not granted"
        case .noDisplaysAvailable:
            return "No displays available for capture"
        case .captureSetupFailed(let message):
            return "Capture setup failed: \(message)"
        case .audioProcessingFailed(let message):
            return "Audio processing failed: \(message)"
        }
    }
}

/// Audio capture configuration
struct AudioCaptureConfig {
    var captureSystemAudio: Bool = true
    var captureMicrophone: Bool = true
    var sampleRate: Double = 16000  // Whisper expects 16kHz
    var channelCount: Int = 1       // Mono for speech recognition
}

/// Service for capturing system audio and microphone input using ScreenCaptureKit
@MainActor
class AudioCaptureService: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var hasPermission: Bool = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastError: String?
    
    // MARK: - Configuration
    var config: AudioCaptureConfig
    
    // MARK: - Audio Callback
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onAudioData: ((Data) -> Void)?
    
    // MARK: - Private Properties
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var audioEngine: AVAudioEngine?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(config: AudioCaptureConfig = AudioCaptureConfig()) {
        self.config = config
        super.init()
    }
    
    // MARK: - Permission Management
    
    /// Check and request screen capture permission
    func checkPermission() async -> Bool {
        do {
            // This will trigger permission dialog if needed
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            hasPermission = !content.displays.isEmpty
            return hasPermission
        } catch {
            hasPermission = false
            lastError = "Permission check failed: \(error.localizedDescription)"
            return false
        }
    }
    
    // MARK: - Capture Control
    
    /// Start capturing audio
    func startCapture() async throws {
        guard !isCapturing else { return }
        
        // Check permission first
        guard await checkPermission() else {
            throw AudioCaptureError.noPermission
        }
        
        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplaysAvailable
        }
        
        // Create content filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Configure stream for audio capture
        let streamConfig = SCStreamConfiguration()
        
        // We only need audio, not video
        streamConfig.capturesAudio = config.captureSystemAudio
        streamConfig.excludesCurrentProcessAudio = true  // Don't capture our own audio
        
        // Audio configuration
        streamConfig.sampleRate = Int(config.sampleRate)
        streamConfig.channelCount = config.channelCount
        
        // Microphone capture (macOS 15+)
        if #available(macOS 15.0, *) {
            streamConfig.captureMicrophone = config.captureMicrophone
        }
        
        // Minimal video config (required even for audio-only)
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS minimum
        
        // Create stream
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        
        // Create and add output handler
        let output = AudioStreamOutput(
            sampleRate: config.sampleRate,
            channelCount: config.channelCount
        )
        output.onAudioBuffer = { [weak self] buffer in
            self?.processAudioBuffer(buffer)
        }
        
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        
        // If microphone is enabled and available
        if #available(macOS 15.0, *), config.captureMicrophone {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: .global(qos: .userInteractive))
        }
        
        // Start the stream
        try await stream.startCapture()
        
        self.stream = stream
        self.streamOutput = output
        isCapturing = true
        lastError = nil
        
        print("Audio capture started successfully")
    }
    
    /// Stop capturing audio
    func stopCapture() async {
        guard isCapturing, let stream = stream else { return }
        
        do {
            try await stream.stopCapture()
        } catch {
            print("Error stopping capture: \(error)")
        }
        
        self.stream = nil
        self.streamOutput = nil
        isCapturing = false
        
        print("Audio capture stopped")
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate audio level for visualization
        if let channelData = buffer.floatChannelData {
            let frames = buffer.frameLength
            var sum: Float = 0
            for i in 0..<Int(frames) {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frames))
            let level = 20 * log10(max(rms, 0.000001))
            
            Task { @MainActor in
                // Normalize to 0-1 range (assuming -60dB to 0dB range)
                self.audioLevel = max(0, min(1, (level + 60) / 60))
            }
        }
        
        // Forward buffer to callback
        onAudioBuffer?(buffer)
        
        // Convert to Data if needed
        if let onAudioData = onAudioData {
            if let data = bufferToData(buffer) {
                onAudioData(data)
            }
        }
    }
    
    /// Convert AVAudioPCMBuffer to Data (16-bit PCM)
    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        
        let frames = Int(buffer.frameLength)
        var data = Data(capacity: frames * 2)  // 16-bit = 2 bytes per sample
        
        for i in 0..<frames {
            // Convert float to 16-bit integer
            let sample = channelData[0][i]
            let clampedSample = max(-1.0, min(1.0, sample))
            let intSample = Int16(clampedSample * Float(Int16.max))
            
            // Append as little-endian bytes
            withUnsafeBytes(of: intSample.littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        
        return data
    }
}

// MARK: - Audio Stream Output Handler

class AudioStreamOutput: NSObject, SCStreamOutput {
    let sampleRate: Double
    let channelCount: Int
    
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    
    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only process audio samples
        guard type == .audio || type == .microphone else { return }
        
        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let buffer = convertToPCMBuffer(sampleBuffer) else { return }
        
        onAudioBuffer?(buffer)
    }
    
    private func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        
        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd = audioStreamBasicDescription?.pointee else {
            return nil
        }
        
        guard let format = AVAudioFormat(streamDescription: &UnsafeMutablePointer(mutating: audioStreamBasicDescription)!.pointee) else {
            return nil
        }
        
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Get audio buffer list
        var bufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr else {
            return nil
        }
        
        // Copy audio data to PCM buffer
        if let audioData = bufferList.mBuffers.mData,
           let pcmData = pcmBuffer.floatChannelData?[0] {
            let byteCount = Int(bufferList.mBuffers.mDataByteSize)
            
            // Convert based on format
            if asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                // Already float
                memcpy(pcmData, audioData, byteCount)
            } else if asbd.mBitsPerChannel == 16 {
                // Convert 16-bit integer to float
                let int16Data = audioData.bindMemory(to: Int16.self, capacity: frameCount)
                for i in 0..<frameCount {
                    pcmData[i] = Float(int16Data[i]) / Float(Int16.max)
                }
            }
        }
        
        return pcmBuffer
    }
}

// MARK: - Extension for microphone output type

extension SCStreamOutputType {
    static var microphone: SCStreamOutputType {
        // microphone is available in macOS 15+
        if #available(macOS 15.0, *) {
            return .microphone
        }
        return .audio
    }
}
