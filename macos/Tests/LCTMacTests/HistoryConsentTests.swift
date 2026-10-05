import XCTest
import Foundation
@testable import LCTMac

/// Guards the privacy contract for translation history:
/// history is opt-in and default-disabled for fresh installs and for existing
/// installs whose saved settings carry no explicit consent decision.
final class HistoryConsentTests: XCTestCase {

    func testHistoryIsDisabledByDefaultForFreshInstalls() {
        XCTAssertFalse(AppSettings().historyEnabled, "history must be opt-in: default settings must not enable it")
    }

    func testHistoryIsDisabledWhenConsentKeyIsMissing() throws {
        // Simulates an existing installation whose saved settings predate the
        // consent field: the JSON has history limits but no consent decision.
        let legacyJSON = """
        {
            "historyRetentionDays": 30,
            "historyMaxEntries": 5000,
            "sourceLanguage": "en-US",
            "targetLanguage": "Chinese"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(settings.historyEnabled, "missing consent key must decode as disabled, never as consent")
    }

    func testExplicitConsentIsHonored() throws {
        let enabledJSON = """
        { "historyEnabled": true }
        """
        let enabled = try JSONDecoder().decode(AppSettings.self, from: Data(enabledJSON.utf8))
        XCTAssertTrue(enabled.historyEnabled, "an explicit opt-in must be preserved")

        let disabledJSON = """
        { "historyEnabled": false }
        """
        let disabled = try JSONDecoder().decode(AppSettings.self, from: Data(disabledJSON.utf8))
        XCTAssertFalse(disabled.historyEnabled, "an explicit opt-out must be preserved")
    }

    func testSettingsUIOffersInformedConsentToggle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LCTMac/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("historyEnabled"),
            "Settings must expose a history consent toggle bound to historyEnabled"
        )
        XCTAssertTrue(
            source.contains("stored on this Mac"),
            "the consent toggle must carry informed-consent copy about local storage"
        )
    }
}
