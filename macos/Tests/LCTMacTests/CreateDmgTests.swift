import XCTest
import Foundation

/// Guards the disk-image packaging contract of `Scripts/create-dmg.sh`:
/// exactly two arguments (signed .app + output .dmg), strict verification of
/// the app, UDZO compression via hdiutil, an Applications symlink in the
/// staging layout, and no signing of the DMG.
final class CreateDmgTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    private var scriptURL: URL {
        packageDir.appendingPathComponent("Scripts/create-dmg.sh")
    }

    private func runCreateDmg(arguments: [String]) throws -> (exitStatus: Int32, stderr: String) {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            XCTFail("Scripts/create-dmg.sh must exist")
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
        let zero = try runCreateDmg(arguments: [])
        XCTAssertNotEqual(zero.exitStatus, 0, "must reject zero arguments")
        XCTAssertTrue(zero.stderr.contains("create-dmg.sh"), "create-dmg.sh itself must produce the failure, got: \(zero.stderr)")

        let three = try runCreateDmg(arguments: ["a.app", "b.dmg", "c"])
        XCTAssertNotEqual(three.exitStatus, 0, "must reject three arguments")
        XCTAssertTrue(three.stderr.contains("create-dmg.sh"), "create-dmg.sh itself must produce the failure, got: \(three.stderr)")
    }

    func testRejectsMissingAppBundle() throws {
        let result = try runCreateDmg(arguments: ["/nonexistent/LCTMac.app", "/tmp/out.dmg"])
        XCTAssertNotEqual(result.exitStatus, 0, "must reject a missing app bundle")
        XCTAssertTrue(result.stderr.contains("create-dmg.sh"), "create-dmg.sh itself must produce the failure, got: \(result.stderr)")
    }

    func testRejectsExistingOutputPath() throws {
        let workURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreateDmgTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workURL) }
        let dmgURL = workURL.appendingPathComponent("out.dmg")
        try "existing".write(to: dmgURL, atomically: true, encoding: .utf8)

        let result = try runCreateDmg(arguments: ["/nonexistent/LCTMac.app", dmgURL.path])
        XCTAssertNotEqual(result.exitStatus, 0, "must reject a pre-existing output path")
        XCTAssertTrue(result.stderr.contains("create-dmg.sh"), "create-dmg.sh itself must produce the failure, got: \(result.stderr)")
        XCTAssertEqual(try String(contentsOf: dmgURL, encoding: .utf8), "existing", "existing output must not be altered")
    }

    func testSourceContract() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(source.contains("hdiutil create"), "must create the image with hdiutil")
        XCTAssertTrue(source.contains("UDZO"), "must produce a compressed UDZO image")
        XCTAssertTrue(
            source.contains("--verify") && source.contains("--strict"),
            "must strict-verify the app signature before packaging"
        )
        XCTAssertTrue(source.contains("ln -s /Applications"), "staging must include an Applications symlink for drag-install")
        XCTAssertFalse(source.contains("--sign"), "create-dmg.sh must never sign the DMG")
        XCTAssertFalse(source.contains(" -ov "), "create-dmg.sh must never overwrite an existing output DMG")
    }
}
