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

// MARK: - Capture patrol (view model, stubbed network + fake launcher)

@MainActor
final class OllamaRecoveryPatrolTests: XCTestCase {

    private let state = OllamaStubState()
    private let launcher = FakeOllamaLauncher()

    override func setUp() {
        super.setUp()
        GuardianStubURLProtocol.state = state
        GuardianStubURLProtocol.chatDelay = 0
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        GuardianStubURLProtocol.state = nil
        GuardianStubURLProtocol.chatDelay = 0
        AppSettings.resetSetupFlag()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    private func makeViewModel(model: String = "model-a") -> TranscriptionViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuardianStubURLProtocol.self]
        var settings = AppSettings()
        settings.ollamaModel = model
        settings.ollamaTimeout = 1
        let service = OllamaService(settings: settings, session: URLSession(configuration: config))
        let guardian = OllamaGuardian(
            ollamaPath: "/fake/ollama",
            ollamaURL: "http://localhost:11434",
            session: URLSession(configuration: config),
            launcher: launcher,
            installationDetector: { .cli("/fake/ollama") },
            serveLogFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("LCTMacTests-ollama-\(UUID().uuidString).log"),
            startupPollInterval: 0.01,
            startupMaxAttempts: 5,
            stopGracePeriod: 0.1
        )
        return TranscriptionViewModel(settings: settings, ollamaService: service, ollamaGuardian: guardian)
    }

    /// Poll until `condition` holds or the deadline passes; returns the final value.
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Ollama dies mid-capture: the patrol warns, restarts it, re-warms the
    /// model and announces the recovery.
    func testPatrol_ServiceDiesDuringCapture_RestartsRewarmsAndRecovers() async {
        state.serviceUp = true
        state.loadedModels = ["model-a"]
        launcher.onLaunchServe = { [state] in state.serviceUp = true }
        let viewModel = makeViewModel()
        // Let the launch-time probe settle before the outage, so its result
        // can't race the patrol's notices.
        let connected = await waitFor { viewModel.isOllamaConnected }
        XCTAssertTrue(connected, "test setup: initial probe must succeed")
        viewModel.captureState = .capturing
        viewModel.startOllamaPatrol(interval: 0.05, backoffBase: 0.01)
        defer { viewModel.stopOllamaPatrol() }

        state.serviceUp = false
        state.loadedModels = []

        let warned = await waitFor {
            viewModel.notice?.severity == .warning
                && viewModel.notice?.message == "Ollama stopped responding — restarting…"
        }
        XCTAssertTrue(warned, "a dead service must surface the restarting warning")

        let recovered = await waitFor {
            viewModel.notice?.severity == .info
                && viewModel.notice?.message == "Ollama is back — translation resumed."
        }
        XCTAssertTrue(recovered, "a successful restart must announce the recovery")
        XCTAssertEqual(launcher.launchServeCallCount, 1, "the patrol restarts the service exactly once")
        XCTAssertGreaterThanOrEqual(state.chatRequestCount, 1,
                                    "the model must be re-warmed after the restart")
        XCTAssertEqual(viewModel.modelState, .loaded)
    }

    /// GUI regression: a failed translation surfaces an Ollama service error
    /// ("server not running") before the patrol notices the outage. The
    /// patrol must replace that error with its restarting warning and then
    /// with the recovery notice, instead of leaving a stale error on screen.
    func testPatrol_ServiceErrorShownFirst_ReplacedByRecoveryNotices() async {
        state.serviceUp = true
        state.loadedModels = ["model-a"]
        launcher.onLaunchServe = { [state] in state.serviceUp = true }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuardianStubURLProtocol.self]
        var settings = AppSettings()
        settings.ollamaModel = "model-a"
        settings.ollamaTimeout = 1
        let service = OllamaService(settings: settings, session: URLSession(configuration: config))
        let guardian = OllamaGuardian(
            ollamaPath: "/fake/ollama",
            ollamaURL: "http://localhost:11434",
            session: URLSession(configuration: config),
            launcher: launcher,
            installationDetector: { .cli("/fake/ollama") },
            serveLogFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("LCTMacTests-ollama-\(UUID().uuidString).log"),
            startupPollInterval: 0.01,
            startupMaxAttempts: 5,
            stopGracePeriod: 0.1
        )
        let viewModel = TranscriptionViewModel(settings: settings, ollamaService: service, ollamaGuardian: guardian)
        let connected = await waitFor { viewModel.isOllamaConnected }
        XCTAssertTrue(connected, "test setup: initial probe must succeed")
        viewModel.captureState = .capturing

        // Outage: a request fails before the patrol's first probe.
        state.serviceUp = false
        state.loadedModels = []
        _ = try? await service.prewarmModel()
        let errorShown = await waitFor { viewModel.notice?.severity == .error }
        XCTAssertTrue(errorShown, "test setup: the failed request must surface an error notice")

        viewModel.startOllamaPatrol(interval: 0.05, backoffBase: 0.01)
        defer { viewModel.stopOllamaPatrol() }

        let warned = await waitFor {
            viewModel.notice?.message == "Ollama stopped responding — restarting…"
        }
        XCTAssertTrue(warned, "the restarting warning must replace the Ollama service error")

        let recovered = await waitFor {
            viewModel.notice?.message == "Ollama is back — translation resumed."
        }
        XCTAssertTrue(recovered, "the recovery notice must not be blocked by the stale service error")
    }

    /// Ollama never comes back: three restart attempts, then an actionable
    /// error — and no further automatic restarts. When the service returns
    /// anyway, the patrol still announces the recovery.
    func testPatrol_ServiceStaysDown_GivesUpAfterThreeRestarts() async {
        state.serviceUp = true
        state.loadedModels = ["model-a"]
        let viewModel = makeViewModel()
        // Let the launch-time probe settle before the outage, so its result
        // can't race the patrol's notices.
        let connected = await waitFor { viewModel.isOllamaConnected }
        XCTAssertTrue(connected, "test setup: initial probe must succeed")
        viewModel.captureState = .capturing
        viewModel.startOllamaPatrol(interval: 0.05, backoffBase: 0.01)
        defer { viewModel.stopOllamaPatrol() }

        state.serviceUp = false
        state.loadedModels = []

        let gaveUp = await waitFor {
            viewModel.notice?.severity == .error
                && viewModel.notice?.message == "Ollama could not be restarted."
        }
        XCTAssertTrue(gaveUp, "three failed restarts must produce the give-up error")
        XCTAssertEqual(viewModel.notice?.actions, [.startOllama])
        XCTAssertEqual(launcher.launchServeCallCount, 3,
                       "exactly three restart attempts before giving up")

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(launcher.launchServeCallCount, 3,
                       "after giving up the patrol must not restart the service again")

        state.serviceUp = true
        state.loadedModels = ["model-a"]
        let recovered = await waitFor {
            viewModel.notice?.severity == .info
                && viewModel.notice?.message == "Ollama is back — translation resumed."
        }
        XCTAssertTrue(recovered, "a service that returns after give-up is still announced")
    }

    /// Ollama answers but dropped the model from memory: the patrol re-warms
    /// it without restarting anything.
    func testPatrol_ModelDroppedFromMemory_RewarmsWithoutRestart() async {
        state.serviceUp = true
        state.loadedModels = []
        GuardianStubURLProtocol.chatDelay = 0.2  // keep the reloading notice observable
        let viewModel = makeViewModel()
        viewModel.captureState = .capturing
        viewModel.startOllamaPatrol(interval: 0.05, backoffBase: 0.01)
        defer { viewModel.stopOllamaPatrol() }

        let reloading = await waitFor {
            viewModel.notice?.severity == .info
                && viewModel.notice?.message == "Reloading translation model…"
        }
        XCTAssertTrue(reloading, "a dropped model must surface the reloading notice")

        let reloaded = await waitFor { viewModel.modelState == .loaded }
        XCTAssertTrue(reloaded, "the model must be loaded again after the re-warm")
        XCTAssertGreaterThanOrEqual(state.chatRequestCount, 1)
        XCTAssertEqual(launcher.launchServeCallCount, 0,
                       "the service is up — nothing to restart")
        let settled = await waitFor { viewModel.notice == nil }
        XCTAssertTrue(settled, "the reloading notice is retracted once the model is back")
    }

    /// Stopping the capture stops the patrol: no more requests, no more
    /// notice changes.
    func testPatrol_CaptureStops_NoFurtherActions() async {
        state.serviceUp = true
        state.loadedModels = ["model-a"]
        let viewModel = makeViewModel()
        viewModel.captureState = .capturing
        viewModel.startOllamaPatrol(interval: 0.05, backoffBase: 0.01)

        try? await Task.sleep(nanoseconds: 150_000_000)
        await viewModel.stop()

        state.serviceUp = false
        state.loadedModels = []
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(launcher.launchServeCallCount, 0,
                       "a stopped patrol must not restart the service")
        XCTAssertEqual(state.chatRequestCount, 0,
                       "a stopped patrol must not prewarm the model")
        XCTAssertNil(viewModel.notice,
                     "a stopped patrol must not raise notices")
    }

    /// Status-light click with a failing startup surfaces an actionable error
    /// instead of being swallowed.
    func testStartOllamaFromIndicator_StartFails_SetsErrorNotice() async {
        state.serviceUp = true
        state.loadedModels = ["model-a"]
        let viewModel = makeViewModel()
        // Let the launch-time probe settle so its result can't race the
        // indicator's error notice.
        let connected = await waitFor { viewModel.isOllamaConnected }
        XCTAssertTrue(connected, "test setup: initial probe must succeed")

        state.serviceUp = false
        launcher.errorToThrow = NSError(domain: "test", code: 1, userInfo: nil)
        viewModel.startOllamaFromIndicator()

        let failed = await waitFor { viewModel.notice?.severity == .error }
        XCTAssertTrue(failed, "a failed indicator start must surface an error notice")
        XCTAssertEqual(viewModel.notice?.actions, [.startOllama])
        XCTAssertTrue(viewModel.notice?.message.hasPrefix("Could not start Ollama:") ?? false)
    }
}
