import XCTest
import Foundation

/// Regression guard for the retained-history consent boundary: while history
/// is disabled, HistoryView must not load or display retained entries and its
/// export/clear actions must be unavailable; ViewModel history operations must
/// no-op so programmatic callers cannot read or write persisted caption text.
/// Enabling history must restore normal behavior (covered by the existing
/// HistoryService tests). Nothing here deletes retained history.
final class HistoryGatingTests: XCTestCase {

    private func source(of relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testHistoryViewDoesNotLoadRetainedEntriesWhenDisabled() throws {
        let viewSource = try source(of: "LCTMac/Views/HistoryView.swift")
        XCTAssertTrue(
            viewSource.contains("guard viewModel.settings.historyEnabled"),
            "loadHistory must refuse to read retained entries while history consent is disabled"
        )
    }

    func testHistoryViewActionsUnavailableWhenDisabled() throws {
        let viewSource = try source(of: "LCTMac/Views/HistoryView.swift")
        XCTAssertTrue(
            viewSource.contains(".disabled(!viewModel.settings.historyEnabled)"),
            "export/clear actions must be disabled while history consent is disabled, not only when the list is empty"
        )
    }

    func testViewModelHistoryOperationsNoOpWhenDisabled() throws {
        let vmSource = try source(of: "LCTMac/ViewModels/TranscriptionVM.swift")
        let gateCount = vmSource.components(separatedBy: "guard settings.historyEnabled").count - 1
        XCTAssertGreaterThanOrEqual(
            gateCount,
            5,
            "clear/load/search/delete/export must each defensively no-op while history consent is disabled"
        )
    }
}
