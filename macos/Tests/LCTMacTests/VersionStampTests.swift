import XCTest
import Foundation

/// Guards the release version stamping contract:
/// `macos/VERSION` is the single manually maintained version source,
/// `Info.plist` carries placeholders, and `Scripts/version-stamp.sh`
/// resolves them at packaging time.
final class VersionStampTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    func testVersionFileIsSemver() throws {
        let url = packageDir.appendingPathComponent("VERSION")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let version = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(
            version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
            "VERSION must be a manually maintained x.y.z value, got '\(version)'"
        )
    }

    func testInfoPlistCarriesPlaceholders() throws {
        let plistURL = packageDir.appendingPathComponent("LCTMac/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let dict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(
            dict["CFBundleShortVersionString"] as? String,
            "__LCT_VERSION__",
            "CFBundleShortVersionString must be a placeholder stamped at package time"
        )
        XCTAssertEqual(
            dict["CFBundleVersion"] as? String,
            "__LCT_BUILD__",
            "CFBundleVersion must be a placeholder stamped at package time"
        )
    }

    func testVersionStampScriptResolvesPlaceholders() throws {
        let targetURL = try makeTempPlistCopy()
        let result = try runStampScript(
            on: targetURL,
            environment: ["RELEASE_VERSION": "9.8.7", "BUILD_NUMBER": "42"]
        )
        XCTAssertEqual(result.exitStatus, 0, "version-stamp.sh failed: \(result.stderr)")

        let data = try Data(contentsOf: targetURL)
        let dict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(dict["CFBundleShortVersionString"] as? String, "9.8.7")
        XCTAssertEqual(dict["CFBundleVersion"] as? String, "42")
    }

    func testVersionStampScriptRejectsInvalidReleaseVersion() throws {
        let targetURL = try makeTempPlistCopy()
        let before = try Data(contentsOf: targetURL)
        let result = try runStampScript(
            on: targetURL,
            environment: ["RELEASE_VERSION": "1.2", "BUILD_NUMBER": "1"]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "strict x.y.z validation must reject '1.2'")
        XCTAssertEqual(try Data(contentsOf: targetURL), before, "plist must not be modified on validation failure")
    }

    func testVersionStampScriptRejectsNonIntegerBuildNumber() throws {
        let targetURL = try makeTempPlistCopy()
        let before = try Data(contentsOf: targetURL)
        let result = try runStampScript(
            on: targetURL,
            environment: ["RELEASE_VERSION": "9.8.7", "BUILD_NUMBER": "abc"]
        )
        XCTAssertNotEqual(result.exitStatus, 0, "integer validation must reject 'abc'")
        XCTAssertEqual(try Data(contentsOf: targetURL), before, "plist must not be modified on validation failure")
    }

    private func makeTempPlistCopy() throws -> URL {
        let plistURL = packageDir.appendingPathComponent("LCTMac/Info.plist")
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionStampTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workURL) }
        let targetURL = workURL.appendingPathComponent("Info.plist")
        try FileManager.default.copyItem(at: plistURL, to: targetURL)
        return targetURL
    }

    private func runStampScript(on targetURL: URL, environment: [String: String]) throws -> (exitStatus: Int32, stderr: String) {
        let scriptURL = packageDir.appendingPathComponent("Scripts/version-stamp.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path, targetURL.path]
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
}
