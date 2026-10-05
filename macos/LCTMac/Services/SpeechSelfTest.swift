import Foundation
import AVFoundation
import Speech
import AppKit

/// Command-line diagnostic mode for speech recognition:
///
///   LCTMac --speech-selftest <audio-file> [--selftest-locale en-US] [--selftest-output <path>]
///
/// Feeds an audio file through the exact same recognition lane used in
/// production (16kHz mono Float32, 20ms chunks, real-time pacing, 2s of
/// silence padding on both ends) and writes a JSON report, then terminates.
/// Never starts audio capture and never prompts for permission.
struct SpeechSelfTestOptions: Equatable {
    let audioPath: String
    let localeIdentifier: String
    let outputPath: String

    /// Parse self-test arguments. Returns nil when `--speech-selftest` is
    /// absent or has no audio path. `arguments` includes argv[0]
    /// (ProcessInfo.processInfo.arguments).
    static func parse(arguments: [String]) -> SpeechSelfTestOptions? {
        guard let flagIndex = arguments.firstIndex(of: "--speech-selftest"),
              flagIndex + 1 < arguments.count else { return nil }
        let audioPath = arguments[flagIndex + 1]
        // Another flag in the path slot means the audio path is missing.
        guard !audioPath.hasPrefix("--") else { return nil }

        var locale = "en-US"
        if let i = arguments.firstIndex(of: "--selftest-locale"), i + 1 < arguments.count {
            locale = arguments[i + 1]
        }

        var output = audioPath + ".selftest.json"
        if let i = arguments.firstIndex(of: "--selftest-output"), i + 1 < arguments.count {
            output = arguments[i + 1]
        }

        return SpeechSelfTestOptions(audioPath: audioPath, localeIdentifier: locale, outputPath: output)
    }
}

/// JSON report written at the end of a self-test run. `finalTexts` may contain
/// recognized speech — allowed here because this file is an explicit,
/// user-requested diagnostic artifact; none of it goes to the log.
struct SpeechSelfTestReport: Codable, Equatable {
    var locale: String
    var finalTexts: [String] = []
    var partialCount: Int = 0
    var error1110Count: Int = 0
    var restartCount: Int = 0
    var staleCallbacksDropped: Int = 0
    var durationSeconds: Double = 0
    var error: String?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

enum SpeechSelfTestError: Error, LocalizedError {
    case unsupportedLocale(String)
    case notAuthorized(String)
    case audioConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id):
            return "Unsupported locale '\(id)'. Use one of: \(SourceLanguage.allCases.map { $0.rawValue }.joined(separator: ", "))"
        case .notAuthorized(let status):
            return "Speech recognition not authorized (status \(status)). Grant permission in System Settings first."
        case .audioConversionFailed(let detail):
            return "Audio conversion failed: \(detail)"
        }
    }
}

/// Audio helpers for the self-test: 16kHz mono Float32 in 20ms chunks,
/// matching what the capture pipeline feeds in production.
enum SelfTestAudio {
    static let sampleRate: Double = 16_000
    static let chunkDuration: TimeInterval = 0.02
    static let silencePaddingSeconds: Double = 2.0

    static var framesPerChunk: AVAudioFrameCount {
        AVAudioFrameCount(sampleRate * chunkDuration) // 320
    }

    /// Silence chunks prepended/appended to cover "no audio yet" and
    /// "speaker finished, silence follows" scenarios.
    static var silenceChunkCount: Int {
        Int(silencePaddingSeconds / chunkDuration) // 100
    }

    static func makeTargetFormat() -> AVAudioFormat {
        // 16kHz mono Float32 non-interleaved — the canonical ASR input format.
        // Force-unwrap: this format combination is always valid.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Read an audio file and convert it to 16kHz mono Float32.
    static func loadAndConvert(url: URL) throws -> (buffer: AVAudioPCMBuffer, durationSeconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let targetFormat = makeTargetFormat()

        let frameCapacity = AVAudioFrameCount(max(file.length, 1))
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity) else {
            throw SpeechSelfTestError.audioConversionFailed("could not allocate source buffer")
        }
        try file.read(into: sourceBuffer)

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw SpeechSelfTestError.audioConversionFailed("no converter from \(file.processingFormat)")
        }
        let ratio = sampleRate / file.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw SpeechSelfTestError.audioConversionFailed("could not allocate converted buffer")
        }

        var conversionError: NSError?
        var sourceConsumed = false
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if sourceConsumed {
                // Signal end of input (not .noDataNow) so the converter
                // flushes the resampler tail into the output buffer.
                outStatus.pointee = .endOfStream
                return nil
            }
            sourceConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw SpeechSelfTestError.audioConversionFailed(conversionError.localizedDescription)
        }
        return (converted, duration)
    }

    /// Split a converted buffer into fixed-size 20ms chunks
    /// (the last chunk may be shorter).
    static func chunk(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard let sourceData = buffer.floatChannelData else { return [] }
        let format = buffer.format
        let perChunk = Int(framesPerChunk)
        let total = Int(buffer.frameLength)
        var chunks: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < total {
            let count = min(perChunk, total - offset)
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            chunkBuffer.frameLength = AVAudioFrameCount(count)
            if let dest = chunkBuffer.floatChannelData {
                memcpy(dest[0], sourceData[0] + offset, count * MemoryLayout<Float>.size)
            }
            chunks.append(chunkBuffer)
            offset += count
        }
        return chunks
    }

    /// One 20ms chunk of digital silence (all zeros).
    static func makeSilenceChunk() -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: makeTargetFormat(), frameCapacity: framesPerChunk) else { return nil }
        buffer.frameLength = framesPerChunk
        if let data = buffer.floatChannelData {
            memset(data[0], 0, Int(framesPerChunk) * MemoryLayout<Float>.size)
        }
        return buffer
    }
}

/// Drives one self-test run. Always terminates the app when done, with the
/// report written to the requested output path.
@MainActor
final class SpeechSelfTestRunner {
    /// Maximum time to wait for recognition to settle after the last chunk.
    private static let settleTimeoutSeconds: Double = 5.0
    /// Settle early once results have gone quiet for this long (but always
    /// wait the full timeout when nothing was recognized at all).
    private static let settleQuietSeconds: Double = 2.0

    func run(options: SpeechSelfTestOptions) async {
        var report = SpeechSelfTestReport(locale: options.localeIdentifier)
        do {
            try await execute(options: options, report: &report)
        } catch {
            report.error = error.localizedDescription
            appLog("[SpeechSelfTest] ❌ \(error.localizedDescription)")
        }
        writeReport(report, to: options.outputPath)
        appLog("[SpeechSelfTest] Report written to \(options.outputPath); terminating")
        NSApp.terminate(nil)
    }

    private func execute(options: SpeechSelfTestOptions, report: inout SpeechSelfTestReport) async throws {
        // Fail fast without ever triggering a permission prompt.
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw SpeechSelfTestError.notAuthorized("\(status.rawValue)")
        }
        guard let language = SourceLanguage(rawValue: options.localeIdentifier) else {
            throw SpeechSelfTestError.unsupportedLocale(options.localeIdentifier)
        }

        let (converted, duration) = try SelfTestAudio.loadAndConvert(url: URL(fileURLWithPath: options.audioPath))
        report.durationSeconds = (duration * 100).rounded() / 100

        var chunks: [AVAudioPCMBuffer] = []
        for _ in 0 ..< SelfTestAudio.silenceChunkCount {
            if let silence = SelfTestAudio.makeSilenceChunk() { chunks.append(silence) }
        }
        chunks.append(contentsOf: SelfTestAudio.chunk(converted))
        for _ in 0 ..< SelfTestAudio.silenceChunkCount {
            if let silence = SelfTestAudio.makeSilenceChunk() { chunks.append(silence) }
        }

        let service = SpeechAnalyzerService(language: language)
        var finalTexts: [String] = []
        var partialCount = 0
        var lastActivity = Date()
        service.onTranscription = { result in
            if result.isVolatile {
                partialCount += 1
            } else {
                finalTexts.append(result.text)
            }
            lastActivity = Date()
        }

        try await service.start(sources: [.system], languages: [.system: language])
        appLog("[SpeechSelfTest] Feeding \(chunks.count) chunks in real time (~\(chunks.count / 50)s of audio)...")

        for chunk in chunks {
            service.appendAudioBuffer(chunk, source: .system)
            try? await Task.sleep(nanoseconds: UInt64(SelfTestAudio.chunkDuration * 1_000_000_000))
        }

        // Let recognition settle: up to 5s, or break early once results have
        // gone quiet (if nothing was recognized at all, always wait the full
        // timeout so a slow recognizer still gets its chance).
        lastActivity = Date()
        let settleDeadline = Date().addingTimeInterval(Self.settleTimeoutSeconds)
        while Date() < settleDeadline {
            let quietFor = Date().timeIntervalSince(lastActivity)
            if quietFor > Self.settleQuietSeconds, partialCount + finalTexts.count > 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let stats = service.statsSnapshot()[.system]
        service.stop()

        report.finalTexts = finalTexts
        report.partialCount = partialCount
        report.error1110Count = stats?.error1110Count ?? 0
        report.restartCount = stats?.restartCount ?? 0
        report.staleCallbacksDropped = stats?.staleCallbackCount ?? 0
    }

    private func writeReport(_ report: SpeechSelfTestReport, to path: String) {
        do {
            try report.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            appLog("[SpeechSelfTest] ❌ Failed to write report to \(path): \(error.localizedDescription)")
        }
    }
}
