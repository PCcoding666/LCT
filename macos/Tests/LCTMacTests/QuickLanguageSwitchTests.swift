import XCTest
import Combine
import AVFoundation
@testable import LCTMac

/// Tests for the quick language switch feature: the HUD language menu, its
/// label formatting, the language-availability mapping, and the view model's
/// live per-lane restart routing. Everything is stubbed — no real
/// recognition, model download, permission prompt, or network.
@MainActor
final class QuickLanguageSwitchTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeSpeechEngine: SpeechRecognitionEngine {
        let kind: SpeechEngineKind = .speechTranscriber
        var onTranscription: ((TranscriptionResult) -> Void)?
        private let lastErrorSubject = CurrentValueSubject<String?, Never>(nil)
        var lastErrorPublisher: AnyPublisher<String?, Never> {
            lastErrorSubject.eraseToAnyPublisher()
        }
        var onModelDownloadStatus: ((SourceLanguage?) -> Void)?
        private(set) var currentLanguage: SourceLanguage = .english
        private(set) var restartedLanes: [(source: AudioSource, language: SourceLanguage)] = []
        var availability: [SourceLanguage: LanguageAvailability] = [:]

        func setLanguage(_ language: SourceLanguage) {
            currentLanguage = language
        }

        func start(sources: [AudioSource], languages: [AudioSource: SourceLanguage]) async throws {}

        func stop() async {}

        func restartLane(_ source: AudioSource, language: SourceLanguage) async throws {
            restartedLanes.append((source, language))
        }

        func languageAvailability() async -> [SourceLanguage: LanguageAvailability] {
            availability
        }

        nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, source: AudioSource) {}

        func statsSnapshot() -> [AudioSource: LaneStats] { [:] }
    }

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    /// A "capturing" view model with a fake engine. The capture state and
    /// running recognition lanes are set directly — no audio, Ollama, or
    /// recognition is touched.
    private func makeCapturingViewModel(
        settings: AppSettings = AppSettings(),
        sources: [AudioSource] = [.system, .microphone]
    ) -> (TranscriptionViewModel, FakeSpeechEngine) {
        let engine = FakeSpeechEngine()
        let viewModel = TranscriptionViewModel(settings: settings, speechEngine: engine)
        viewModel.captureState = .capturing
        viewModel.recognitionLanes = sources
        return (viewModel, engine)
    }

    /// Poll until `condition` holds or the deadline passes; returns the final value.
    private func waitFor(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - Label formatting

    func testLanguageLabel_SameLanguages_ShowsCompactForm() {
        XCTAssertEqual(
            LanguageLabel.format(system: .chinese, microphone: nil, target: .english, microphoneActive: true),
            "ZH → EN"
        )
    }

    func testLanguageLabel_ExplicitSameMicLanguage_ShowsCompactForm() {
        XCTAssertEqual(
            LanguageLabel.format(system: .chinese, microphone: .chinese, target: .english, microphoneActive: true),
            "ZH → EN"
        )
    }

    func testLanguageLabel_DifferentMicLanguage_ShowsPerLaneForm() {
        XCTAssertEqual(
            LanguageLabel.format(system: .chinese, microphone: .english, target: .english, microphoneActive: true),
            "SYS ZH · MIC EN → EN"
        )
    }

    func testLanguageLabel_MicInactive_ShowsCompactFormEvenWhenDifferent() {
        XCTAssertEqual(
            LanguageLabel.format(system: .chinese, microphone: .english, target: .english, microphoneActive: false),
            "ZH → EN"
        )
    }

    func testListeningLabel_SameLanguages_ShowsSingleLanguage() {
        XCTAssertEqual(
            LanguageLabel.listening(system: .chinese, microphone: nil, microphoneActive: true),
            "// listening (ZH)…"
        )
    }

    func testListeningLabel_DifferentLanguages_ShowsPerLaneForm() {
        XCTAssertEqual(
            LanguageLabel.listening(system: .chinese, microphone: .english, microphoneActive: true),
            "// listening (SYS ZH · MIC EN)…"
        )
    }

    // MARK: - Availability mapping

    func testLanguageAvailability_SupportedAndInstalled_IsInstalled() {
        XCTAssertEqual(LanguageAvailability(isSupported: true, isInstalled: true), .installed)
    }

    func testLanguageAvailability_SupportedNotInstalled_IsDownloadable() {
        XCTAssertEqual(LanguageAvailability(isSupported: true, isInstalled: false), .downloadable)
    }

    func testLanguageAvailability_NotSupported_IsUnsupported() {
        XCTAssertEqual(LanguageAvailability(isSupported: false, isInstalled: false), .unsupported)
    }

    // MARK: - Lane restart routing while capturing

    func testSetSourceLanguage_CapturingSystemChangeWithFollowingMic_RestartsBothLanes() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)

        await viewModel.setSourceLanguage(.english, for: .system)

        XCTAssertEqual(engine.restartedLanes.map(\.source), [.system, .microphone],
                       "the mic lane follows the system language, so its effective language changed too")
        XCTAssertEqual(engine.restartedLanes.map(\.language), [.english, .english])
        XCTAssertEqual(viewModel.settings.sourceLanguage, .english)
    }

    func testSetSourceLanguage_CapturingSystemChangeWithExplicitMic_RestartsSystemLaneOnly() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        settings.microphoneSourceLanguage = .japanese
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)

        await viewModel.setSourceLanguage(.english, for: .system)

        XCTAssertEqual(engine.restartedLanes.map(\.source), [.system])
        XCTAssertEqual(viewModel.settings.language(for: .microphone), .japanese,
                       "the explicit mic language must survive a system-language change")
    }

    func testSetSourceLanguage_CapturingMicChange_RestartsMicLaneOnly() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)

        await viewModel.setSourceLanguage(.english, for: .microphone)

        XCTAssertEqual(engine.restartedLanes.map(\.source), [.microphone])
        XCTAssertEqual(engine.restartedLanes.first?.language, .english)
        XCTAssertEqual(viewModel.settings.microphoneSourceLanguage, .english)
    }

    func testSetSourceLanguage_CapturingMicResetToFollow_RestartsMicWithSystemLanguage() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        settings.microphoneSourceLanguage = .english
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)

        await viewModel.setSourceLanguage(nil, for: .microphone)

        XCTAssertEqual(engine.restartedLanes.map(\.source), [.microphone])
        XCTAssertEqual(engine.restartedLanes.first?.language, .chinese,
                       "back to 'same as system audio' means the mic now recognizes the system language")
        XCTAssertNil(viewModel.settings.microphoneSourceLanguage)
    }

    func testSetTargetLanguage_Capturing_DoesNotRestartLanes() {
        let (viewModel, engine) = makeCapturingViewModel()

        viewModel.setTargetLanguage(.japanese)

        XCTAssertTrue(engine.restartedLanes.isEmpty, "translation language applies to new translations only")
        XCTAssertEqual(viewModel.settings.targetLanguage, .japanese)
    }

    func testSetSourceLanguage_Idle_SavesWithoutRestarting() async {
        let engine = FakeSpeechEngine()
        let viewModel = TranscriptionViewModel(settings: AppSettings(), speechEngine: engine)

        await viewModel.setSourceLanguage(.japanese, for: .system)

        XCTAssertTrue(engine.restartedLanes.isEmpty, "nothing restarts while idle — the next start() picks it up")
        XCTAssertEqual(viewModel.settings.sourceLanguage, .japanese)
        XCTAssertEqual(AppSettings.load().sourceLanguage, .japanese, "the change must persist")
    }

    func testSetSourceLanguage_CapturingLaneNotRunning_SkipsRestart() async {
        // The legacy single-task engine drops the mic lane; only .system runs.
        let (viewModel, engine) = makeCapturingViewModel(sources: [.system])

        await viewModel.setSourceLanguage(.english, for: .microphone)

        XCTAssertTrue(engine.restartedLanes.isEmpty, "a lane that isn't running can't restart")
        XCTAssertEqual(viewModel.settings.microphoneSourceLanguage, .english,
                       "the setting still applies — it takes effect on the next start()")
    }

    // MARK: - Draft flush on lane restart

    func testSetSourceLanguage_UncommittedDraft_FlushesAsCaption() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)
        viewModel.isPaused = true  // paused: nothing is enqueued for translation

        engine.onTranscription?(TranscriptionResult(text: "hello world", isVolatile: true, source: .microphone))
        XCTAssertTrue(viewModel.liveSourceText.contains("hello world"), "test setup: the draft must be live")

        await viewModel.setSourceLanguage(.english, for: .microphone)

        XCTAssertTrue(
            viewModel.segments.contains { $0.sourceText == "hello world" && $0.source == .microphone },
            "the old task's uncommitted draft becomes a caption instead of being dropped"
        )
        XCTAssertEqual(viewModel.liveSourceText, "", "the lane's live draft resets for the new task")
    }

    // MARK: - updateSettings integration

    func testUpdateSettings_CapturingLanguageChange_AppliesLiveWithoutRestartWarning() async {
        var settings = AppSettings()
        settings.sourceLanguage = .chinese
        let (viewModel, engine) = makeCapturingViewModel(settings: settings)

        var newSettings = settings
        newSettings.sourceLanguage = .english
        viewModel.updateSettings(newSettings)

        XCTAssertFalse(viewModel.notice?.message.contains("need a restart") ?? false,
                       "language changes apply live — no restart warning may appear")
        let restarted = await waitFor { engine.restartedLanes.count == 2 }
        XCTAssertTrue(restarted, "the settings-page path must restart the affected lanes too")
        XCTAssertEqual(engine.restartedLanes.map(\.source), [.system, .microphone])
    }

    func testUpdateSettings_CapturingTargetLanguageChange_DoesNotRestartOrWarn() async {
        let (viewModel, engine) = makeCapturingViewModel()

        var newSettings = viewModel.settings
        newSettings.targetLanguage = .japanese
        viewModel.updateSettings(newSettings)

        XCTAssertTrue(engine.restartedLanes.isEmpty)
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(viewModel.settings.targetLanguage, .japanese)
    }

    func testUpdateSettings_CapturingCaptureToggleChange_StillWarns() {
        let (viewModel, _) = makeCapturingViewModel()

        var newSettings = viewModel.settings
        newSettings.captureMicrophone = false
        viewModel.updateSettings(newSettings)

        XCTAssertTrue(viewModel.notice?.message.contains("need a restart") ?? false,
                      "non-language capture settings keep the restart warning")
    }
}
