import Foundation
import Combine
@preconcurrency import AVFoundation
import Speech
import AppKit

/// Command-line diagnostic mode for speech recognition:
///
///   LCTMac --speech-selftest <audio-file> [--selftest-locale en-US] [--selftest-engine auto|sf|analyzer] [--selftest-output <path>]
///
/// Feeds an audio file through the exact same recognition lane used in
/// production (16kHz mono Float32, 20ms chunks, real-time pacing, 2s of
/// silence padding on both ends) and writes a JSON report, then terminates.
/// Never starts audio capture and never prompts for permission.
struct SpeechSelfTestOptions: Equatable {
    let audioPath: String
    let localeIdentifier: String
    let outputPath: String
    var engine: String = SelfTestEngineFlag.auto

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

        var engine = SelfTestEngineFlag.auto
        if let i = arguments.firstIndex(of: "--selftest-engine"), i + 1 < arguments.count {
            engine = arguments[i + 1]
        }

        return SpeechSelfTestOptions(audioPath: audioPath, localeIdentifier: locale, outputPath: output, engine: engine)
    }
}

/// Dual-channel diagnostic mode (replaces the throwaway dual spike):
///
///   LCTMac --speech-selftest-dual --selftest-a <file> --selftest-b <file>
///          --selftest-locale <A locale> [--selftest-locale-b <B locale>]
///          [--selftest-engine auto|sf|analyzer] --selftest-output <json>
///
/// Lane A is fed as .system, lane B as .microphone, from the same loop at
/// real-time pace; B starts 1.5s after A so the two lanes interleave. Both
/// lanes are padded to the same total length with 2s of leading silence and
/// enough trailing silence. Runs through the real engine implementations —
/// "auto" resolves exactly like the view model's selection.
struct SpeechDualSelfTestOptions: Equatable {
    let pathA: String
    let pathB: String
    let localeIdentifierA: String
    let localeIdentifierB: String
    let engine: String
    let outputPath: String

    /// Parse dual self-test arguments. Returns nil when `--speech-selftest-dual`
    /// is absent or either audio path is missing.
    static func parse(arguments: [String]) -> SpeechDualSelfTestOptions? {
        guard arguments.contains("--speech-selftest-dual") else { return nil }
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            let candidate = arguments[i + 1]
            // Another flag in the value slot means the value is missing.
            return candidate.hasPrefix("--") ? nil : candidate
        }
        guard let pathA = value("--selftest-a"), let pathB = value("--selftest-b") else { return nil }

        let localeA = value("--selftest-locale") ?? "en-US"
        return SpeechDualSelfTestOptions(
            pathA: pathA,
            pathB: pathB,
            localeIdentifierA: localeA,
            localeIdentifierB: value("--selftest-locale-b") ?? localeA,
            engine: value("--selftest-engine") ?? SelfTestEngineFlag.auto,
            outputPath: value("--selftest-output") ?? (pathA + ".dual-selftest.json")
        )
    }
}

/// Recognized values for --selftest-engine.
enum SelfTestEngineFlag {
    static let auto = "auto"
    static let sf = "sf"
    static let analyzer = "analyzer"
}

enum SelfTestEngineError: Error, Equatable, LocalizedError {
    case unknownEngine(String)
    case analyzerUnavailable

    var errorDescription: String? {
        switch self {
        case .unknownEngine(let flag):
            return "Unknown --selftest-engine '\(flag)'. Use one of: auto, sf, analyzer"
        case .analyzerUnavailable:
            return "The 'analyzer' engine needs macOS 26 or later; SpeechAnalyzer is not available on this system"
        }
    }
}

/// Resolution of the --selftest-engine flag, pure so it can be unit-tested.
enum SelfTestEngineSelection {
    static func resolve(flag: String, transcriberAvailable: Bool) throws -> SpeechEngineKind {
        switch flag {
        case SelfTestEngineFlag.auto:
            return SpeechEngineSelection.engineKind(transcriberEngineAvailable: transcriberAvailable)
        case SelfTestEngineFlag.sf:
            return .sfSpeechRecognizer
        case SelfTestEngineFlag.analyzer:
            guard transcriberAvailable else { throw SelfTestEngineError.analyzerUnavailable }
            return .speechTranscriber
        default:
            throw SelfTestEngineError.unknownEngine(flag)
        }
    }
}

/// Chunk layout of the two lanes in a dual self-test run (pure, testable).
struct DualFeedSchedule: Equatable {
    /// Silence chunks before lane A's clip.
    var leadChunksA: Int
    /// Silence chunks before lane B's clip (lead + the 1.5s interleave offset).
    var leadChunksB: Int
    /// Identical chunk count of both padded lanes.
    var totalChunks: Int
}

enum DualSelfTestSchedule {
    /// Lane B starts this many seconds after lane A so the lanes' recognition
    /// tasks interleave instead of starting together.
    static let defaultOffsetSecondsB: Double = 1.5

    /// A = lead + clipA, B = lead + offset + clipB, both padded with trailing
    /// silence to the same total: max(A, B) + lead.
    static func make(aChunkCount: Int, bChunkCount: Int, leadSilenceChunks: Int, offsetChunksB: Int) -> DualFeedSchedule {
        let leadA = leadSilenceChunks
        let leadB = leadSilenceChunks + offsetChunksB
        let total = max(leadA + aChunkCount, leadB + bChunkCount) + leadSilenceChunks
        return DualFeedSchedule(leadChunksA: leadA, leadChunksB: leadB, totalChunks: total)
    }
}

/// Field-wise max of two per-lane stat snapshots. The legacy engine's counters
/// are complete BEFORE stop() (afterwards its snapshot is empty), while the
/// SpeechAnalyzer engine's counters only become complete DURING stop() (the
/// async finalize flushes the remaining finals). Merging covers both.
enum SelfTestStatsMerge {
    static func merge(_ a: [AudioSource: LaneStats], _ b: [AudioSource: LaneStats]) -> [AudioSource: LaneStats] {
        var merged = a
        for (source, stats) in b {
            var m = merged[source] ?? LaneStats()
            m.resultCount = max(m.resultCount, stats.resultCount)
            m.finalCount = max(m.finalCount, stats.finalCount)
            m.errorCount = max(m.errorCount, stats.errorCount)
            m.error1110Count = max(m.error1110Count, stats.error1110Count)
            m.restartCount = max(m.restartCount, stats.restartCount)
            m.staleCallbackCount = max(m.staleCallbackCount, stats.staleCallbackCount)
            merged[source] = m
        }
        return merged
    }
}

/// JSON report written at the end of a self-test run. `finalTexts` may contain
/// recognized speech — allowed here because this file is an explicit,
/// user-requested diagnostic artifact; none of it goes to the log.
struct SpeechSelfTestReport: Codable, Equatable {
    var locale: String
    /// Engine that produced this report ("sf" or "analyzer").
    var engine: String = ""
    var finalTexts: [String] = []
    /// Latest text of every recognized segment, final or still partial — SF
    /// only emits isFinal on long pauses, so short clips may have no finals.
    var segmentTexts: [String] = []
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

/// One lane of a dual self-test report. Texts appear here for the same reason
/// as in SpeechSelfTestReport (explicit diagnostic artifact, never logged).
struct DualLaneReport: Codable, Equatable {
    /// Latest text of every recognized segment, in first-seen order.
    var segmentTexts: [String] = []
    var finalTexts: [String] = []
    var resultCount: Int = 0
    var finalCount: Int = 0
    var errorCount: Int = 0
    var error1110Count: Int = 0
    var restartCount: Int = 0
    var errors: [String] = []
}

/// JSON report of a dual-channel self-test run.
struct SpeechDualSelfTestReport: Codable, Equatable {
    var engine: String
    var localeA: String
    var localeB: String
    var laneA = DualLaneReport()
    var laneB = DualLaneReport()
    /// Engine-level errors that are not attributable to one lane.
    var runtimeErrors: [String] = []
    var elapsedSeconds: Double = 0
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
        let input = ConverterInput(buffer: sourceBuffer)
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if input.consumed {
                // Signal end of input (not .noDataNow) so the converter
                // flushes the resampler tail into the output buffer.
                outStatus.pointee = .endOfStream
                return nil
            }
            input.consumed = true
            outStatus.pointee = .haveData
            return input.buffer
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

    /// Build one padded lane: `lead` silence chunks, then the clip, then
    /// silence up to `total` chunks.
    static func buildPaddedLane(clip: [AVAudioPCMBuffer], lead: Int, total: Int, silence: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        (0 ..< total).map { i in
            let clipIndex = i - lead
            return (clipIndex >= 0 && clipIndex < clip.count) ? clip[clipIndex] : silence
        }
    }
}

/// Collects recognition results for the self-test reports. The engine delivers
/// on the MainActor, so no locking is needed.
@MainActor
private final class SelfTestResultCollector {
    private(set) var segmentOrder: [AudioSource: [UUID]] = [:]
    private(set) var segmentLatest: [UUID: String] = [:]
    private(set) var finalTexts: [AudioSource: [String]] = [:]
    private(set) var partialCount = 0
    private(set) var lastActivity = Date()

    var hasResults: Bool {
        segmentOrder.values.contains { !$0.isEmpty }
    }

    func record(_ result: TranscriptionResult) {
        if segmentLatest[result.id] == nil {
            segmentOrder[result.source, default: []].append(result.id)
        }
        segmentLatest[result.id] = result.text
        if result.isVolatile {
            partialCount += 1
        } else {
            finalTexts[result.source, default: []].append(result.text)
        }
        lastActivity = Date()
    }

    func noteSettleStart() {
        lastActivity = Date()
    }

    func segmentTexts(for source: AudioSource) -> [String] {
        (segmentOrder[source] ?? []).compactMap { segmentLatest[$0] }
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
        let kind = try SelfTestEngineSelection.resolve(
            flag: options.engine,
            transcriberAvailable: SpeechEngineAvailability.isTranscriberEngineAvailable
        )
        report.engine = kind.rawValue
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

        let engine = SpeechEngineFactory.makeEngine(kind: kind, language: language)
        let collector = SelfTestResultCollector()
        engine.onTranscription = { result in
            collector.record(result)
        }

        try await engine.start(sources: [.system], languages: [.system: language])
        appLog("[SpeechSelfTest] Engine \(kind.rawValue): feeding \(chunks.count) chunks in real time (~\(chunks.count / 50)s of audio)...")

        for chunk in chunks {
            engine.appendAudioBuffer(chunk, source: .system)
            try? await Task.sleep(nanoseconds: UInt64(SelfTestAudio.chunkDuration * 1_000_000_000))
        }

        // Let recognition settle: up to 5s, or break early once results have
        // gone quiet (if nothing was recognized at all, always wait the full
        // timeout so a slow recognizer still gets its chance).
        collector.noteSettleStart()
        let settleDeadline = Date().addingTimeInterval(Self.settleTimeoutSeconds)
        while Date() < settleDeadline {
            let quietFor = Date().timeIntervalSince(collector.lastActivity)
            if quietFor > Self.settleQuietSeconds, collector.hasResults { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let statsBeforeStop = engine.statsSnapshot()
        await engine.stop()
        let stats = SelfTestStatsMerge.merge(statsBeforeStop, engine.statsSnapshot())[.system]

        report.finalTexts = collector.finalTexts[.system] ?? []
        report.segmentTexts = collector.segmentTexts(for: .system)
        report.partialCount = collector.partialCount
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

/// Drives one dual-channel self-test run: lane A as .system, lane B as
/// .microphone, fed from the same loop at real-time pace. Always terminates
/// the app when done, with the report written to the requested output path.
@MainActor
final class SpeechDualSelfTestRunner {
    private static let settleTimeoutSeconds: Double = 5.0
    private static let settleQuietSeconds: Double = 2.0

    func run(options: SpeechDualSelfTestOptions) async {
        var report = SpeechDualSelfTestReport(
            engine: options.engine,
            localeA: options.localeIdentifierA,
            localeB: options.localeIdentifierB
        )
        let started = Date()
        do {
            try await execute(options: options, report: &report)
        } catch {
            report.error = error.localizedDescription
            appLog("[SpeechSelfTest] ❌ dual: \(error.localizedDescription)")
        }
        report.elapsedSeconds = (Date().timeIntervalSince(started) * 10).rounded() / 10
        writeReport(report, to: options.outputPath)
        appLog("[SpeechSelfTest] Dual report written to \(options.outputPath); terminating")
        NSApp.terminate(nil)
    }

    private func execute(options: SpeechDualSelfTestOptions, report: inout SpeechDualSelfTestReport) async throws {
        // Fail fast without ever triggering a permission prompt.
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw SpeechSelfTestError.notAuthorized("\(status.rawValue)")
        }
        let kind = try SelfTestEngineSelection.resolve(
            flag: options.engine,
            transcriberAvailable: SpeechEngineAvailability.isTranscriberEngineAvailable
        )
        report.engine = kind.rawValue
        guard let languageA = SourceLanguage(rawValue: options.localeIdentifierA) else {
            throw SpeechSelfTestError.unsupportedLocale(options.localeIdentifierA)
        }
        guard let languageB = SourceLanguage(rawValue: options.localeIdentifierB) else {
            throw SpeechSelfTestError.unsupportedLocale(options.localeIdentifierB)
        }

        let chunksA = SelfTestAudio.chunk(try SelfTestAudio.loadAndConvert(url: URL(fileURLWithPath: options.pathA)).buffer)
        let chunksB = SelfTestAudio.chunk(try SelfTestAudio.loadAndConvert(url: URL(fileURLWithPath: options.pathB)).buffer)
        guard let silence = SelfTestAudio.makeSilenceChunk() else {
            throw SpeechSelfTestError.audioConversionFailed("could not allocate silence chunk")
        }
        let schedule = DualSelfTestSchedule.make(
            aChunkCount: chunksA.count,
            bChunkCount: chunksB.count,
            leadSilenceChunks: SelfTestAudio.silenceChunkCount,
            offsetChunksB: Int(DualSelfTestSchedule.defaultOffsetSecondsB / SelfTestAudio.chunkDuration)
        )
        let laneA = SelfTestAudio.buildPaddedLane(clip: chunksA, lead: schedule.leadChunksA, total: schedule.totalChunks, silence: silence)
        let laneB = SelfTestAudio.buildPaddedLane(clip: chunksB, lead: schedule.leadChunksB, total: schedule.totalChunks, silence: silence)

        let engine = SpeechEngineFactory.makeEngine(kind: kind, language: languageA)
        let collector = SelfTestResultCollector()
        engine.onTranscription = { result in
            collector.record(result)
        }
        var runtimeErrors: [String] = []
        let errorCancellable = engine.lastErrorPublisher
            .compactMap { $0 }
            .sink { runtimeErrors.append($0) }
        defer { errorCancellable.cancel() }

        try await engine.start(
            sources: [.system, .microphone],
            languages: [.system: languageA, .microphone: languageB]
        )
        appLog("[SpeechSelfTest] Dual (\(kind.rawValue)): feeding \(schedule.totalChunks) chunk pairs in real time (~\(schedule.totalChunks / 50)s)...")

        for i in 0 ..< schedule.totalChunks {
            engine.appendAudioBuffer(laneA[i], source: .system)
            engine.appendAudioBuffer(laneB[i], source: .microphone)
            try? await Task.sleep(nanoseconds: UInt64(SelfTestAudio.chunkDuration * 1_000_000_000))
        }

        // Let recognition settle (same policy as the single-lane self-test).
        collector.noteSettleStart()
        let settleDeadline = Date().addingTimeInterval(Self.settleTimeoutSeconds)
        while Date() < settleDeadline {
            let quietFor = Date().timeIntervalSince(collector.lastActivity)
            if quietFor > Self.settleQuietSeconds, collector.hasResults { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let statsBeforeStop = engine.statsSnapshot()
        await engine.stop()
        let stats = SelfTestStatsMerge.merge(statsBeforeStop, engine.statsSnapshot())
        let laneErrors = engine.laneErrorDescriptions

        report.laneA = SelfTestLaneReport.make(source: .system, collector: collector, stats: stats, laneErrors: laneErrors)
        report.laneB = SelfTestLaneReport.make(source: .microphone, collector: collector, stats: stats, laneErrors: laneErrors)
        report.runtimeErrors = runtimeErrors
    }

    private func writeReport(_ report: SpeechDualSelfTestReport, to path: String) {
        do {
            try report.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            appLog("[SpeechSelfTest] ❌ Failed to write dual report to \(path): \(error.localizedDescription)")
        }
    }
}

/// Maps one lane's collected results + stats into the JSON lane report.
@MainActor
private enum SelfTestLaneReport {
    static func make(
        source: AudioSource,
        collector: SelfTestResultCollector,
        stats: [AudioSource: LaneStats],
        laneErrors: [AudioSource: [String]]
    ) -> DualLaneReport {
        var lane = DualLaneReport()
        lane.segmentTexts = collector.segmentTexts(for: source)
        lane.finalTexts = collector.finalTexts[source] ?? []
        let laneStats = stats[source]
        lane.resultCount = laneStats?.resultCount ?? 0
        lane.finalCount = laneStats?.finalCount ?? 0
        lane.errorCount = laneStats?.errorCount ?? 0
        lane.error1110Count = laneStats?.error1110Count ?? 0
        lane.restartCount = laneStats?.restartCount ?? 0
        lane.errors = laneErrors[source] ?? []
        return lane
    }
}

/// Single-shot input for AVAudioConverter's pull block. The block runs
/// synchronously inside convert(to:error:withInputFrom:), so the unchecked
/// Sendable box is never touched concurrently.
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
