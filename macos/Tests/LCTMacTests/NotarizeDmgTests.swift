import XCTest
import Foundation

/// Guards the notarization contract of `Scripts/notarize-dmg.sh`:
/// exactly one existing .dmg argument, a required LCT_NOTARY_PROFILE keychain
/// profile, submission via `notarytool submit --wait`, stapling and validation
/// of the same DMG, no ZIP submission, no DMG signing, and no Apple
/// credentials on the command line. Tests never invoke Apple services.
final class NotarizeDmgTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    private var scriptURL: URL {
        packageDir.appendingPathComponent("Scripts/notarize-dmg.sh")
    }

    private func runNotarize(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (exitStatus: Int32, stderr: String) {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            XCTFail("Scripts/notarize-dmg.sh must exist")
            return (-1, "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderrText)
    }

    func testRejectsWrongArgumentCount() throws {
        let zero = try runNotarize(arguments: [], environment: ["LCT_NOTARY_PROFILE": "profile"])
        XCTAssertNotEqual(zero.exitStatus, 0, "must reject zero arguments")
        XCTAssertTrue(zero.stderr.contains("notarize-dmg.sh"), "notarize-dmg.sh itself must produce the failure, got: \(zero.stderr)")

        let two = try runNotarize(arguments: ["a.dmg", "b.dmg"], environment: ["LCT_NOTARY_PROFILE": "profile"])
        XCTAssertNotEqual(two.exitStatus, 0, "must reject two arguments")
        XCTAssertTrue(two.stderr.contains("notarize-dmg.sh"), "notarize-dmg.sh itself must produce the failure, got: \(two.stderr)")
    }

    func testRejectsEmptyNotaryProfile() throws {
        let result = try runNotarize(arguments: ["/nonexistent/LCT.dmg"], environment: ["LCT_NOTARY_PROFILE": ""])
        XCTAssertNotEqual(result.exitStatus, 0, "must reject an empty LCT_NOTARY_PROFILE")
        XCTAssertTrue(result.stderr.contains("notarize-dmg.sh"), "notarize-dmg.sh itself must produce the failure, got: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("LCT_NOTARY_PROFILE"), "failure must point at LCT_NOTARY_PROFILE, got: \(result.stderr)")
    }

    func testRejectsMissingDmgAndNonDmgInput() throws {
        let profile = ["LCT_NOTARY_PROFILE": "profile"]
        let missing = try runNotarize(arguments: ["/nonexistent/LCT.dmg"], environment: profile)
        XCTAssertNotEqual(missing.exitStatus, 0, "must reject a missing DMG")
        XCTAssertTrue(missing.stderr.contains("notarize-dmg.sh"), "notarize-dmg.sh itself must produce the failure, got: \(missing.stderr)")

        let zip = try runNotarize(arguments: ["/nonexistent/LCT.zip"], environment: profile)
        XCTAssertNotEqual(zip.exitStatus, 0, "must refuse to notarize a ZIP")
        XCTAssertTrue(zip.stderr.contains("notarize-dmg.sh"), "notarize-dmg.sh itself must produce the failure, got: \(zip.stderr)")
    }

    func testSourceContract() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(source.contains("notarytool submit"), "must submit via notarytool")
        XCTAssertTrue(source.contains("--wait"), "must wait for notarization to complete")
        XCTAssertTrue(source.contains("--keychain-profile"), "must authenticate via a keychain profile")
        XCTAssertTrue(source.contains("stapler staple"), "must staple the DMG")
        XCTAssertTrue(source.contains("stapler validate"), "must validate the staple")
        XCTAssertFalse(source.contains("--sign"), "must never codesign the DMG")
        XCTAssertFalse(source.contains("--apple-id"), "must never pass Apple credentials on the command line")
        XCTAssertFalse(source.contains("--password"), "must never pass Apple credentials on the command line")
        XCTAssertFalse(source.contains(".zip"), "must never submit a ZIP archive")
    }
}
