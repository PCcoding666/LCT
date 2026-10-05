import XCTest
import Foundation

/// Guards the formal release signing contract enforced by `Scripts/sign-app.sh`:
/// Developer ID signing with hardened runtime, secure timestamp, and the
/// canonical entitlements, followed by strict verification. No ad-hoc fallback.
final class SignAppTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    private var scriptURL: URL {
        packageDir.appendingPathComponent("Scripts/sign-app.sh")
    }

    private func scriptSource() throws -> String {
        try String(contentsOf: scriptURL, encoding: .utf8)
    }

    private func runSignScript(
        arguments: [String],
        environment: [String: String]
    ) throws -> (exitStatus: Int32, stderr: String) {
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

    func testScriptRequiresLctSignIdentity() throws {
        let result = try runSignScript(
            arguments: ["LCTMac.app"],
            environment: ["LCT_SIGN_IDENTITY": ""]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "sign-app.sh must fail when LCT_SIGN_IDENTITY is empty")
        XCTAssertTrue(result.stderr.contains("sign-app.sh"), "sign-app.sh itself must produce the failure, got: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("LCT_SIGN_IDENTITY"),
            "failure must point at LCT_SIGN_IDENTITY, got: \(result.stderr)"
        )
    }

    func testScriptRequiresExistingBundlePath() throws {
        let missing = packageDir.appendingPathComponent("DoesNotExist.app")
        let result = try runSignScript(
            arguments: [missing.path],
            environment: ["LCT_SIGN_IDENTITY": "Developer ID Application: Nobody"]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "sign-app.sh must fail for a missing bundle path")
        XCTAssertTrue(result.stderr.contains("sign-app.sh"), "sign-app.sh itself must produce the failure, got: \(result.stderr)")
    }

    func testScriptFailsOnUnknownIdentityWithoutAdHocFallback() throws {
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignAppTests-\(UUID().uuidString)")
        let appURL = workURL.appendingPathComponent("LCTMac.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/LCTMac")
        try "#!/bin/sh\nexit 0\n".write(to: executableURL, atomically: true, encoding: .utf8)
        let plistURL = packageDir.appendingPathComponent("LCTMac/Info.plist")
        try FileManager.default.copyItem(
            at: plistURL,
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: workURL) }

        let result = try runSignScript(
            arguments: [appURL.path],
            environment: ["LCT_SIGN_IDENTITY": "LCT No Such Identity \(UUID().uuidString)"]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "unknown identity must fail, not fall back to ad-hoc")
        XCTAssertTrue(result.stderr.contains("sign-app.sh"), "sign-app.sh itself must produce the failure, got: \(result.stderr)")
        let signed = try runVerify(appURL: appURL)
        XCTAssertNotEqual(signed.exitStatus, 0, "bundle must not carry a valid signature after a failed signing attempt")
        let display = try runCodesignDisplay(appURL: appURL)
        XCTAssertFalse(
            display.stderr.contains("Signature=adhoc"),
            "sign-app.sh must never fall back to ad-hoc signing"
        )
    }

    func testScriptRejectsExtraArguments() throws {
        let result = try runSignScript(
            arguments: ["LCTMac.app", "Extra.app"],
            environment: ["LCT_SIGN_IDENTITY": "Developer ID Application: Nobody"]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "sign-app.sh must reject extra arguments")
        XCTAssertTrue(result.stderr.contains("sign-app.sh"), "sign-app.sh itself must produce the failure, got: \(result.stderr)")
    }

    func testScriptDeclaresFormalSigningContract() throws {
        let source = try scriptSource()
        XCTAssertTrue(source.contains("--options runtime"), "must enable hardened runtime")
        XCTAssertTrue(source.contains("--timestamp"), "must request a secure timestamp")
        XCTAssertTrue(source.contains("LCTMac.entitlements"), "must apply the canonical entitlements")
        XCTAssertTrue(
            source.contains("--verify") && source.contains("--strict"),
            "must perform strict signature verification"
        )
    }

    private func runVerify(appURL: URL) throws -> (exitStatus: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "--deep", appURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderrText)
    }

    private func runCodesignDisplay(appURL: URL) throws -> (exitStatus: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", appURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderrText)
    }
}
