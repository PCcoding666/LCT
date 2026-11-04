import Foundation
import XCTest

final class EmbeddedFrameworkSigningTests: XCTestCase {
    func testSigning_EmbeddedRuntime_SignsInnerFrameworkBeforeAppAndVerifies() throws {
        let result = try runSigning(failFramework: false)
        XCTAssertEqual(result.status, 0)
        guard result.calls.count == 3 else { return XCTFail("Expected nested sign, outer sign, then verification: \(result.calls)") }
        XCTAssertTrue(result.calls[0].hasSuffix("/Contents/Frameworks/llama.framework"))
        XCTAssertTrue(result.calls[1].hasSuffix("/Fixture.app"))
        XCTAssertTrue(result.calls[2].hasPrefix("--verify --strict --deep"))
    }

    func testSigning_FrameworkFailure_DoesNotSealOuterApp() throws {
        let result = try runSigning(failFramework: true)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertTrue(result.calls.first?.hasSuffix("/Contents/Frameworks/llama.framework") == true)
    }

    private func runSigning(failFramework: Bool) throws -> (status: Int32, calls: [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Fixture.app")
        let framework = app.appendingPathComponent("Contents/Frameworks/llama.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let mock = directory.appendingPathComponent("codesign")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$LCT_SIGN_TEST_LOG"
        if [ "$LCT_SIGN_TEST_FAIL" = "1" ]; then exit 2; fi
        exit 0
        """.write(to: mock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)
        let log = directory.appendingPathComponent("calls.txt")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [package.appendingPathComponent("Scripts/sign-app.sh").path, app.path]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin", "LCT_SIGN_IDENTITY": "Fixture Identity",
            "LCT_SIGN_TEST_LOG": log.path, "LCT_SIGN_TEST_FAIL": failFramework ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        return (process.terminationStatus, calls)
    }
}
