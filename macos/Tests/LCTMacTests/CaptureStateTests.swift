import XCTest
@testable import LCTMac

/// Tests for the capture state machine: start/stop re-entry guards and the
/// guarantee that every failed start lands back on .idle.
@MainActor
final class CaptureStateTests: XCTestCase {

    /// Settings that pass the endpoint check but enable no capture lane, so
    /// start() fails fast without touching any real service.
    private func noSourceSettings() -> AppSettings {
        var settings = AppSettings()
        settings.captureSystemAudio = false
        settings.captureMicrophone = false
        return settings
    }

    // MARK: - Derived isCapturing

    func testCaptureState_StateChanges_IsCapturingDerived() {
        let viewModel = CaptionOnlyTestHarness().viewModel
        XCTAssertFalse(viewModel.isCapturing)
        viewModel.captureState = .starting
        XCTAssertFalse(viewModel.isCapturing)
        viewModel.captureState = .capturing
        XCTAssertTrue(viewModel.isCapturing)
        viewModel.captureState = .stopping
        XCTAssertFalse(viewModel.isCapturing)
    }

    // MARK: - Failed starts return to .idle

    func testCaptureState_InvalidLegacyEndpoint_DoesNotBlockCaptions() async {
        var settings = CaptionOnlyTestHarness.settings()
        settings.ollamaHost = "192.168.1.100"
        settings.remoteOllamaOptIn = false
        let harness = CaptionOnlyTestHarness(settings: settings)

        await harness.viewModel.start()

        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.speech.startedSources, [.system])
        await harness.viewModel.stop()
    }

    func testCaptureState_NoAudioSourceEnabled_ReturnsToIdle() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.settings = noSourceSettings()

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .idle, "a failed start must return to idle")
        XCTAssertEqual(viewModel.notice?.severity, .error)
    }

    // MARK: - Re-entry guards

    func testCaptureState_StartWhileStarting_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.settings = noSourceSettings()
        viewModel.captureState = .starting
        let sentinel = AppNotice.warning("sentinel", autoDismiss: false)
        viewModel.notice = sentinel

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .starting, "the in-flight start must own the state")
        XCTAssertEqual(viewModel.notice, sentinel, "an ignored start must not touch the notice")
    }

    func testCaptureState_StartWhileCapturing_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.captureState = .capturing
        let sentinel = AppNotice.warning("sentinel", autoDismiss: false)
        viewModel.notice = sentinel

        await viewModel.start()

        XCTAssertEqual(viewModel.captureState, .capturing)
        XCTAssertEqual(viewModel.notice, sentinel)
    }

    func testCaptureState_StopWhileStarting_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.captureState = .starting

        await viewModel.stop()

        XCTAssertEqual(viewModel.captureState, .starting, "stop during startup must not tear down the half-started session")
    }

    func testCaptureState_StopWhileIdle_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel

        await viewModel.stop()

        XCTAssertEqual(viewModel.captureState, .idle)
    }

    func testCaptureState_StopFromCapturing_ReturnsToIdle() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.captureState = .capturing

        await viewModel.stop()

        XCTAssertEqual(viewModel.captureState, .idle)
    }

    // MARK: - toggleCapture routing

    func testCaptureState_ToggleWhileStarting_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.settings = noSourceSettings()
        viewModel.captureState = .starting
        let sentinel = AppNotice.warning("sentinel", autoDismiss: false)
        viewModel.notice = sentinel

        await viewModel.toggleCapture()

        XCTAssertEqual(viewModel.captureState, .starting)
        XCTAssertEqual(viewModel.notice, sentinel)
    }

    func testCaptureState_ToggleWhileStopping_IsIgnored() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.captureState = .stopping

        await viewModel.toggleCapture()

        XCTAssertEqual(viewModel.captureState, .stopping)
    }

    func testCaptureState_ToggleFromIdle_Starts() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.settings = noSourceSettings()

        await viewModel.toggleCapture()

        // The no-source configuration fails the start, proving toggle routed
        // into start(); the failure must land back on idle.
        XCTAssertEqual(viewModel.captureState, .idle)
        XCTAssertEqual(viewModel.notice?.severity, .error)
    }

    func testCaptureState_ToggleFromCapturing_Stops() async {
        let viewModel = CaptionOnlyTestHarness().viewModel
        viewModel.captureState = .capturing

        await viewModel.toggleCapture()

        XCTAssertEqual(viewModel.captureState, .idle)
    }
}
