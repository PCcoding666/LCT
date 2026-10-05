import XCTest
import Foundation

/// Guards the development run contract of `Scripts/dev-run.sh` and the
/// deprecated wrappers that forward to it:
/// - a stable signing identity is mandatory (explicit `LCT_SIGN_IDENTITY`,
///   otherwise the first Apple Development certificate's SHA-1);
/// - ad-hoc (`-`) signing is rejected outright;
/// - a running instance is quit before packaging;
/// - `--no-launch` builds without opening the app.
/// All external tools (security, osascript, pgrep/pkill, open) and the
/// packaging step are stubbed via PATH injection and `LCT_PACKAGE_SCRIPT`.
final class DevRunTests: XCTestCase {

    private var packageDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
    }

    private var scriptsDir: URL {
        packageDir.appendingPathComponent("Scripts")
    }

    // MARK: - Stub helpers

    private struct StubbedRun {
        let workDir: URL
        let logURL: URL
    }

    @discardableResult
    private func writeExecutable(_ name: String, contents: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Creates a temp dir with stub `pgrep` (not running), `pkill`,
    /// `osascript`, `open`, and a stub packaging script; every stub appends
    /// its invocation to the log at `LCT_STUB_LOG`.
    private func makeStubbedRun(
        securityOutput: String?,
        pgrepBody: String? = nil
    ) throws -> StubbedRun {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevRunTests-\(UUID().uuidString)")
        let binDir = workDir.appendingPathComponent("bin")
        let homeDir = workDir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        let logURL = workDir.appendingPathComponent("stub.log")
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }

        if let securityOutput {
            try writeExecutable("security", contents: """
                #!/bin/bash
                cat <<'LCT_SECURITY_EOF'
                \(securityOutput)
                LCT_SECURITY_EOF
                """, in: binDir)
        }

        try writeExecutable("pgrep", contents: pgrepBody ?? "#!/bin/bash\nexit 1\n", in: binDir)
        try writeExecutable("pkill", contents: """
            #!/bin/bash
            echo "pkill $*" >> "$LCT_STUB_LOG"
            """, in: binDir)
        try writeExecutable("osascript", contents: """
            #!/bin/bash
            echo "osascript $*" >> "$LCT_STUB_LOG"
            """, in: binDir)
        try writeExecutable("open", contents: """
            #!/bin/bash
            echo "open $*" >> "$LCT_STUB_LOG"
            """, in: binDir)
        try writeExecutable("package-stub.sh", contents: """
            #!/bin/bash
            echo "package identity=$LCT_SIGN_IDENTITY" >> "$LCT_STUB_LOG"
            """, in: workDir)

        return StubbedRun(workDir: workDir, logURL: logURL)
    }

    private func run(
        _ script: String,
        arguments: [String] = [],
        stubs: StubbedRun,
        identity: String? = nil
    ) throws -> (exitStatus: Int32, stdout: String, stderr: String) {
        var environment: [String: String] = [
            "PATH": "\(stubs.workDir.appendingPathComponent("bin").path):/usr/bin:/bin",
            "HOME": stubs.workDir.appendingPathComponent("home").path,
            "LCT_PACKAGE_SCRIPT": stubs.workDir.appendingPathComponent("package-stub.sh").path,
            "LCT_STUB_LOG": stubs.logURL.path,
        ]
        if let identity {
            environment["LCT_SIGN_IDENTITY"] = identity
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptsDir.appendingPathComponent(script).path] + arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdoutText, stderrText)
    }

    private func stubLog(_ stubs: StubbedRun) -> String {
        (try? String(contentsOf: stubs.logURL, encoding: .utf8)) ?? ""
    }

    private let twoAppleDevelopmentIdentities = """
             1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Alice Example (TEAM1)"
             2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Alice Example (TEAM1)"
             3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Bob Example (TEAM2)"
        """

    // MARK: - dev-run.sh

    func testDevRun_NoIdentityEnv_SelectsFirstAppleDevelopmentSHA1() throws {
        let stubs = try makeStubbedRun(securityOutput: twoAppleDevelopmentIdentities)
        let result = try run("dev-run.sh", stubs: stubs)

        XCTAssertEqual(result.exitStatus, 0, "dev-run.sh failed: \(result.stderr)")
        let log = stubLog(stubs)
        XCTAssertTrue(
            log.contains("package identity=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "packaging must receive the first Apple Development SHA-1, got: \(log)"
        )
        XCTAssertTrue(
            result.stdout.contains("export LCT_SIGN_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "must print how to pin the selected identity, got: \(result.stdout)"
        )
        XCTAssertTrue(log.contains("open "), "default run must open the app, got: \(log)")
    }

    func testDevRun_ExplicitIdentity_IsPassedThroughToPackaging() throws {
        let stubs = try makeStubbedRun(securityOutput: nil)
        let result = try run("dev-run.sh", stubs: stubs, identity: "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        XCTAssertEqual(result.exitStatus, 0, "dev-run.sh failed: \(result.stderr)")
        XCTAssertTrue(
            stubLog(stubs).contains("package identity=DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"),
            "explicit LCT_SIGN_IDENTITY must reach the packaging step, got: \(stubLog(stubs))"
        )
    }

    func testDevRun_NoIdentities_ExitsNonZeroWithGuidance() throws {
        let stubs = try makeStubbedRun(securityOutput: "     0 valid identities found")
        let result = try run("dev-run.sh", stubs: stubs)

        XCTAssertNotEqual(result.exitStatus, 0, "dev-run.sh must fail when no identity is available")
        XCTAssertTrue(result.stderr.contains("dev-run.sh"), "dev-run.sh itself must produce the failure, got: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("LCT_SIGN_IDENTITY"),
            "failure must explain how to set LCT_SIGN_IDENTITY, got: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stderr.contains("Apple Development"),
            "failure must explain how to obtain an Apple Development certificate, got: \(result.stderr)"
        )
    }

    func testDevRun_AdHocIdentity_ExitsNonZero() throws {
        let stubs = try makeStubbedRun(securityOutput: twoAppleDevelopmentIdentities)
        let result = try run("dev-run.sh", stubs: stubs, identity: "-")

        XCTAssertNotEqual(result.exitStatus, 0, "dev-run.sh must reject ad-hoc ('-') signing")
        XCTAssertTrue(result.stderr.contains("dev-run.sh"), "dev-run.sh itself must produce the failure, got: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("ad-hoc"), "failure must name ad-hoc signing as the problem, got: \(result.stderr)")
        XCTAssertFalse(stubLog(stubs).contains("package "), "packaging must not run for an ad-hoc identity")
    }

    func testDevRun_NoLaunch_DoesNotOpenApp() throws {
        let stubs = try makeStubbedRun(securityOutput: nil)
        let result = try run("dev-run.sh", arguments: ["--no-launch"], stubs: stubs, identity: "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        XCTAssertEqual(result.exitStatus, 0, "dev-run.sh failed: \(result.stderr)")
        let log = stubLog(stubs)
        XCTAssertTrue(log.contains("package "), "packaging must still run with --no-launch, got: \(log)")
        XCTAssertFalse(log.contains("open "), "--no-launch must not open the app, got: \(log)")
    }

    func testDevRun_RunningInstance_QuitsGracefullyWithoutPkill() throws {
        let pgrep = """
            #!/bin/bash
            echo "pgrep $*" >> "$LCT_STUB_LOG"
            count_file="$LCT_STUB_LOG.pgrep-count"
            n=0
            [ -f "$count_file" ] && n=$(cat "$count_file")
            n=$((n + 1))
            echo "$n" > "$count_file"
            # First invocation reports a running instance; later ones report it gone.
            [ "$n" -eq 1 ] && exit 0
            exit 1
            """
        let stubs = try makeStubbedRun(securityOutput: nil, pgrepBody: pgrep)
        let result = try run("dev-run.sh", stubs: stubs, identity: "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        XCTAssertEqual(result.exitStatus, 0, "dev-run.sh failed: \(result.stderr)")
        let log = stubLog(stubs)
        XCTAssertTrue(log.contains("osascript"), "a running instance must be quit via osascript, got: \(log)")
        XCTAssertFalse(log.contains("pkill"), "pkill is only a fallback after a 5s grace period, got: \(log)")
    }

    // MARK: - Deprecated wrappers

    func testBuildAppScript_ForwardsToDevRun() throws {
        let stubs = try makeStubbedRun(securityOutput: nil)
        let result = try run("build-app.sh", arguments: ["release"], stubs: stubs, identity: "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        XCTAssertEqual(result.exitStatus, 0, "build-app.sh failed: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("deprecated: use Scripts/dev-run.sh"),
            "wrapper must print the deprecation notice, got: \(result.stderr)"
        )
        let log = stubLog(stubs)
        XCTAssertTrue(log.contains("package identity=DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"), "wrapper must reach packaging via dev-run.sh, got: \(log)")
        XCTAssertTrue(log.contains("open "), "wrapper must not forward the ignored release/debug argument (it would fail as an unknown argument), got: \(log)")
    }

    func testBuildSignedScript_ForwardsToDevRun() throws {
        let stubs = try makeStubbedRun(securityOutput: nil)
        let result = try run("build_signed.sh", stubs: stubs, identity: "DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        XCTAssertEqual(result.exitStatus, 0, "build_signed.sh failed: \(result.stderr)")
        XCTAssertTrue(
            result.stderr.contains("deprecated: use Scripts/dev-run.sh"),
            "wrapper must print the deprecation notice, got: \(result.stderr)"
        )
        XCTAssertTrue(
            stubLog(stubs).contains("package identity=DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF"),
            "wrapper must reach packaging via dev-run.sh, got: \(stubLog(stubs))"
        )
    }
}
