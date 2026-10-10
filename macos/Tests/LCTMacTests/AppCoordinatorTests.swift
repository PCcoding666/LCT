import XCTest
@testable import LCTMac

/// Records which capture entry point was called instead of touching any real
/// capture service.
@MainActor
private final class RecordingViewModel: TranscriptionViewModel {
    var onCall: ((String) -> Void)?

    override func start() async { onCall?("start") }
    override func stop() async { onCall?("stop") }
    override func toggleCapture() async { onCall?("toggleCapture") }
}

/// Stands in for the main window and onboarding state, and logs window and
/// capture calls in the order they happen.
@MainActor
private final class CoordinatorHarness {
    var events: [String] = []
    var windowVisible = false
    var setupComplete = true
    var createdViewModels: [RecordingViewModel] = []
    let notificationCenter = NotificationCenter()

    func makeCoordinator() -> AppCoordinator {
        let coordinator = AppCoordinator(
            notificationCenter: notificationCenter,
            isSetupComplete: { self.setupComplete },
            isMainWindowVisible: { self.windowVisible },
            makeViewModel: {
                let viewModel = RecordingViewModel()
                viewModel.onCall = { self.events.append($0) }
                self.createdViewModels.append(viewModel)
                return viewModel
            }
        )
        coordinator.setMainWindowOpener {
            self.events.append("showMainWindow")
            self.windowVisible = true
        }
        return coordinator
    }
}

/// Tests that start/stop, pause and settings commands reach the app's view
/// model whether or not the main window is open.
@MainActor
final class AppCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
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

    // MARK: - Notification decoding

    func testCaptureCommand_NotificationObject_MapsToStartStopToggle() {
        XCTAssertEqual(CaptureCommand(notificationObject: true), .start, "status bar Start Capture")
        XCTAssertEqual(CaptureCommand(notificationObject: false), .stop, "status bar Stop Capture")
        XCTAssertEqual(CaptureCommand(notificationObject: nil), .toggle, "Window menu / global hotkey")
        XCTAssertEqual(CaptureCommand(notificationObject: "unexpected"), .toggle)
    }

    // MARK: - Main window closed

    func testPerform_MainWindowClosed_ShowsWindowThenDelivers() async {
        let cases: [(CaptureCommand, String)] = [(.start, "start"), (.stop, "stop"), (.toggle, "toggleCapture")]
        for (command, expectedCall) in cases {
            let harness = CoordinatorHarness()
            let coordinator = harness.makeCoordinator()

            await coordinator.perform(command)

            XCTAssertEqual(harness.events, ["showMainWindow", expectedCall], "\(command)")
        }
    }

    /// The reported bug: with the main window closed nothing observed
    /// `.toggleCapture`, so the Window menu, status bar and hotkey did nothing.
    func testToggleCaptureNotification_MainWindowClosed_IsDelivered() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()

        harness.notificationCenter.post(name: .toggleCapture, object: nil)

        let delivered = await waitFor { harness.events == ["showMainWindow", "toggleCapture"] }
        XCTAssertTrue(delivered, "events: \(harness.events)")
        withExtendedLifetime(coordinator) {}
    }

    func testStartCaptureNotification_MainWindowClosed_StartsCapture() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()

        harness.notificationCenter.post(name: .toggleCapture, object: true)

        let delivered = await waitFor { harness.events == ["showMainWindow", "start"] }
        XCTAssertTrue(delivered, "events: \(harness.events)")
        withExtendedLifetime(coordinator) {}
    }

    // MARK: - Main window open

    func testPerform_MainWindowVisible_DeliversWithoutShowingWindow() async {
        let harness = CoordinatorHarness()
        harness.windowVisible = true
        let coordinator = harness.makeCoordinator()

        await coordinator.perform(.toggle)

        XCTAssertEqual(harness.events, ["toggleCapture"], "a visible window must not be re-activated (the hotkey works from other apps)")
    }

    // MARK: - Onboarding

    func testPerform_SetupNotCompleted_ShowsWindowWithoutCreatingViewModel() async {
        let harness = CoordinatorHarness()
        harness.setupComplete = false
        let coordinator = harness.makeCoordinator()

        await coordinator.perform(.start)

        XCTAssertEqual(harness.events, ["showMainWindow"], "onboarding is shown; there is no session to start")
        XCTAssertTrue(harness.createdViewModels.isEmpty, "the view model must load the settings onboarding saves, so it is created only afterwards")
    }

    // MARK: - View model lifetime

    func testViewModel_SurvivesMainWindowCloseAndReopen() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let firstViewModel = coordinator.viewModel

        await coordinator.perform(.start)
        harness.windowVisible = false // user closes the window mid-session
        await coordinator.perform(.stop)

        XCTAssertEqual(harness.events, ["showMainWindow", "start", "showMainWindow", "stop"])
        XCTAssertEqual(harness.createdViewModels.count, 1)
        XCTAssertTrue(coordinator.viewModel === firstViewModel, "the session must not be replaced when the window reopens")
    }

    // MARK: - Pause and settings

    func testTogglePauseNotification_MainWindowClosed_ReachesViewModel() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let viewModel = coordinator.viewModel
        XCTAssertFalse(viewModel.isPaused)

        harness.notificationCenter.post(name: .togglePause, object: nil)

        let paused = await waitFor { viewModel.isPaused }
        XCTAssertTrue(paused)
        XCTAssertTrue(harness.events.isEmpty, "pause must not bring the window back")
        withExtendedLifetime(coordinator) {}
    }

    func testSettingsDidChangeNotification_UpdatesExistingViewModel() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()
        let viewModel = coordinator.viewModel
        var newSettings = viewModel.settings
        newSettings.maxContextEntries += 1

        harness.notificationCenter.post(name: .settingsDidChange, object: newSettings)

        let applied = await waitFor { viewModel.settings == newSettings }
        XCTAssertTrue(applied)
        withExtendedLifetime(coordinator) {}
    }

    func testSettingsDidChangeNotification_NoViewModelYet_DoesNotCreateOne() async {
        let harness = CoordinatorHarness()
        let coordinator = harness.makeCoordinator()

        harness.notificationCenter.post(name: .settingsDidChange, object: AppSettings())
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(harness.createdViewModels.isEmpty, "a view model created later loads the saved settings itself")
        withExtendedLifetime(coordinator) {}
    }
}
