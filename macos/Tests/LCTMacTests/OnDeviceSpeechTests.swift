import XCTest
import Foundation
import Speech
@testable import LCTMac

/// Guards the on-device speech recognition contract:
/// every recognition request must require on-device recognition (no silent
/// network fallback), unsupported languages fail with a clear error before
/// capture starts, and user-facing copy truthfully describes on-device
/// processing.
@MainActor
final class OnDeviceSpeechTests: XCTestCase {

    // MARK: - Request contract

    func testRecognitionRequestRequiresOnDeviceRecognition() {
        let service = SpeechAnalyzerService(language: .english)
        let request = service.makeRecognitionRequest()

        XCTAssertTrue(request.requiresOnDeviceRecognition,
                      "Every recognition request must require on-device recognition")
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertTrue(request is SFSpeechAudioBufferRecognitionRequest)
    }

    func testServiceSourceNeverAllowsNetworkFallback() throws {
        let source = try readSource("Services/SpeechAnalyzerService.swift")

        XCTAssertFalse(source.contains("requiresOnDeviceRecognition = false"),
                       "Service must never disable on-device recognition")

        // Requests must only be created through the single hardened factory.
        let creationCount = source.components(separatedBy: "SFSpeechAudioBufferRecognitionRequest()").count - 1
        XCTAssertEqual(creationCount, 1,
                       "All recognition requests must be created via makeRecognitionRequest()")

        XCTAssertTrue(source.contains("requiresOnDeviceRecognition = true"))
        XCTAssertTrue(source.contains("supportsOnDeviceRecognition"),
                      "Service must check on-device availability before starting")
    }

    // MARK: - Availability contract

    func testOnDeviceAvailabilityIsFalseForUnknownLocale() {
        let service = SpeechAnalyzerService(language: .english)
        XCTAssertFalse(service.isOnDeviceRecognitionAvailable(locale: Locale(identifier: "xx-XX")),
                       "A locale with no recognizer must report on-device recognition as unavailable")
    }

    func testOnDeviceUnavailableErrorIsActionable() {
        let error = SpeechAnalyzerError.onDeviceRecognitionUnavailable
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.localizedLowercase.contains("on-device"),
                      "Error must explain on-device requirement, got: \(message)")
    }

    func testViewModelSurfacesOnDeviceErrorBeforeCapture() throws {
        let source = try readSource("ViewModels/TranscriptionVM.swift")
        XCTAssertTrue(source.contains("onDeviceRecognitionUnavailable"),
                      "start() must map the on-device error to an actionable notice")
    }

    // MARK: - User-facing copy

    func testWelcomeCopyStatesOnDeviceProcessing() throws {
        let source = try readSource("Views/WelcomeView.swift")
        XCTAssertTrue(source.contains("processed on-device"),
                      "Welcome copy must state speech is processed on-device")
        XCTAssertTrue(source.contains("on-device speech model"),
                      "Welcome copy must explain that unavailable languages need an on-device speech model")
    }

    func testSettingsCopyExplainsOnDeviceRequirement() throws {
        let source = try readSource("Views/SettingsView.swift")
        XCTAssertTrue(source.contains("on-device speech model"),
                      "Settings language warning must mention the on-device speech model")
        XCTAssertTrue(source.contains("supportsOnDeviceRecognition"),
                      "Settings language availability must reflect on-device support")
    }

    // MARK: - Helpers

    private func readSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OnDeviceSpeechTests.swift
            .deletingLastPathComponent() // LCTMacTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("LCTMac")
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Source file not found: \(url.path)")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
