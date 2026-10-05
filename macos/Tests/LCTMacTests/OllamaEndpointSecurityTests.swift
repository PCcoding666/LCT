import XCTest
import Foundation
@testable import LCTMac

/// Guards the Ollama endpoint security contract:
/// loopback endpoints may use HTTP; any non-loopback endpoint requires the
/// explicit remote opt-in and is HTTPS-only; malformed hosts, embedded
/// schemes/paths/credentials, and invalid ports are rejected without any
/// request being possible. Missing consent (old settings) means remote
/// disabled — only the dedicated Settings toggle can enable it.
final class OllamaEndpointSecurityTests: XCTestCase {

    // MARK: - Loopback

    func testCanonicalLoopbackEndpointsUseHttp() throws {
        let expectations: [(host: String, url: String)] = [
            ("localhost", "http://localhost:11434"),
            ("127.0.0.1", "http://127.0.0.1:11434"),
            // IPv6 literals must be bracketed to form a valid URL authority.
            ("::1", "http://[::1]:11434"),
            ("[::1]", "http://[::1]:11434")
        ]
        for (host, expectedURL) in expectations {
            let endpoint = try OllamaEndpoint.validated(host: host, port: 11434, remoteOptIn: false)
            XCTAssertTrue(endpoint.isLoopback, "\(host) must be loopback")
            XCTAssertEqual(endpoint.baseURL.absoluteString, expectedURL)
        }
    }

    func testLoopbackDoesNotRequireOptIn() throws {
        XCTAssertNoThrow(try OllamaEndpoint.validated(host: "localhost", port: 11434, remoteOptIn: false))
    }

    // MARK: - Remote rejection by default

    func testRemoteHostRejectedWithoutOptIn() {
        for host in ["192.168.1.50", "ollama.example.com", "10.0.0.7"] {
            XCTAssertThrowsError(try OllamaEndpoint.validated(host: host, port: 11434, remoteOptIn: false)) { error in
                guard case OllamaEndpointError.remoteOptInRequired = error else {
                    return XCTFail("\(host) must fail with remoteOptInRequired, got \(error)")
                }
            }
        }
    }

    // MARK: - HTTPS remote opt-in

    func testRemoteHostWithOptInIsHttpsOnly() throws {
        let endpoint = try OllamaEndpoint.validated(host: "ollama.example.com", port: 11434, remoteOptIn: true)
        XCTAssertFalse(endpoint.isLoopback)
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://ollama.example.com:11434")
    }

    // MARK: - Old-settings migration

    func testOldSettingsWithoutOptInKeyDecodeRemoteDisabled() throws {
        let legacyJSON = """
        { "ollamaHost": "ollama.example.com", "ollamaPort": 11434 }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(settings.remoteOllamaOptIn, "missing opt-in key must decode as remote disabled")
        XCTAssertNil(settings.validatedOllamaEndpoint, "a saved non-loopback host without opt-in must not produce a usable endpoint")
        XCTAssertNotNil(settings.ollamaEndpointError)
    }

    func testFreshSettingsAreRemoteDisabledWithLoopbackDefault() {
        let settings = AppSettings()
        XCTAssertFalse(settings.remoteOllamaOptIn)
        let endpoint = settings.validatedOllamaEndpoint
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://localhost:11434")
    }

    func testNonLoopbackHostAloneNeverImpliesOptIn() throws {
        // Only the dedicated consent toggle may enable remote access.
        var settings = AppSettings()
        settings.ollamaHost = "ollama.example.com"
        XCTAssertNil(settings.validatedOllamaEndpoint)
        settings.remoteOllamaOptIn = true
        XCTAssertEqual(settings.validatedOllamaEndpoint?.baseURL.scheme, "https")
    }

    // MARK: - Hostile / malformed inputs

    func testMalformedHostsAreRejected() {
        let hostileHosts = [
            "",
            "   ",
            "http://localhost",
            "https://ollama.example.com",
            "ollama.example.com/api",
            "user:pass@ollama.example.com",
            "ollama.example.com:11434",
            "local host",
            "ollama!.example.com",
        ]
        for host in hostileHosts {
            XCTAssertThrowsError(
                try OllamaEndpoint.validated(host: host, port: 11434, remoteOptIn: true),
                "'\(host)' must be rejected"
            )
        }
    }

    func testInvalidPortsAreRejected() {
        for port in [0, -1, 65_536, 999_999] {
            XCTAssertThrowsError(
                try OllamaEndpoint.validated(host: "localhost", port: port, remoteOptIn: true),
                "port \(port) must be rejected"
            )
        }
    }

    func testInvalidEndpointCannotProduceRequestableURL() {
        var settings = AppSettings()
        settings.ollamaHost = "http://evil.example"
        XCTAssertNil(settings.validatedOllamaEndpoint)
        XCTAssertFalse(
            settings.ollamaURL.contains("evil.example"),
            "an invalid host must never be interpolated into a requestable URL"
        )
    }

    // MARK: - UI consent surface

    func testSettingsUIHasDedicatedConsentToggle() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LCTMac/Views/SettingsView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("remoteOllamaOptIn"), "Settings must bind the consent toggle to remoteOllamaOptIn")
        XCTAssertTrue(source.contains("HTTPS"), "the consent copy must state the HTTPS consequence")
    }
}
