import XCTest
import Foundation
@testable import LCTMac

/// Guards `LCTMac/Info.plist` hygiene for notarization:
/// entitlement-style keys belong only in `LCTMac.entitlements`, and no dead
/// usage-description keys may be added.
final class InfoPlistTests: XCTestCase {

    private func loadPlist() -> [String: Any]? {
        // #filePath = .../macos/Tests/LCTMacTests/InfoPlistTests.swift
        let sourceURL = URL(fileURLWithPath: #filePath)
        let packageDir = sourceURL
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
        let plistURL = packageDir.appendingPathComponent("LCTMac/Info.plist")

        guard let data = try? Data(contentsOf: plistURL) else {
            XCTFail("Info.plist not found at \(plistURL.path)")
            return nil
        }
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dict = object as? [String: Any] else {
            XCTFail("Failed to parse Info.plist at \(plistURL.path)")
            return nil
        }
        return dict
    }

    func testNoAppleSecurityKeysInInfoPlist() throws {
        let plist = try XCTUnwrap(loadPlist())
        let securityKeys = plist.keys.filter { $0.hasPrefix("com.apple.security.") }.sorted()
        XCTAssertEqual(
            securityKeys,
            [],
            "Entitlement keys must live in LCTMac.entitlements, not Info.plist: \(securityKeys)"
        )
    }

    func testNoScreenCaptureUsageDescription() throws {
        let plist = try XCTUnwrap(loadPlist())
        XCTAssertNil(
            plist["NSScreenCaptureUsageDescription"],
            "Screen capture uses system-managed TCC; a usage-description key in Info.plist is dead weight"
        )
    }

    func testBundleIdentifier() throws {
        let plist = try XCTUnwrap(loadPlist())
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.lct.mac")
    }
}
