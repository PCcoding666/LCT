import XCTest
import Foundation
@testable import LCTMac

/// Guards the diagnostics contract: exports are metadata-only, never raw log
/// lines or transcript/translation-derived content, and speech recognition
/// results are never written to logs.
final class DiagnosticsPrivacyTests: XCTestCase {

    private func makeReport(historyEnabled: Bool, historyEntryCount: Int) -> String {
        DiagnosticsReport.build(
            appVersion: "1.0.0",
            buildNumber: "7",
            osVersion: "15.0",
            microphoneStatus: "granted",
            speechStatus: "granted",
            screenRecordingGranted: true,
            ollamaURL: "http://localhost:11434",
            ollamaIsLocal: true,
            modelName: "qwen3.5:4b-mlx",
            modelType: "Standard (Chat)",
            sourceLanguage: "English (US)",
            targetLanguage: "Chinese",
            captureSystemAudio: true,
            captureMicrophone: true,
            ollamaStatus: "running",
            ollamaVersion: "0.5.1",
            installedModels: ["qwen3.5:4b-mlx"],
            historyEnabled: historyEnabled,
            historyEntryCount: historyEntryCount
        )
    }

    func testReportIsMetadataOnly() {
        let report = makeReport(historyEnabled: true, historyEntryCount: 12)
        XCTAssertTrue(report.contains("Version: 1.0.0 (7)"))
        XCTAssertTrue(report.contains("Microphone: granted"))
        XCTAssertTrue(report.contains("History: enabled (12 entries)"), "history state is metadata and may appear in the report")
        XCTAssertFalse(report.contains("== Recent Log =="), "the report must not embed raw log lines")
        XCTAssertFalse(report.contains("LCTMac.log"), "the report must not reference the raw log file")
    }

    func testReportStatesHistoryDisabledState() {
        let report = makeReport(historyEnabled: false, historyEntryCount: 3)
        XCTAssertTrue(report.contains("History: disabled (3 entries retained)"))
    }

    func testSettingsViewNoLongerEmbedsLogContent() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LCTMac/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("Recent Log"), "diagnostics export must not embed raw log lines")
        XCTAssertFalse(source.contains("recentLogLines"), "diagnostics export must not read raw log content")
    }

    func testSpeechAnalyzerDoesNotLogTranscriptContent() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LCTMac/Services/SpeechAnalyzerService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(
            source.contains("bestTranscription.formattedString.prefix"),
            "recognition results must not be written to logs, even truncated"
        )
    }
}
