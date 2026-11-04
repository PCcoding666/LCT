import XCTest
@testable import LCTMac

/// Speech readiness is independent from optional translation preparation.
@MainActor
final class SpeechStatusTests: XCTestCase {
    func testSpeechStatus_CapturePauseResume_ReflectsListeningState() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        XCTAssertEqual(harness.viewModel.speechStatusText, "Listening")

        harness.viewModel.togglePause()
        XCTAssertEqual(harness.viewModel.speechStatusText, "Paused")

        harness.viewModel.togglePause()
        XCTAssertEqual(harness.viewModel.speechStatusText, "Listening")
        await harness.viewModel.stop()
    }

    func testSpeechStatus_SpeechModelDownload_IsSeparateFromTranslationState() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        let translationStatus = harness.viewModel.translationStatusText

        harness.speech.onModelDownloadStatus?(.japanese)

        XCTAssertEqual(harness.viewModel.speechStatusText, "Preparing resources")
        XCTAssertEqual(harness.viewModel.translationStatusText, translationStatus)
        XCTAssertFalse(harness.viewModel.isTranslationReady)

        harness.speech.onModelDownloadStatus?(nil)
        XCTAssertEqual(harness.viewModel.speechStatusText, "Listening")
        await harness.viewModel.stop()
    }

    func testSpeechStatus_ASRFailure_ShowsUnavailable() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()

        harness.speech.emitError("The recognizer stopped unexpectedly.")
        let unavailable = await harness.waitFor {
            harness.viewModel.speechStatusText == "Unavailable"
        }

        XCTAssertTrue(unavailable)
        await harness.viewModel.stop()
    }

    func testSpeechStatus_ASRErrorCleared_ReturnsToListening() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emitError("Temporary recognition failure.")
        let unavailable = await harness.waitFor { harness.viewModel.speechStatusText == "Unavailable" }
        XCTAssertTrue(unavailable)

        harness.speech.emitError(nil)
        let recovered = await harness.waitFor { harness.viewModel.speechStatusText == "Listening" }

        XCTAssertTrue(recovered)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        await harness.viewModel.stop()
    }

    func testSpeechStatus_TranslationFailure_StillShowsListening() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        translator.shouldFail = true
        let harness = CaptionOnlyTestHarness(settings: settings, translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("Original speech continues.")

        let translationFailed = await harness.waitFor {
            harness.viewModel.segments.first?.state == .failed
        }

        XCTAssertTrue(translationFailed)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.speechStatusText, "Listening")
        XCTAssertFalse(harness.viewModel.isTranslationReady)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.sourceText, "Original speech continues.")
        await harness.viewModel.stop()
    }

    func testSpeechStatus_IdleInstalledSelectedLanguage_ShowsReady() async {
        let harness = CaptionOnlyTestHarness()
        harness.speech.availability = [.english: .installed, .japanese: .unsupported]

        await harness.viewModel.refreshLanguageAvailability()

        XCTAssertEqual(harness.viewModel.speechStatusText, "Ready")
        XCTAssertTrue(harness.speech.startedSources.isEmpty)
    }

    func testSpeechStatus_IdleDownloadableSelectedLanguage_ShowsResourcesNeeded() async {
        let harness = CaptionOnlyTestHarness()
        harness.speech.availability = [.english: .downloadable, .japanese: .installed]

        await harness.viewModel.refreshLanguageAvailability()

        XCTAssertEqual(harness.viewModel.speechStatusText, "Resources needed")
        XCTAssertTrue(harness.speech.startedSources.isEmpty)
    }

    func testSpeechStatus_IdleUnsupportedSelectedLanguage_ShowsUnavailable() async {
        let harness = CaptionOnlyTestHarness()
        harness.speech.availability = [.english: .unsupported, .japanese: .installed]

        await harness.viewModel.refreshLanguageAvailability()

        XCTAssertEqual(harness.viewModel.speechStatusText, "Unavailable")
        XCTAssertTrue(harness.speech.startedSources.isEmpty)
    }

    func testSpeechStatus_DualLaneSecondaryLanguageUnsupported_ShowsUnavailable() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.captureMicrophone = true
        settings.microphoneSourceLanguage = .japanese
        let harness = CaptionOnlyTestHarness(settings: settings)
        harness.speech.availability = [.english: .installed, .japanese: .unsupported]

        await harness.viewModel.refreshLanguageAvailability()

        XCTAssertEqual(harness.viewModel.speechStatusText, "Unavailable")
        XCTAssertTrue(harness.speech.startedSources.isEmpty, "readiness must not start capture or request microphone permission")
    }

    func testSpeechStatus_LegacyDualLaneDegradesToSystem_IgnoresDroppedMicLanguage() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.captureMicrophone = true
        settings.microphoneSourceLanguage = .japanese
        let harness = CaptionOnlyTestHarness(settings: settings, speechKind: .sfSpeechRecognizer)
        harness.speech.availability = [.english: .installed, .japanese: .unsupported]

        await harness.viewModel.refreshLanguageAvailability()

        XCTAssertEqual(harness.viewModel.speechStatusText, "Ready")
        XCTAssertTrue(harness.speech.startedSources.isEmpty)
    }
}
