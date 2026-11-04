import Foundation
import XCTest
@testable import LCTMac

// MARK: - Pure decision logic

final class OllamaRecoveryControllerTests: XCTestCase {

    func testController_ServiceHealthy_ProbesAgain() {
        var controller = OllamaRecoveryController()
        XCTAssertEqual(controller.step(for: .healthy), .probeAgain)
    }

    func testController_FirstOutage_RestartsWithBaseBackoff() {
        var controller = OllamaRecoveryController()
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 10, attempt: 1))
    }

    func testController_ConsecutiveOutages_BackoffDoubles() {
        var controller = OllamaRecoveryController()
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 10, attempt: 1))
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 20, attempt: 2))
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 40, attempt: 3))
    }

    func testController_FourthConsecutiveOutage_GivesUp() {
        var controller = OllamaRecoveryController()
        _ = controller.step(for: .serviceUnreachable)
        _ = controller.step(for: .serviceUnreachable)
        _ = controller.step(for: .serviceUnreachable)
        XCTAssertEqual(controller.step(for: .serviceUnreachable), .giveUp,
                       "three failed restarts must stop the automatic retries")
    }

    func testController_AfterGiveUp_NoMoreRestarts() {
        var controller = OllamaRecoveryController()
        for _ in 0..<4 { _ = controller.step(for: .serviceUnreachable) }
        XCTAssertEqual(controller.step(for: .serviceUnreachable), .probeAgain,
                       "after giving up the patrol only observes — it never restarts on its own again")
        XCTAssertEqual(controller.step(for: .serviceUnreachable), .probeAgain)
    }

    func testController_HealthyDuringRecovery_AnnouncesRecovered() {
        var controller = OllamaRecoveryController()
        _ = controller.step(for: .serviceUnreachable)
        XCTAssertEqual(controller.step(for: .healthy), .announceRecovered)
        XCTAssertEqual(controller.step(for: .healthy), .probeAgain,
                       "the recovery is announced exactly once")
    }

    func testController_HealthyAfterGiveUp_AnnouncesRecovered() {
        var controller = OllamaRecoveryController()
        for _ in 0..<4 { _ = controller.step(for: .serviceUnreachable) }
        XCTAssertEqual(controller.step(for: .healthy), .announceRecovered,
                       "a service that comes back after give-up (manual restart) is still announced")
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 10, attempt: 1),
                       "recovery resets the state — a later outage restarts the backoff from scratch")
    }

    func testController_ModelMissing_ReloadsModel() {
        var controller = OllamaRecoveryController()
        XCTAssertEqual(controller.step(for: .modelNotLoaded), .reloadModel)
        XCTAssertEqual(controller.step(for: .modelNotLoaded), .reloadModel,
                       "a still-missing model is reloaded again on the next tick")
    }

    func testController_ModelMissingDuringRecovery_ReloadsWithoutAnnouncing() {
        var controller = OllamaRecoveryController()
        _ = controller.step(for: .serviceUnreachable)
        XCTAssertEqual(controller.step(for: .modelNotLoaded), .reloadModel,
                       "right after a restart the model is gone — reload before announcing recovery")
        XCTAssertEqual(controller.step(for: .healthy), .announceRecovered)
    }

    func testController_CustomBaseBackoff_ScalesDelays() {
        var controller = OllamaRecoveryController(baseBackoff: 0.01)
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 0.01, attempt: 1))
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 0.02, attempt: 2))
        XCTAssertEqual(controller.step(for: .serviceUnreachable),
                       .restartService(delay: 0.04, attempt: 3))
    }
}

// MARK: - Embedded translation failure isolation

/// The app no longer patrols Ollama; failed embedded translation must leave
/// speech capture running, and explicit retry can recover in place.
@MainActor
final class TranslationFailureIsolationTests: XCTestCase {
    func testTranslationFailure_DoesNotStopSourceCaptionsOrLaunchOllama() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        translator.shouldFail = true
        let harness = CaptionOnlyTestHarness(settings: settings, translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("Source survives inference failure.")
        let failed = await harness.waitFor { harness.viewModel.segments.first?.state == .failed }

        XCTAssertTrue(failed)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.sourceText, "Source survives inference failure.")
        XCTAssertEqual(harness.network.value, 0)
        XCTAssertEqual(harness.launcher.launchServeCallCount, 0)
        XCTAssertEqual(harness.launcher.openAppCallCount, 0)
        await harness.viewModel.stop()
    }

    func testTranslationFailure_ExplicitRetryRecovers_WithoutRestartingSession() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        translator.shouldFail = true
        let harness = CaptionOnlyTestHarness(settings: settings, translator: translator)
        await harness.viewModel.start()
        let startedAt = harness.viewModel.sessionTranscript.startedAt
        harness.speech.emit("Failed translation source.")
        let failed = await harness.waitFor { harness.viewModel.segments.first?.state == .failed }
        XCTAssertTrue(failed)

        let attempts = translator.texts.count
        harness.speech.emit("Caption while translation stopped.")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(translator.texts.count, attempts, "a failed engine must not retry on every new caption")
        XCTAssertEqual(harness.viewModel.segments.last?.state, .captionOnly)

        translator.shouldFail = false
        await harness.viewModel.prepareTranslation()
        harness.speech.emit("Recovered translation source.")
        let recovered = await harness.waitFor {
            harness.viewModel.sessionTranscript.entries.last?.translatedText == "Translated: Recovered translation source."
        }

        XCTAssertTrue(recovered)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.sessionTranscript.startedAt, startedAt)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.count, 3)
        XCTAssertEqual(harness.network.value, 0)
        await harness.viewModel.stop()
    }
}
