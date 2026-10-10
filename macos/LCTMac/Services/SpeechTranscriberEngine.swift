import Foundation
import Combine
@preconcurrency import AVFoundation
import os

#if compiler(>=6.2)
import Speech

/// Lane state shared between the MainActor (start/stop) and the audio threads
/// (appendAudioBuffer). Lock-protected; the continuation is yield-only here
/// and finished exactly once via `finishInput()`.
@available(macOS 26.0, *)
private final class TranscriberLaneBox: @unchecked Sendable {
    let source: AudioSource
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat
    private var _lock = os_unfair_lock()
    private let _converter: AVAudioConverter?
    private var _isActive = true
    private var _bufferCount = 0

    init(
        source: AudioSource,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter?
    ) {
        self.source = source
        self.continuation = continuation
        self.targetFormat = targetFormat
        self._converter = converter
    }

    /// Convert (if the analyzer wants a different format) and yield the buffer
    /// into the analyzer's input stream. Called from realtime audio threads.
    func append(_ buffer: AVAudioPCMBuffer) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard _isActive else { return }
        _bufferCount += 1
        let output: AVAudioPCMBuffer?
        if let converter = _converter {
            output = Self.convert(buffer, with: converter, to: targetFormat)
        } else {
            output = buffer
        }
        if let output {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    /// Stop accepting buffers and close the analyzer's input stream.
    func finishInput() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard _isActive else { return }
        _isActive = false
        continuation.finish()
    }

    /// Single-shot pull conversion, same pattern as MicrophoneFormatConverter:
    /// the input block hands the buffer over exactly once.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = max(AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16, 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let input = AnalyzerConverterInput(buffer: buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if input.consumed {
                status.pointee = .noDataNow
                return nil
            }
            input.consumed = true
            status.pointee = .haveData
            return input.buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

/// Single-shot input for AVAudioConverter's pull block. The block runs
/// synchronously inside convert(to:error:withInputFrom:), so the unchecked
/// Sendable box is never touched concurrently.
private final class AnalyzerConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var consumed = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Lock-protected map of the active lane boxes, readable from any thread.
/// Written on the MainActor (start/stop), read from audio threads (append).
@available(macOS 26.0, *)
private final class LockedLaneBoxes: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _boxes: [AudioSource: TranscriberLaneBox] = [:]

    func box(for source: AudioSource) -> TranscriberLaneBox? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _boxes[source]
    }

    func set(_ box: TranscriberLaneBox, for source: AudioSource) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _boxes[source] = box
    }

    func remove(for source: AudioSource) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _boxes[source] = nil
    }

    func removeAll() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        _boxes.removeAll()
    }
}

/// Speech recognition engine built on the macOS 26+ SpeechAnalyzer API: one
/// SpeechTranscriber + SpeechAnalyzer per capture lane. Unlike
/// SFSpeechRecognizer (one on-device task per process), the lanes recognize
/// truly concurrently and may use different languages.
@available(macOS 26.0, *)
@MainActor
final class SpeechTranscriberEngine: SpeechRecognitionEngine {
    // MARK: - SpeechRecognitionEngine

    let kind: SpeechEngineKind = .speechTranscriber
    @Published private(set) var lastError: String?
    @Published private(set) var currentLanguage: SourceLanguage
    var onTranscription: ((TranscriptionResult) -> Void)?
    var onModelDownloadStatus: ((SourceLanguage?) -> Void)?

    var lastErrorPublisher: AnyPublisher<String?, Never> {
        $lastError.eraseToAnyPublisher()
    }

    // MARK: - Private state

    /// MainActor-side record for one running lane.
    private struct LaneContext {
        let box: TranscriberLaneBox
        let analyzer: SpeechAnalyzer
        var mapper: TranscriberResultMapper
        var stats: LaneStats
        let resultsTask: Task<Void, Never>
    }

    private var lanes: [AudioSource: LaneContext] = [:]
    /// Stats of the most recently stopped session: stop() tears the lanes down
    /// but the self-test still needs the counters (finals flushed during the
    /// async teardown would otherwise be lost).
    private var lastSessionStats: [AudioSource: LaneStats] = [:]
    private var isRunning = false
    /// Monotonic per-lane restart counter. restartLane bumps it up front and
    /// re-checks it after every suspension point, so two overlapping restarts
    /// of the same lane can never both rebuild it — the stale one bows out.
    private var laneRestartGenerations: [AudioSource: Int] = [:]
    /// Lane-scoped error descriptions for diagnostics (messages only, never
    /// transcript content). Capped so a flapping lane can't grow memory.
    private var laneErrors: [AudioSource: [String]] = [:]
    private static let maxLaneErrorsKept = 20

    /// Thread-safe view of the active lanes for appendAudioBuffer.
    private let laneBoxes = LockedLaneBoxes()

    init(language: SourceLanguage = .english) {
        self.currentLanguage = language
        // Transcribers and analyzers are created per lane in start() so
        // nothing here touches model assets or privacy prompts.
    }

    /// Runtime gate used by SpeechEngineAvailability: the class exists
    /// (macOS 26 SDK) and the device actually supports the transcriber.
    nonisolated static var isAvailableOnThisDevice: Bool {
        SpeechTranscriber.isAvailable
    }

    // MARK: - Language

    func setLanguage(_ language: SourceLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        // Mirrors the legacy engine: changing the language mid-session tears
        // the lanes down; the caller decides whether to restart.
        if isRunning {
            Task { await self.stop() }
        }
    }

    // MARK: - Recognition control

    func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws {
        appLog("[SpeechTranscriberEngine] start() called for lanes: \(sources.map { $0.rawValue })")

        // Resolve every lane's locale up front so a configuration problem
        // fails before any lane starts.
        var laneLocales: [AudioSource: Locale] = [:]
        var laneLanguages: [AudioSource: SourceLanguage] = [:]
        for source in sources {
            let language = languages[source] ?? currentLanguage
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                lastError = "On-device speech recognition is not available for \(language.displayName)."
                appLog("[SpeechTranscriberEngine] ❌ No supported locale for \(language.displayName)")
                throw SpeechAnalyzerError.onDeviceRecognitionUnavailable
            }
            laneLocales[source] = locale
            laneLanguages[source] = language
        }

        // Make sure the on-device models are present, downloading per language
        // when needed. The download can take a while — the VM shows a
        // non-auto-dismissing info notice via onModelDownloadStatus.
        var transcribers: [AudioSource: SpeechTranscriber] = [:]
        for source in sources {
            guard let locale = laneLocales[source] else { continue }
            transcribers[source] = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        }
        let languagesInUse = Set(sources.compactMap { laneLanguages[$0] })
        for language in languagesInUse.sorted(by: { $0.rawValue < $1.rawValue }) {
            let modules = sources.compactMap { laneLanguages[$0] == language ? transcribers[$0] : nil }
            try await ensureAssetsInstalled(for: modules, language: language)
        }

        // Stop any existing recognition before starting fresh lanes.
        if isRunning {
            await stop()
        }

        do {
            for source in sources {
                guard let transcriber = transcribers[source] else { continue }
                try await startLane(source: source, transcriber: transcriber)
            }
        } catch {
            // A lane that fails to start must not leave its siblings running:
            // tear everything down so the next start begins from a clean state.
            await stop()
            throw error
        }

        isRunning = true
        lastError = nil
        appLog("[SpeechTranscriberEngine] ✅ Recognition started for \(sources.count) lane(s)")
    }

    private func ensureAssetsInstalled(for modules: [SpeechTranscriber], language: SourceLanguage) async throws {
        guard !modules.isEmpty else { return }
        let status = await AssetInventory.status(forModules: modules)
        appLog("[SpeechTranscriberEngine] Asset status for \(language.rawValue): \(status)")
        guard status < .installed else { return }

        onModelDownloadStatus?(language)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            let after = await AssetInventory.status(forModules: modules)
            appLog("[SpeechTranscriberEngine] Asset status after install for \(language.rawValue): \(after)")
        } catch {
            onModelDownloadStatus?(nil)
            lastError = "Failed to download the on-device speech model for \(language.displayName): \(error.localizedDescription)"
            appLog("[SpeechTranscriberEngine] ❌ Model download failed for \(language.rawValue)")
            throw SpeechAnalyzerError.onDeviceRecognitionUnavailable
        }
        onModelDownloadStatus?(nil)
    }

    private func startLane(source: AudioSource, transcriber: SpeechTranscriber) async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            lastError = "No compatible audio format for the \(source.rawValue) lane."
            throw SpeechAnalyzerError.recognizerUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        let inputFormat = Self.pipelineInputFormat
        let converter = inputFormat == format ? nil : AVAudioConverter(from: inputFormat, to: format)
        let box = TranscriberLaneBox(source: source, continuation: continuation, targetFormat: format, converter: converter)
        laneBoxes.set(box, for: source)

        // Created on the MainActor, so result handling below runs there too —
        // same delivery semantics as the legacy engine.
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handleTranscriberResult(result, source: source)
                }
            } catch {
                self?.handleTranscriberError(error, source: source)
            }
        }

        lanes[source] = LaneContext(box: box, analyzer: analyzer, mapper: TranscriberResultMapper(), stats: LaneStats(), resultsTask: resultsTask)
        appLog("[SpeechTranscriberEngine] ✅ [\(source.rawValue)] lane started (format: \(format.sampleRate)Hz, \(format.channelCount)ch)")
    }

    func stop() async {
        let activeLanes = lanes
        // Stop accepting audio right away, but keep `lanes` populated until
        // finalization is done: the analyzer delivers the last utterance's
        // final result during finalize, and handleTranscriberResult drops
        // results for lanes that are no longer registered.
        laneBoxes.removeAll()
        isRunning = false
        // Invalidate in-flight lane restarts: a restart resuming after stop()
        // must not rebuild a lane behind the caller's back.
        for source in Array(laneRestartGenerations.keys) {
            laneRestartGenerations[source]! += 1
        }

        for lane in activeLanes.values {
            lane.box.finishInput()
        }

        for (source, lane) in activeLanes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            await finalize(lane.analyzer, source: source)
            // Finishing the analyzer ends the results sequence; let the
            // consumer drain what is already queued before cancelling it.
            await drain(lane.resultsTask, source: source)
        }

        // Remove only the lanes this call finalized: a start() that ran while
        // we were awaiting may already have registered fresh lanes.
        var finishedLanes: [AudioSource: LaneContext] = [:]
        for (source, lane) in activeLanes {
            if let current = lanes[source], current.box === lane.box {
                finishedLanes[source] = current
                lanes[source] = nil
            }
        }

        if !finishedLanes.isEmpty {
            lastSessionStats = finishedLanes.mapValues { $0.stats }
            let summary = finishedLanes
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { source, lane in
                    "\(source.rawValue) results=\(lane.stats.resultCount) finals=\(lane.stats.finalCount) errors=\(lane.stats.errorCount)"
                }
                .joined(separator: " | ")
            appLog("[SpeechTranscriberEngine] stop() summary: \(summary)")
        }
    }

    /// Restart a single lane with a new recognition language; every other lane
    /// keeps running untouched. The lane goes through the same teardown as
    /// stop() (finish input, finalize ≤2s, drain results) and is then rebuilt
    /// with the new language, downloading its on-device model first when
    /// needed. A failure leaves the lane stopped and sets `lastError`.
    func restartLane(_ source: AudioSource, language: SourceLanguage) async throws {
        let generation = (laneRestartGenerations[source] ?? 0) + 1
        laneRestartGenerations[source] = generation
        appLog("[SpeechTranscriberEngine] [\(source.rawValue)] lane restart requested (language: \(language.rawValue))")

        // Single-lane scoped teardown, mirroring stop().
        if let lane = lanes[source] {
            laneBoxes.remove(for: source)
            lane.box.finishInput()
            await finalize(lane.analyzer, source: source)
            await drain(lane.resultsTask, source: source)
            // Remove only the lane this call finalized: a start() that ran
            // while we were awaiting may have registered a fresh lane.
            if let current = lanes[source], current.box === lane.box {
                lanes[source] = nil
            }
        }

        func superseded() -> Bool {
            !isRunning || laneRestartGenerations[source] != generation
        }

        // A stop() or a newer restart of this lane ran while we were awaiting.
        guard !superseded() else {
            appLog("[SpeechTranscriberEngine] ⏭ [\(source.rawValue)] lane restart superseded before rebuild")
            return
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            lastError = "On-device speech recognition is not available for \(language.displayName)."
            appLog("[SpeechTranscriberEngine] ❌ No supported locale for \(language.displayName)")
            throw SpeechAnalyzerError.onDeviceRecognitionUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        // Downloads the on-device model when missing (can take minutes — the
        // VM shows the download notice via onModelDownloadStatus).
        try await ensureAssetsInstalled(for: [transcriber], language: language)

        guard !superseded() else {
            appLog("[SpeechTranscriberEngine] ⏭ [\(source.rawValue)] lane restart superseded after asset install")
            return
        }

        try await startLane(source: source, transcriber: transcriber)
        lastError = nil
        appLog("[SpeechTranscriberEngine] ✅ [\(source.rawValue)] lane restarted (language: \(language.rawValue))")
    }

    /// Per-language on-device availability for the language menu: supported by
    /// SpeechTranscriber (possibly after a model download) or already installed.
    func languageAvailability() async -> [SourceLanguage: LanguageAvailability] {
        let installedLocales = await SpeechTranscriber.installedLocales
        var result: [SourceLanguage: LanguageAvailability] = [:]
        for language in SourceLanguage.allCases {
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale)
            let isInstalled = supported.map { installedLocales.contains($0) } ?? false
            result[language] = LanguageAvailability(isSupported: supported != nil, isInstalled: isInstalled)
        }
        return result
    }

    /// Flush remaining results, giving the analyzer at most 2 seconds before
    /// forcing an immediate finish.
    private func finalize(_ analyzer: SpeechAnalyzer, source: AudioSource) async {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    // A failed finalize still ends analysis — no force-cancel needed.
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let finalized = await group.next() ?? true
            if !finalized {
                appLog("[SpeechTranscriberEngine] ⚠️ [\(source.rawValue)] finalize timed out after 2s; cancelling analysis")
                await analyzer.cancelAndFinishNow()
            }
            group.cancelAll()
            while await group.next() != nil {}
        }
    }

    /// Wait (at most 1 second) for a lane's results consumer to finish
    /// delivering queued results, then make sure it is cancelled.
    private func drain(_ resultsTask: Task<Void, Never>, source: AudioSource) async {
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await resultsTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? true
            // The group waits for every child before returning, and awaiting
            // `resultsTask.value` ignores child cancellation — so on timeout
            // cancel the consumer itself, which ends its iteration.
            if !first {
                resultsTask.cancel()
            }
            group.cancelAll()
            return first
        }
        if !drained {
            appLog("[SpeechTranscriberEngine] ⚠️ [\(source.rawValue)] results did not drain within 1s; cancelling")
        }
        resultsTask.cancel()
    }

    nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        laneBoxes.box(for: source)?.append(buffer)
    }

    func statsSnapshot() -> [AudioSource: LaneStats] {
        lanes.isEmpty ? lastSessionStats : lanes.mapValues { $0.stats }
    }

    /// Lane-scoped error descriptions for diagnostics (messages only, never
    /// transcript content).
    var laneErrorDescriptions: [AudioSource: [String]] {
        laneErrors
    }

    // MARK: - Results

    private func handleTranscriberResult(_ result: SpeechTranscriber.Result, source: AudioSource) {
        guard var lane = lanes[source] else { return }
        lane.stats.resultCount += 1
        if result.isFinal {
            lane.stats.finalCount += 1
        }
        let text = String(result.text.characters)
        let start = result.range.start.seconds
        let end = (result.range.start + result.range.duration).seconds
        if let mapped = lane.mapper.map(text: text, isFinal: result.isFinal, start: start, end: end, source: source) {
            onTranscription?(mapped)
        }
        lanes[source] = lane
    }

    private func handleTranscriberError(_ error: Error, source: AudioSource) {
        // Errors arriving after stop()/restartLane() (cancelled results stream)
        // are expected teardown noise, not failures.
        guard !(error is CancellationError) else { return }
        guard isRunning, var lane = lanes[source] else { return }
        lane.stats.errorCount += 1
        lanes[source] = lane
        var errors = laneErrors[source] ?? []
        errors.append(error.localizedDescription)
        if errors.count > Self.maxLaneErrorsKept {
            errors.removeFirst(errors.count - Self.maxLaneErrorsKept)
        }
        laneErrors[source] = errors
        lastError = error.localizedDescription
        appLog("[SpeechTranscriberEngine] ⚠️ [\(source.rawValue)] results stream error: \(error.localizedDescription)")
    }

    /// The capture pipeline's canonical ASR input: 16kHz mono Float32.
    private static var pipelineInputFormat: AVAudioFormat {
        // Force-unwrap: this format combination is always valid.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }
}

#endif
