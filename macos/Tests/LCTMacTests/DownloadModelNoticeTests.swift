import XCTest
@testable import LCTMac

/// Download/preparation is independent from capture. Model transport and
/// integrity failures are exercised separately by LocalModelStoreTests.
@MainActor
final class DownloadModelNoticeTests: XCTestCase {
    func testStart_LegacyMLXModelOnIntel_StillStartsCaptions() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.ollamaModel = "qwen3.5:4b-mlx"
        let intel = HardwareProfile(isAppleSilicon: false, physicalMemoryBytes: 17_179_869_184, chipName: "Intel Core i7")
        let harness = CaptionOnlyTestHarness(settings: settings, hardware: intel)

        await harness.viewModel.start()
        harness.speech.emit("Hardware-independent captions.")

        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["Hardware-independent captions."])
        XCTAssertTrue(harness.translator.texts.isEmpty)
        await harness.viewModel.stop()
        XCTAssertEqual(harness.network.value, 0)
    }

    func testTranslationEnabled_ModelNotReady_RecordsSourceWithoutStartingDownload() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let harness = CaptionOnlyTestHarness(settings: settings)

        await harness.viewModel.start()
        harness.speech.emit("Read this while the model is unavailable.")

        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.segments.first?.state, .captionOnly)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.sourceText, "Read this while the model is unavailable.")
        XCTAssertTrue(harness.translator.texts.isEmpty)
        XCTAssertFalse(harness.viewModel.isTranslationReady)
        await harness.viewModel.stop()
        XCTAssertEqual(harness.network.value, 0)
    }

    func testTranslationDisabled_ReadyModel_DoesNotTranslateSpeech() async {
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        let harness = CaptionOnlyTestHarness(translator: translator)

        await harness.viewModel.start()
        harness.speech.emit("Translation is optional.")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.viewModel.segments.first?.state, .captionOnly)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.translatedText, "")
        XCTAssertTrue(translator.texts.isEmpty)
        await harness.viewModel.stop()
    }
}
