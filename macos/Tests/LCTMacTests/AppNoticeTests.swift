import XCTest
@testable import LCTMac

final class AppNoticeTests: XCTestCase {

    // MARK: - Builders

    func testInfoBuilderAutoDismisses() {
        let notice = AppNotice.info("Loading…")
        XCTAssertEqual(notice.severity, .info)
        XCTAssertTrue(notice.autoDismiss)
        XCTAssertTrue(notice.actions.isEmpty)
    }

    func testWarningDefaultsToAutoDismiss() {
        XCTAssertTrue(AppNotice.warning("heads up").autoDismiss)
        XCTAssertFalse(AppNotice.warning("persist", autoDismiss: false).autoDismiss)
    }

    func testErrorDoesNotAutoDismissAndCarriesActions() {
        let notice = AppNotice.error("boom", actions: [.retryCapture, .openAppSettings])
        XCTAssertEqual(notice.severity, .error)
        XCTAssertFalse(notice.autoDismiss)
        XCTAssertEqual(notice.actions, [.retryCapture, .openAppSettings])
    }

    // MARK: - Identity

    func testEachNoticeHasUniqueID() {
        let a = AppNotice.error("same")
        let b = AppNotice.error("same")
        XCTAssertNotEqual(a, b, "Distinct constructions must differ so auto-dismiss targets the right instance")
        XCTAssertEqual(a, a)
    }

    // MARK: - Action labels

    func testPermissionActionsShareSystemSettingsLabel() {
        XCTAssertEqual(NoticeAction.openScreenRecordingSettings.label, "Open System Settings")
        XCTAssertEqual(NoticeAction.openMicrophoneSettings.label, "Open System Settings")
        XCTAssertEqual(NoticeAction.openSpeechRecognitionSettings.label, "Open System Settings")
    }

    func testActionLabelsAreDistinctWhereExpected() {
        XCTAssertEqual(NoticeAction.startOllama.label, "Start Ollama")
        XCTAssertEqual(NoticeAction.retryCapture.label, "Retry")
        XCTAssertEqual(NoticeAction.openAppSettings.label, "Settings")
    }

    func testActionIDsAreUnique() {
        let actions: [NoticeAction] = [
            .openScreenRecordingSettings, .openMicrophoneSettings,
            .openSpeechRecognitionSettings, .startOllama,
            .openAppSettings, .retryCapture,
        ]
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
    }

    // MARK: - ViewModel dispatch

    @MainActor
    func testDismissNoticeClearsIt() {
        let viewModel = TranscriptionViewModel()
        viewModel.notice = .error("boom")
        viewModel.dismissNotice()
        XCTAssertNil(viewModel.notice)
    }

    @MainActor
    func testRetryCaptureClearsNoticeImmediately() {
        let viewModel = TranscriptionViewModel()
        viewModel.notice = .error("boom", actions: [.retryCapture])
        // retryCapture clears the notice synchronously before the async start()
        viewModel.perform(.retryCapture)
        XCTAssertNil(viewModel.notice)
    }

    @MainActor
    func testOpenAppSettingsIsNoOpInViewModel() {
        let viewModel = TranscriptionViewModel()
        let original = AppNotice.error("config", actions: [.openAppSettings])
        viewModel.notice = original
        // The view intercepts .openAppSettings; the VM must leave state untouched
        viewModel.perform(.openAppSettings)
        XCTAssertEqual(viewModel.notice, original)
    }
}
