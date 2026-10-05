import XCTest
import Foundation

/// Guards the release verification contract of `Scripts/verify-release-dmg.sh`:
/// exactly one existing .dmg argument, `stapler validate` on the DMG, and
/// `spctl` assessment of it as an opened disk image with verbose diagnostics.
/// Verification only — the script never mounts, modifies, signs, or notarizes.
/// Tests are fully local and need no signed/notarized artifact.
final class VerifyReleaseDmgTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    private var scriptURL: URL {
        packageDir.appendingPathComponent("Scripts/verify-release-dmg.sh")
    }

    private func runVerify(arguments: [String]) throws -> (exitStatus: Int32, stderr: String) {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            XCTFail("Scripts/verify-release-dmg.sh must exist")
            return (-1, "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderrText)
    }

    func testRejectsWrongArgumentCount() throws {
        let zero = try runVerify(arguments: [])
        XCTAssertNotEqual(zero.exitStatus, 0, "must reject zero arguments")
        XCTAssertTrue(zero.stderr.contains("verify-release-dmg.sh"), "verify-release-dmg.sh itself must produce the failure, got: \(zero.stderr)")

        let two = try runVerify(arguments: ["a.dmg", "b.dmg"])
        XCTAssertNotEqual(two.exitStatus, 0, "must reject two arguments")
        XCTAssertTrue(two.stderr.contains("verify-release-dmg.sh"), "verify-release-dmg.sh itself must produce the failure, got: \(two.stderr)")
    }

    func testRejectsMissingDmgAndNonDmgInput() throws {
        let missing = try runVerify(arguments: ["/nonexistent/LCT.dmg"])
        XCTAssertNotEqual(missing.exitStatus, 0, "must reject a missing DMG")
        XCTAssertTrue(missing.stderr.contains("verify-release-dmg.sh"), "verify-release-dmg.sh itself must produce the failure, got: \(missing.stderr)")

        let nonDmg = try runVerify(arguments: ["/nonexistent/LCT.app"])
        XCTAssertNotEqual(nonDmg.exitStatus, 0, "must reject a non-.dmg path")
        XCTAssertTrue(nonDmg.stderr.contains("verify-release-dmg.sh"), "verify-release-dmg.sh itself must produce the failure, got: \(nonDmg.stderr)")
    }

    func testSourceContract() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(source.contains("stapler validate"), "must validate the staple on the DMG")
        XCTAssertTrue(source.contains("spctl"), "must assess the DMG with spctl")
        XCTAssertTrue(source.contains("--verbose"), "must emit verbose diagnostics")
        XCTAssertTrue(source.contains("--type open"), "must assess the DMG as an opened disk image")
        XCTAssertFalse(source.contains("hdiutil attach"), "must not mount the DMG")
        XCTAssertFalse(source.contains("--sign"), "must never sign the DMG")
        XCTAssertFalse(source.contains("notarytool"), "must never notarize the DMG")
        XCTAssertFalse(source.contains("curl"), "must not invoke network services")
    }
}
