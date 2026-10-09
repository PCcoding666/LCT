import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AudioUnit
import Combine
import CoreGraphics

/// Audio capture error types
enum AudioCaptureError: Error, LocalizedError {
    case noPermission
    case noMicrophonePermission
    case noDisplaysAvailable
    case captureSetupFailed(String)
    case audioProcessingFailed(String)
    case streamInterrupted(String)
    
    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Screen recording permission not granted"
        case .noMicrophonePermission:
            return "Microphone permission not granted"
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
    /// Core Audio UID of the microphone input device; nil follows the system default.
    var microphoneDeviceUID: String? = nil
}

/// Service for capturing system audio and microphone input using ScreenCaptureKit
/// Service for capturing system audio and microphone input using ScreenCaptureKit
class AudioCaptureService: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties
    @MainActor @Published private(set) var isCapturing: Bool = false
    @MainActor @Published private(set) var hasPermission: Bool = false
    @MainActor @Published private(set) var audioLevel: Float = 0
    /// Per-lane meter levels (0...1, -60dB…0dB normalized, with fast-attack/slow-decay ballistics)
    @MainActor @Published private(set) var systemLevel: Float = 0
    @MainActor @Published private(set) var micLevel: Float = 0
    /// Lanes actually running in the current capture session
    @MainActor @Published private(set) var activeSources: [AudioSource] = []
    @MainActor @Published private(set) var lastError: String?
    /// Microphone input device actually in use for the current session (nil when the mic lane is off)
    @MainActor @Published private(set) var microphoneDeviceName: String?
    @MainActor @Published private(set) var microphoneDeviceIsVirtual: Bool = false

    // MARK: - Configuration
    var config: AudioCaptureConfig

    // MARK: - Audio Callback
    // These callbacks are marked nonisolated(unsafe) because they are called from background threads
    // The callbacks themselves must be thread-safe (e.g., SFSpeechAudioBufferRecognitionRequest.append is thread-safe)
    // The AudioSource tag tells the consumer which capture lane the buffer came from.
    nonisolated(unsafe) var onAudioBuffer: (@Sendable (AVAudioPCMBuffer, AudioSource) -> Void)?
    nonisolated(unsafe) var onAudioData: (@Sendable (Data) -> Void)?

    /// Callback when the SCStream is interrupted (e.g., display disconnected).
    /// Called on MainActor so the ViewModel can react (show error, attempt restart).
    var onStreamInterrupted: ((Error) -> Void)?

    /// Fired on the MainActor when the mic lane stays completely silent for a
    /// whole SilenceDetector streak (typically a wrong/idle input device).
    var onMicrophoneSilenceDetected: (@MainActor () -> Void)?

    /// Fired on the MainActor when the mic lane delivers continuous audible
    /// RMS again after a silence warning fired (the input device recovered).
    var onMicrophoneAudioResumed: (@MainActor () -> Void)?
    
    // MARK: - Private Properties
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var videoOutput: VideoStreamOutput?
    private let streamOutputQueue = DispatchQueue(label: "com.lct.audioCapture.streamOutput", qos: .userInitiated)
    private var audioEngine: AVAudioEngine?
    /// Mic input device in use for the current session, recorded synchronously
    /// when the engine starts so callers can inspect it right after `await
    /// start…Capture()` returns (the @Published mirror above hops to MainActor).
    private(set) var activeMicrophoneDevice: AudioInputDevice?
    /// Watchdog for a mic lane that delivers only digital silence.
    private var micSilenceDetector = SilenceDetector()
    private var cancellables = Set<AnyCancellable>()
    private var isStarting = false
    private var isStopping = false
    // Meter update throttling timestamps (each lane's buffers arrive serially on
    // its own queue, so per-lane vars stay single-threaded)
    private var lastSystemMeterUpdate: TimeInterval = 0
    private var lastMicMeterUpdate: TimeInterval = 0

    // MARK: - Initialization
    
    init(config: AudioCaptureConfig = AudioCaptureConfig()) {
        self.config = config
        super.init()
    }
    
    // MARK: - Permission Management

    /// Ensure microphone TCC permission, requesting in-app when undetermined.
    /// macOS feeds silent (all-zero) buffers to unauthorized processes without
    /// any error — previously surfaced as "capturing but RMS always 0.0".
    /// Returns true when authorized.
    @discardableResult
    static func ensureMicrophonePermission() async -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        appLog("[AudioCaptureService] Microphone authorization status: \(micStatus.rawValue)")
        switch micStatus {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            appLog("[AudioCaptureService] Microphone permission request result: \(granted)")
            return granted
        default:
            appLog("[AudioCaptureService] ❌ Microphone permission denied/restricted")
            return false
        }
    }

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

    /// Start capturing system audio only (ScreenCaptureKit)
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

        try await startSystemAudioStream()

        Task { @MainActor in
            self.isCapturing = true
            self.lastError = nil
            self.activeSources = [.system]
            self.systemLevel = 0
        }

        appLog("Audio capture started successfully (system audio)")
    }

    /// Start BOTH lanes concurrently: system audio (ScreenCaptureKit) + microphone
    /// (AVAudioEngine). Buffers are tagged with their AudioSource so downstream
    /// recognition runs as two independent lanes — never mixed into one stream
    /// (mixing/interleaving two streams into a single recognizer corrupts both).
    func startDualCapture() async throws {
        let isCapturingCurrently = await MainActor.run { isCapturing }
        guard !isCapturingCurrently else { return }
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard await checkPermission() else {
            throw AudioCaptureError.noPermission
        }

        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.noMicrophonePermission
        }

        try await startSystemAudioStream()

        do {
            try startMicrophoneEngine()
        } catch {
            // Mic failed after the system stream started — tear everything back
            // down so we don't run a half-configured session.
            await teardownCapture()
            throw error
        }

        Task { @MainActor in
            self.isCapturing = true
            self.lastError = nil
            self.activeSources = [.system, .microphone]
            self.systemLevel = 0
            self.micLevel = 0
        }

        appLog("Dual capture started successfully (system audio + microphone)")
    }

    /// Start capturing audio from microphone only (no screen capture permission needed)
    func startMicrophoneOnlyCapture() async throws {
        let isCapturingCurrently = await MainActor.run { isCapturing }
        guard !isCapturingCurrently else { return }

        appLog("Starting microphone-only capture mode...")

        guard await Self.ensureMicrophonePermission() else {
            throw AudioCaptureError.noMicrophonePermission
        }

        try startMicrophoneEngine()

        Task { @MainActor in
            self.isCapturing = true
            self.lastError = nil
            self.activeSources = [.microphone]
            self.micLevel = 0
        }

        appLog("Microphone-only capture started successfully")
    }

    // MARK: - Lane Setup Helpers

    /// Open the ScreenCaptureKit system-audio stream and wire it to the `.system` lane.
    private func startSystemAudioStream() async throws {
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
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = true  // Don't capture our own audio

        // Audio configuration
        streamConfig.sampleRate = Int(config.sampleRate)
        streamConfig.channelCount = config.channelCount

        // NOTE: ScreenCaptureKit's `captureMicrophone` / `.microphone` output stays
        // disabled deliberately. The mic lane uses AVAudioEngine instead so both
        // lanes keep clean, separately-tagged buffers (see startDualCapture).

        // Minimal video config (required even for audio-only)
        streamConfig.width = 2
        streamConfig.height = 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 FPS minimum

        // Create stream with delegate for error handling (e.g., display disconnect)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

        // Create and add output handler
        let output = AudioStreamOutput(
            sampleRate: config.sampleRate,
            channelCount: config.channelCount
        )
        output.onAudioBuffer = { [weak self] buffer in
            self?.processAudioBufferBackground(buffer, source: .system)
        }

        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: streamOutputQueue)

        // Register a screen output to avoid ScreenCaptureKit dropping frames when video is configured.
        let screenOutput = VideoStreamOutput()
        try stream.addStreamOutput(screenOutput, type: .screen, sampleHandlerQueue: streamOutputQueue)

        // Start the stream only after all outputs have been registered.
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
        self.videoOutput = screenOutput
    }

    /// Start the AVAudioEngine microphone lane, wired to the `.microphone` source.
    /// Caller must have ensured microphone TCC permission first
    /// (`ensureMicrophonePermission`) — unauthorized processes receive silent buffers.
    private func startMicrophoneEngine() throws {
        // Never stack engines: a previous session's engine/tap must go first.
        if audioEngine != nil {
            teardownMicrophoneEngine()
        }
        micSilenceDetector.reset()

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        // Apply the configured input device BEFORE reading the native format —
        // kAudioOutputUnitProperty_CurrentDevice changes what the input node runs.
        var effectiveDevice = resolveMicrophoneDevice()
        if let device = effectiveDevice, config.microphoneDeviceUID != nil {
            var deviceID = device.id
            let status = inputNode.audioUnit.map {
                AudioUnitSetProperty(
                    $0,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            } ?? -1
            if status != noErr {
                appLog("[AudioCaptureService] ⚠️ Could not select microphone \"\(device.name)\" (status \(status)); using the system default device instead")
                effectiveDevice = AudioInputDevices.systemDefaultInputDevice()
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.captureSetupFailed("No usable microphone input device")
        }
        appLog("Microphone native format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels, device: \(effectiveDevice?.name ?? "system default")")

        guard let converter = MicrophoneFormatConverter(
            inputFormat: inputFormat,
            targetSampleRate: config.sampleRate,
            targetChannels: config.channelCount
        ) else {
            throw AudioCaptureError.captureSetupFailed("Could not create microphone format converter")
        }

        // Tap the input node directly in its native format (same structure as
        // Apple's SpokenWord sample): no mixer and no output-volume node in the
        // data path, so the tap can't be muted by the graph and nothing is fed
        // back to the speakers.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            self?.processAudioBufferBackground(converted, source: .microphone)
        }

        // Start audio engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.captureSetupFailed("Could not start audio engine: \(error.localizedDescription)")
        }

        self.audioEngine = audioEngine
        self.activeMicrophoneDevice = effectiveDevice
        let deviceName = effectiveDevice?.name
        let deviceIsVirtual = effectiveDevice?.isVirtual ?? false
        Task { @MainActor in
            self.microphoneDeviceName = deviceName
            self.microphoneDeviceIsVirtual = deviceIsVirtual
        }
        appLog("Microphone engine started (device: \(effectiveDevice?.name ?? "system default"), \(Int(config.sampleRate))Hz mono)")
    }

    /// Pick the Core Audio input device for the mic lane: the configured UID
    /// when it still exists, otherwise the system default input device.
    private func resolveMicrophoneDevice() -> AudioInputDevice? {
        let devices = AudioInputDevices.listInputDevices()
        if let uid = config.microphoneDeviceUID {
            if let match = devices.first(where: { $0.uid == uid }) {
                return match
            }
            let fallback = devices.first(where: { $0.isSystemDefault })
            appLog("[AudioCaptureService] ⚠️ Configured microphone is no longer available; falling back to system default \"\(fallback?.name ?? "unknown")\"")
            return fallback
        }
        return devices.first(where: { $0.isSystemDefault })
    }

    /// Stop and clear the ScreenCaptureKit stream and the microphone engine,
    /// regardless of capture state. Idempotent — every exit path (user stop,
    /// SCStream error, failed start) funnels through here.
    private func teardownCapture() async {
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                appLog("[AudioCaptureService] Error stopping stream during teardown: \(error.localizedDescription)")
            }
            self.stream = nil
            self.streamOutput = nil
            self.videoOutput = nil
        }
        teardownMicrophoneEngine()
    }

    /// Stop the mic engine and remove its tap. Idempotent.
    private func teardownMicrophoneEngine() {
        guard let audioEngine else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
        self.activeMicrophoneDevice = nil
        Task { @MainActor in
            self.microphoneDeviceName = nil
            self.microphoneDeviceIsVirtual = false
        }
    }

    /// Stop capturing audio
    func stopCapture() async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        // Tear down unconditionally: an SCStream error flips isCapturing to
        // false while the mic engine may still be running.
        await teardownCapture()

        Task { @MainActor in
            self.isCapturing = false
            self.activeSources = []
            self.systemLevel = 0
            self.micLevel = 0
            self.audioLevel = 0
        }

        appLog("Audio capture stopped")
    }
    
    // MARK: - Handlers

    /// Meter ballistics: fast attack, slow decay (~0.05 per 66ms tick), so the
    /// bar jumps up instantly on sound and falls smoothly like an OBS meter.
    @MainActor
    private func applyMeterLevel(_ norm: Float, for source: AudioSource) {
        switch source {
        case .system:
            systemLevel = norm >= systemLevel ? norm : max(norm, systemLevel - 0.05)
        case .microphone:
            micLevel = norm >= micLevel ? norm : max(norm, micLevel - 0.05)
        }
        audioLevel = max(systemLevel, micLevel)
    }

    /// Process audio buffer - this is called from background thread, so we use nonisolated
    private func processAudioBufferBackground(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
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

            // Watch the mic lane for a session-long silent streak (usually a
            // wrong or idle input device); fires at most once per session, and
            // reports once when the lane recovers afterwards.
            if source == .microphone {
                switch micSilenceDetector.process(rms: rms, at: Date()) {
                case .none:
                    break
                case .silenceDetected:
                    Task { @MainActor [weak self] in
                        self?.onMicrophoneSilenceDetected?()
                    }
                case .audioResumed:
                    Task { @MainActor [weak self] in
                        self?.onMicrophoneAudioResumed?()
                    }
                }
            }

            // Log RMS occasionally to verify audio isn't silent (tagged by lane)
            if Int(Date().timeIntervalSince1970 * 10) % 50 == 0 {
                appLog("[AudioCaptureService] 🔊 [\(source.rawValue)] RMS level: \(rms)")
            }

            // Throttle UI meter updates to ~15Hz per lane — hopping to MainActor
            // for every 20ms buffer would flood the main thread.
            let now = Date().timeIntervalSince1970
            let last = source == .system ? lastSystemMeterUpdate : lastMicMeterUpdate
            if now - last >= 0.066 {
                if source == .system { lastSystemMeterUpdate = now } else { lastMicMeterUpdate = now }
                // Normalize to 0-1 range (assuming -60dB to 0dB range)
                let norm = max(0, min(1, (level + 60) / 60))
                Task { @MainActor [weak self] in
                    self?.applyMeterLevel(norm, for: source)
                }
            }
        }

        // IMPORTANT: Call onAudioBuffer directly from background thread
        // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe according to Apple documentation
        // Dispatching to main thread for every buffer causes main thread flooding and UI hangs
        onAudioBuffer?(buffer, source)
        
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
            // Stop everything — including the mic engine, which would otherwise
            // outlive the stream and leak until the next start overwrites it.
            await self.teardownCapture()
            self.isCapturing = false
            self.lastError = "Audio capture interrupted: \(error.localizedDescription). Please click Start to resume."

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
