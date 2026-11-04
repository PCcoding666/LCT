import XCTest
import Combine
import AVFoundation
@testable import LCTMac

/// Isolated storage for view-model fixtures; never opens the user's history.
final class TemporaryHistoryDatabase {
    let directory: URL
    let service: HistoryService
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LCT-history-test-\(UUID().uuidString)", isDirectory: true)
        service = HistoryService(databasePath: directory.appendingPathComponent("history.sqlite").path)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Real view-model/capture wiring with hardware and external services replaced
/// at their boundaries. No permission prompts, user defaults, or real network.
@MainActor
final class CaptionOnlyTestHarness {
    class Translator: TranslationEngine {
        var ready = false
        var shouldFail = false
        private(set) var texts: [String] = []
        private(set) var settingsUpdates = 0
        func updateSettings(_ settings: AppSettings) { settingsUpdates += 1 }
        func translate(text: String, context: [TranslationEntry]) async throws -> (String, Int) {
            texts.append(text)
            if shouldFail { throw URLError(.cannotDecodeContentData) }
            return ("Translated: " + text, 1)
        }
        func translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int {
            let (output, elapsed) = try await translate(text: text, context: context)
            onToken(output)
            return elapsed
        }
    }
    final class Speech: SpeechRecognitionEngine {
        var kind: SpeechEngineKind = .speechTranscriber
        var onTranscription: ((TranscriptionResult) -> Void)?
        var onModelDownloadStatus: ((SourceLanguage?) -> Void)?
        var currentLanguage: SourceLanguage = .english
        var startedSources: [AudioSource] = []
        var availability: [SourceLanguage: LanguageAvailability] = [:]
        var stopCount = 0
        var onStop: (() -> Void)?
        nonisolated let buffers = NetworkCounter()
        private let errors = CurrentValueSubject<String?, Never>(nil)
        var lastErrorPublisher: AnyPublisher<String?, Never> { errors.eraseToAnyPublisher() }
        func setLanguage(_ language: SourceLanguage) { currentLanguage = language }
        func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws {
            startedSources = sources
        }
        func stop() async { stopCount += 1; onStop?() }
        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) { buffers.record() }
        func statsSnapshot() -> [AudioSource: LaneStats] { [:] }
        func restartLane(_ source: AudioSource, language: SourceLanguage) async throws {}
        func languageAvailability() async -> [SourceLanguage: LanguageAvailability] { availability }
        func emitError(_ error: String?) { errors.send(error) }
        func emit(_ text: String, isVolatile: Bool = false, taskID: UUID = UUID()) {
            onTranscription?(TranscriptionResult(id: taskID, text: text, isVolatile: isVolatile, source: .system))
        }
    }

    final class Tap: SystemAudioTapping, @unchecked Sendable {
        var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var onFirstCallback: (@Sendable () -> Void)?
        func start() throws { onFirstCallback?() }
        func stop() {}
    }

    final class NetworkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func record() { lock.lock(); defer { lock.unlock() }; count += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    final class RejectingProtocol: URLProtocol {
        nonisolated(unsafe) static var counter: NetworkCounter?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.counter?.record()
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        override func stopLoading() {}
    }

    let speech = Speech()
    let network = NetworkCounter()
    let launcher = FakeOllamaLauncher()
    let translator: Translator
    let capture: AudioCaptureService
    let historyDatabase = TemporaryHistoryDatabase()
    let viewModel: TranscriptionViewModel

    init(settings: AppSettings = CaptionOnlyTestHarness.settings(),
         translator: Translator = Translator(),
         hardware: HardwareProfile = .current(),
         speechKind: SpeechEngineKind = .speechTranscriber,
         historyService: HistoryService? = nil) {
        self.translator = translator
        speech.kind = speechKind
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectingProtocol.self]
        RejectingProtocol.counter = network
        let session = URLSession(configuration: configuration)
        let service = OllamaService(settings: settings, session: session)
        let guardian = OllamaGuardian(
            ollamaPath: "/not-installed/ollama", session: session,
            launcher: launcher, installationDetector: { .none }
        )
        capture = AudioCaptureService(makeSystemAudioTap: { Tap() })
        viewModel = TranscriptionViewModel(
            settings: settings, ollamaService: service, ollamaGuardian: guardian,
            hardwareProfile: hardware,
            audioCaptureService: capture,
            speechEngine: speech,
            translationEngine: translator,
            translationReadiness: { translator.ready },
            historyService: historyService ?? historyDatabase.service,
            persistSettings: { _ in true }
        )
    }

    func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    static func settings() -> AppSettings {
        var settings = AppSettings()
        settings.captureSystemAudio = true
        settings.captureMicrophone = false
        settings.historyEnabled = false
        return settings
    }
}

@MainActor
final class CaptionOnlyLifecycleTests: XCTestCase {
    func testCaptionOnly_StopWithTranslationReady_FlushesSourceWithoutStartingNewInference() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        settings.liveDraftTranslation = false
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        let harness = CaptionOnlyTestHarness(settings: settings, translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("Keep this without new inference", isVolatile: true)
        XCTAssertTrue(translator.texts.isEmpty)

        await harness.viewModel.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["Keep this without new inference"])
        XCTAssertEqual(harness.viewModel.segments.first?.state, .captionOnly)
        XCTAssertTrue(translator.texts.isEmpty, "stop must not start a new translation after cancelling pending work")
    }

    func testCaptionOnly_StopWithoutASRFinal_PreservesVisibleDraftOnce() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("An unfinished thought", isVolatile: true)
        XCTAssertEqual(harness.viewModel.liveSourceText, "An unfinished thought")
        XCTAssertTrue(harness.viewModel.sessionTranscript.entries.isEmpty)

        await harness.viewModel.stop()

        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["An unfinished thought"])
        XCTAssertEqual(harness.viewModel.segments.map(\.sourceText), ["An unfinished thought"])
        XCTAssertEqual(harness.viewModel.captureState, .idle)
    }

    func testCaptionOnly_StopWithASRFinal_DoesNotDuplicateVisibleDraft() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        let taskID = UUID()
        harness.speech.emit("An unfinished thought", isVolatile: true, taskID: taskID)
        harness.speech.onStop = { [weak speech = harness.speech] in
            speech?.emit("An unfinished thought", taskID: taskID)
        }

        await harness.viewModel.stop()

        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["An unfinished thought"])
        XCTAssertEqual(harness.viewModel.segments.map(\.sourceText), ["An unfinished thought"])
    }

    func testCaptionOnly_StopWhilePaused_PreservesDraftVisibleBeforePause() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Visible before pause", isVolatile: true)
        harness.viewModel.togglePause()
        harness.speech.emit("Ignored while paused", isVolatile: true)

        await harness.viewModel.stop()

        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["Visible before pause"])
        XCTAssertEqual(harness.viewModel.segments.map(\.sourceText), ["Visible before pause"])
    }

    func testCaptionOnly_InvalidLegacyEndpoint_StartsSystemCaptionsWithoutOllama() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.ollamaHost = "untrusted.example"
        settings.remoteOllamaOptIn = false
        let harness = CaptionOnlyTestHarness(settings: settings)

        await harness.viewModel.start()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.speech.startedSources, [.system])
        XCTAssertNotNil(harness.viewModel.sessionTranscript.startedAt)
        await harness.viewModel.stop()
        XCTAssertEqual(harness.network.value, 0, "init/start/stop must never probe the legacy service")
        XCTAssertTrue(harness.launcher.launchedProcesses.isEmpty)
    }

    func testCaptionOnly_FinalSpeech_IsExportableWithoutTranslation() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Only the original caption.")
        let transcript = harness.viewModel.sessionTranscript

        XCTAssertEqual(transcript.entries.map(\.sourceText), ["Only the original caption."])
        XCTAssertEqual(harness.viewModel.segments.first?.state, .captionOnly)
        XCTAssertEqual(transcript.entries.first?.translatedText, "")
        for format in SessionExporter.Format.allCases {
            let output = SessionExporter.export(transcript, format: format, sourceLanguages: "EN", targetLanguage: "ZH")
            XCTAssertTrue(output.contains("Only the original caption."))
        }
        await harness.viewModel.stop()
        XCTAssertEqual(harness.viewModel.sessionTranscript, transcript)
        XCTAssertTrue(harness.translator.texts.isEmpty)
    }

    func testCaptionOnly_TranslationBecomesReady_PreservesSessionAndTranslatesNewSpeech() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let harness = CaptionOnlyTestHarness(settings: settings)
        await harness.viewModel.start()
        harness.speech.emit("Before model load.")
        let startedAt = harness.viewModel.sessionTranscript.startedAt
        let originalID = harness.viewModel.sessionTranscript.entries.first?.id
        XCTAssertTrue(harness.translator.texts.isEmpty)

        harness.translator.ready = true
        harness.viewModel.updateSettings(settings)
        harness.speech.emit("After model load.")
        let translated = await harness.waitFor {
            harness.viewModel.sessionTranscript.entries.last?.translatedText == "Translated: After model load."
        }

        XCTAssertTrue(translated)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.sessionTranscript.startedAt, startedAt)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.id, originalID)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["Before model load.", "After model load."])
        XCTAssertEqual(harness.translator.texts, ["After model load."])
        await harness.viewModel.stop()
    }
}
