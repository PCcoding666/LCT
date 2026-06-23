import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import Combine
import CoreGraphics

/// Audio capture error types
enum AudioCaptureError: Error, LocalizedError {
    case noPermission
    case noDisplaysAvailable
    case captureSetupFailed(String)
    case audioProcessingFailed(String)
    case streamInterrupted(String)
    
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
        case .streamInterrupted(let message):
            return "Audio stream interrupted: \(message)"
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
/// Service for capturing system audio and microphone input using ScreenCaptureKit
class AudioCaptureService: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties
    @MainActor @Published private(set) var isCapturing: Bool = false
    @MainActor @Published private(set) var hasPermission: Bool = false
    @MainActor @Published private(set) var audioLevel: Float = 0
    @MainActor @Published private(set) var lastError: String?
    
    // MARK: - Configuration
    var config: AudioCaptureConfig
    
    // MARK: - Audio Callback
    // These callbacks are marked nonisolated(unsafe) because they are called from background threads
    // The callbacks themselves must be thread-safe (e.g., SFSpeechAudioBufferRecognitionRequest.append is thread-safe)
    nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    nonisolated(unsafe) var onAudioData: (@Sendable (Data) -> Void)?
    
    /// Callback when the SCStream is interrupted (e.g., display disconnected).
    /// Called on MainActor so the ViewModel can react (show error, attempt restart).
    var onStreamInterrupted: ((Error) -> Void)?
    
    // MARK: - Private Properties
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var videoOutput: VideoStreamOutput?
    private let streamOutputQueue = DispatchQueue(label: "com.lct.audioCapture.streamOutput", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    private var isStopping = false

    // MARK: - Initialization
    
    init(config: AudioCaptureConfig = AudioCaptureConfig()) {
        self.config = config
        super.init()
    }
    
    // MARK: - Permission Management
    
    /// Open System Settings to Screen Recording permissions
    static func openScreenRecordingSettings() {
        openPrivacySettings(pane: "Privacy_ScreenCapture")
    }

    /// Open System Settings to Microphone permissions
    static func openMicrophoneSettings() {
        openPrivacySettings(pane: "Privacy_Microphone")
    }

    /// Open System Settings to Speech Recognition permissions
    static func openSpeechRecognitionSettings() {
        openPrivacySettings(pane: "Privacy_SpeechRecognition")
    }

    private static func openPrivacySettings(pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Check and request screen capture permission
    func checkPermission() async -> Bool {
        appLog("[AudioCaptureService] --------- Permission Check Start ---------")
        
        // Method 1: Check standard macOS 15 API
        let hasAccess = CGPreflightScreenCaptureAccess()
        appLog("[AudioCaptureService] 1. CGPreflightScreenCaptureAccess: \(hasAccess)")
        
        if hasAccess {
            Task { @MainActor in self.hasPermission = true }
            appLog("[AudioCaptureService] ✅ Permission already granted via CGPreflight")
            return true
        }
        
        // Method 2: Fallback to SCShareableContent
        // CGPreflightScreenCaptureAccess sometimes caches 'false' if the user granted 
        // permission in System Settings without restarting the app.
        // SCShareableContent actually queries the display server.
        do {
            appLog("[AudioCaptureService] 2. Testing SCShareableContent fallback...")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                appLog("[AudioCaptureService] ✅ SCShareableContent returned \(content.displays.count) displays. Permission is actually granted.")
                Task { @MainActor in self.hasPermission = true }
                return true
            } else {
                appLog("[AudioCaptureService] ⚠️ SCShareableContent succeeded but returned 0 displays (could be headless mac, but usually means no perm).")
            }
        } catch {
            appLog("[AudioCaptureService] ❌ SCShareableContent test failed: \(error.localizedDescription)")
        }
        
        // Method 3: Request Access (will show prompt or return false if previously denied)
        let requestedAccess = CGRequestScreenCaptureAccess()
        appLog("[AudioCaptureService] 3. CGRequestScreenCaptureAccess: \(requestedAccess)")
        
        if requestedAccess {
            Task { @MainActor in self.hasPermission = true }
            appLog("[AudioCaptureService] ✅ Permission granted after CGRequest")
            return true
        }
        
        appLog("[AudioCaptureService] --------- Permission Check Failed ---------")

        // Pure query: don't set lastError or open System Settings here. The caller
        // (TranscriptionViewModel) decides whether this is fatal — if microphone
        // capture is enabled it silently falls back instead of surfacing an error.
        Task { @MainActor in
            self.hasPermission = false
        }

        return false
    }
    
    // MARK: - Capture Control
    
    /// Start capturing audio
    func startCapture() async throws {
        let isCapturingCurrently = await MainActor.run { isCapturing }
        guard !isCapturingCurrently else { return }
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

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
        // Disabled for now as dual-stream appending breaks SFSpeechRecognizer
        // if #available(macOS 15.0, *) {
        //     streamConfig.captureMicrophone = config.captureMicrophone
        // }
        
        // Minimal video config (required even for audio-only)
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS minimum
        
        // Create stream
        // Create stream with delegate for error handling (e.g., display disconnect)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

        // Create and add output handler
        let output = AudioStreamOutput(
            sampleRate: config.sampleRate,
            channelCount: config.channelCount
        )
        output.onAudioBuffer = { [weak self] buffer in
            self?.processAudioBufferBackground(buffer)
        }

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: streamOutputQueue)

        // Register a screen output to avoid ScreenCaptureKit dropping frames when video is configured.
        let screenOutput = VideoStreamOutput()
        try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: streamOutputQueue)

        // If microphone is enabled and available (macOS 15+)
        // Disabled for now as dual-stream appending breaks SFSpeechRecognizer
        // if #available(macOS 15.0, *), config.captureMicrophone {
        //     do {
        //         try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: streamOutputQueue)
        //     } catch {
        //         print("Warning: Could not add microphone stream output: \(error)")
        //         // Continue without microphone - system audio will still work
        //     }
        // }

        // Start the stream only after all outputs have been registered.
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
        self.videoOutput = screenOutput

        Task { @MainActor in
            self.isCapturing = true
            self.lastError = nil
        }
        
        appLog("Audio capture started successfully")
    }
    
    /// Start capturing audio from microphone only (no screen capture permission needed)
    func startMicrophoneOnlyCapture() async throws {
        let isCapturingCurrently = await MainActor.run { isCapturing }
        guard !isCapturingCurrently else { return }
        
        appLog("Starting microphone-only capture mode...")
        
        // Use AVAudioEngine for microphone capture
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        appLog("Microphone native format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
        
        // Target format for SFSpeechRecognizer (16kHz Mono PCM)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channelCount),
            interleaved: false
        )!
        
        // Use an AVAudioMixerNode to perform safe sample rate conversion
        let mixer = AVAudioMixerNode()
        audioEngine.attach(mixer)
        
        // Connect input -> mixer (native format)
        audioEngine.connect(inputNode, to: mixer, format: inputFormat)
        
        // Connect mixer -> mainMixerNode (target format) to ensure the graph runs
        // Mute the mixer so we don't get audio feedback through speakers
        audioEngine.connect(mixer, to: audioEngine.mainMixerNode, format: targetFormat)
        mixer.outputVolume = 0.0
        
        // Install tap on the mixer's output to get the correctly converted 16kHz buffers
        mixer.installTap(onBus: 0, bufferSize: 4096, format: targetFormat) { [weak self] buffer, _ in
            self?.processAudioBufferBackground(buffer)
        }
        
        // Start audio engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            throw AudioCaptureError.captureSetupFailed("Could not start audio engine: \(error.localizedDescription)")
        }
        
        self.audioEngine = audioEngine
        
        Task { @MainActor in
            self.isCapturing = true
            self.lastError = nil
        }
        
        appLog("Microphone-only capture started successfully (format: \(targetFormat.sampleRate)Hz, \(targetFormat.channelCount) channels)")
    }
    
    /// Stop capturing audio
    func stopCapture() async {
        let isCapturingCurrently = await MainActor.run { isCapturing }
        guard isCapturingCurrently else { return }
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        // Stop ScreenCaptureKit stream if active
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping capture: \(error)")
            }
            self.stream = nil
            self.streamOutput = nil
            self.videoOutput = nil
        }
        
        // Stop AVAudioEngine if active
        if let audioEngine = audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            self.audioEngine = nil
        }
        
        Task { @MainActor in
            self.isCapturing = false
        }
        
        appLog("Audio capture stopped")
    }
    
    // MARK: - Handlers
    
    /// Process audio buffer - this is called from background thread, so we use nonisolated
    private func processAudioBufferBackground(_ buffer: AVAudioPCMBuffer) {
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
            
            // Log RMS occasionally to verify audio isn't silent
            if Int(Date().timeIntervalSince1970 * 10) % 50 == 0 {
                appLog("[AudioCaptureService] 🔊 Current RMS level: \(rms)")
            }
            
            // Only dispatch UI updates to main thread (not every buffer)
            Task { @MainActor [weak self] in
                // Normalize to 0-1 range (assuming -60dB to 0dB range)
                self?.audioLevel = max(0, min(1, (level + 60) / 60))
            }
        }
        
        // IMPORTANT: Call onAudioBuffer directly from background thread
        // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe according to Apple documentation
        // Dispatching to main thread for every buffer causes main thread flooding and UI hangs
        onAudioBuffer?(buffer)
        
        // Convert to Data and call onAudioData if needed
        if let onAudioData = onAudioData {
            if let data = bufferToData(buffer) {
                onAudioData(data)
            }
        }
    }
    
    /// Convert AVAudioPCMBuffer to Data (16-bit PCM)
    nonisolated private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
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

// MARK: - SCStreamDelegate (Stream Error Handling)

extension AudioCaptureService: SCStreamDelegate {
    /// Called when the SCStream stops unexpectedly (e.g., display disconnected,
    /// process interrupted, or system-level error).
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        appLog("[AudioCaptureService] ⚠️ SCStream stopped with error: \(error.localizedDescription)")
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isCapturing = false
            self.lastError = "Audio capture interrupted: \(error.localizedDescription). Please click Start to resume."
            
            // Clean up stream references
            self.stream = nil
            self.streamOutput = nil
            self.videoOutput = nil
            
            // Notify the ViewModel so it can handle recovery
            self.onStreamInterrupted?(error)
        }
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
        // Process system audio samples
        // Note: We ignore .microphone samples here because appending two overlapping parallel streams 
        // (system audio + microphone) to a single SFSpeechAudioBufferRecognitionRequest causes 
        // the audio to be sequentially concatenated, resulting in a stuttering mess that fails recognition.
        // To support both, they must be mixed into a single buffer first.
        if type == .audio {
            guard let buffer = convertToPCMBuffer(sampleBuffer) else { return }
            onAudioBuffer?(buffer)
        }
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

private final class VideoStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Intentionally drain screen samples to satisfy ScreenCaptureKit output contract.
        _ = sampleBuffer
        _ = type
    }
}
