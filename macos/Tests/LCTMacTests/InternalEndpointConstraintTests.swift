import XCTest
import Foundation
@testable import LCTMac

/// Guards the internal endpoint constraint for OllamaModelManager and
/// OllamaGuardian: both must build request URLs exclusively from a validated
/// OllamaEndpoint via URL APIs. Model management defaults to canonical
/// loopback and reaches remote servers only through a caller-supplied
/// validated endpoint (HTTPS by construction). The guardian manages the local
/// process and must reject any non-loopback or malformed URL before a request
/// can be made.
@MainActor
final class InternalEndpointConstraintTests: XCTestCase {

    // MARK: - OllamaModelManager

    func testModelManagerDefaultsToCanonicalLoopback() {
        let manager = OllamaModelManager()
        XCTAssertTrue(manager.endpoint.isLoopback)
        XCTAssertEqual(manager.endpoint.baseURL.absoluteString, "http://localhost:11434")
        XCTAssertEqual(manager.endpoint.scheme, "http")
    }

    func testModelManagerRemoteEndpointIsHttpsByConstruction() throws {
        let remote = try OllamaEndpoint.validated(
            host: "ollama.example.com",
            port: 11434,
            remoteOptIn: true
        )
        let manager = OllamaModelManager(endpoint: remote)
        XCTAssertEqual(manager.endpoint.baseURL.absoluteString, "https://ollama.example.com:11434")
    }

    func testModelManagerSourceBuildsURLsFromEndpointOnly() throws {
        let source = try readSource("Services/OllamaModelManager.swift")

        XCTAssertFalse(source.contains(#"URL(string: "\("#),
                       "Model manager must not build URLs by string interpolation")
        XCTAssertTrue(source.contains("OllamaEndpoint"),
                      "Model manager must use a validated OllamaEndpoint")
        XCTAssertTrue(source.contains("appendingPathComponent"),
                      "Model manager must construct paths with URL APIs")
    }

    // MARK: - OllamaGuardian

    func testGuardianAcceptsCanonicalLoopbackURLs() {
        for urlString in [
            "http://localhost:11434",
            "http://127.0.0.1:11434",
            "http://[::1]:11434"
        ] {
            let guardian = OllamaGuardian(ollamaPath: "/bin/echo", ollamaURL: urlString)
            guard let endpoint = guardian.endpoint else {
                return XCTFail("\(urlString) must be accepted as loopback")
            }
            XCTAssertTrue(endpoint.isLoopback)
            XCTAssertEqual(endpoint.baseURL.absoluteString, "http://\(endpoint.host):11434")
        }
    }

    func testGuardianRejectsNonLoopbackAndMalformedURLs() {
        for urlString in [
            "http://evil.example:11434",
            "http://192.168.1.50:11434",
            "http://user:pass@evil.example:11434",
            "http://localhost:11434/api",
            "not a url at all",
            "",
            "http://:11434"
        ] {
            let guardian = OllamaGuardian(ollamaPath: "/bin/echo", ollamaURL: urlString)
            XCTAssertNil(guardian.endpoint,
                         "\(urlString) must be rejected before any request can be made")
        }
    }

    func testGuardianRejectedEndpointCannotProduceRequestURL() {
        let guardian = OllamaGuardian(ollamaPath: "/bin/echo", ollamaURL: "http://evil.example:11434")
        XCTAssertNil(guardian.requestURL(apiPath: "api/tags"))
        XCTAssertNil(guardian.requestURL(apiPath: "api/version"))
    }

    func testGuardianSourceBuildsURLsFromEndpointOnly() throws {
        let source = try readSource("Services/OllamaGuardian.swift")

        XCTAssertFalse(source.contains(#"URL(string: "\("#),
                       "Guardian must not build URLs by string interpolation")
        XCTAssertTrue(source.contains("OllamaEndpoint"),
                      "Guardian must use a validated OllamaEndpoint")
    }

    // MARK: - OllamaEndpoint.parsedLoopback

    func testParsedLoopbackAcceptsLoopbackURLsOnly() throws {
        for (urlString, expectedHost) in [
            ("http://localhost:11434", "localhost"),
            ("http://127.0.0.1:11434", "127.0.0.1"),
            ("http://[::1]:11434", "[::1]")
        ] {
            let endpoint = OllamaEndpoint.parsedLoopback(from: urlString)
            XCTAssertEqual(endpoint?.host, expectedHost, "\(urlString) must parse to loopback")
            XCTAssertEqual(endpoint?.port, 11434)
            XCTAssertTrue(endpoint?.isLoopback ?? false)
        }
    }

    func testParsedLoopbackRejectsRemoteAndMalformedURLs() {
        for urlString in [
            "https://ollama.example.com:11434",
            "http://10.0.0.7:11434",
            "http://localhost",
            "http://localhost:11434/",
            "http://localhost:11434?x=1",
            "http://user:pass@localhost:11434",
            "ftp://localhost:11434",
            "localhost:11434",
            "not a url",
            "",
            "http://localhost:0"
        ] {
            XCTAssertNil(OllamaEndpoint.parsedLoopback(from: urlString),
                         "\(urlString) must not produce a loopback endpoint")
        }
    }

    // MARK: - Helpers

    private func readSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LCTMac")
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Source file not found: \(url.path)")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
