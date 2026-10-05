import XCTest
import Foundation

/// Guards the macOS delivery workflow contract in
/// `.github/workflows/macos-build.yml` using local, static checks only
/// (no credentials, no network, no GitHub API).
final class DeliveryWorkflowTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/LCTMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo root
    }

    private func workflowSource() throws -> String {
        let url = repoRoot.appendingPathComponent(".github/workflows/macos-build.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testContinuousJobsRunWithoutSecrets() throws {
        let source = try workflowSource()
        XCTAssertTrue(source.contains("push:"), "normal pushes must trigger the workflow")
        XCTAssertTrue(source.contains("pull_request:"), "pull requests must trigger the workflow")
        XCTAssertTrue(source.contains("fetch-depth: 1"), "must not check out git history")
        XCTAssertFalse(source.contains("fetch-depth: 0"), "must not check out full git history")
        XCTAssertFalse(source.contains("git describe"), "must never derive versions from git")
    }

    func testDeliveryUsesSecretsAndTemporaryKeychain() throws {
        let source = try workflowSource()
        XCTAssertTrue(source.contains("secrets.LCT_DEVELOPER_ID_CERTIFICATE"), "must import the Developer ID certificate from GitHub Secrets")
        XCTAssertTrue(source.contains("secrets.LCT_DEVELOPER_ID_CERTIFICATE_PASSWORD"), "must unlock the certificate with its secret password")
        XCTAssertTrue(source.contains("secrets.LCT_NOTARY_PROFILE"), "must store the notarytool keychain profile from secrets")
        XCTAssertTrue(source.contains("create-keychain"), "must use a temporary keychain")
        XCTAssertTrue(source.contains("security import"), "must import the .p12 into the temporary keychain")
        XCTAssertTrue(source.contains("LCT_SIGN_IDENTITY"), "must package with LCT_SIGN_IDENTITY")
        XCTAssertTrue(source.contains("store-credentials"), "must store notarytool credentials as a keychain profile, never on the command line")
    }

    func testDeliveryPipelineUsesExistingScriptsOnly() throws {
        let source = try workflowSource()
        XCTAssertTrue(source.contains("./package-app.sh"), "package-app.sh lives at the macos root and must be invoked as ./package-app.sh")
        XCTAssertFalse(source.contains("Scripts/package-app.sh"), "Scripts/package-app.sh does not exist")
        XCTAssertTrue(source.contains("create-dmg.sh"), "must build the DMG via Scripts/create-dmg.sh")
        XCTAssertTrue(source.contains("notarize-dmg.sh"), "must notarize and staple via Scripts/notarize-dmg.sh")
        XCTAssertTrue(source.contains("verify-release-dmg.sh"), "must Gatekeeper-verify via Scripts/verify-release-dmg.sh")
    }

    func testMacOsCompatibleTooling() throws {
        let source = try workflowSource()
        XCTAssertTrue(source.contains("base64 -D"), "macOS BSD base64 requires -D to decode")
        XCTAssertFalse(source.contains("--decode"), "GNU-only base64 --decode fails on macOS runners")
        XCTAssertTrue(
            source.contains("'^[0-9]+\\.[0-9]+\\.[0-9]+$'"),
            "release-version validation must enforce strict x.y.z (three nonempty numeric components)"
        )
    }

    func testVersionSourcesAndArtifactContract() throws {
        let source = try workflowSource()
        XCTAssertTrue(source.contains("VERSION"), "version must come from macos/VERSION by default")
        XCTAssertTrue(source.contains("release-version"), "an explicit release-version workflow input must override the version")
        XCTAssertTrue(source.contains(".dmg"), "must produce and upload a DMG")
        XCTAssertFalse(source.contains("zip"), "must never produce ZIP artifacts")
        XCTAssertFalse(source.contains("action-gh-release"), "must never create GitHub Releases")
    }

    func testCredentialHygiene() throws {
        let source = try workflowSource()
        XCTAssertFalse(source.contains("echo ${{ secrets"), "must never echo secrets")
        XCTAssertTrue(source.contains("delete-keychain"), "must delete the temporary keychain")
        XCTAssertTrue(source.contains("delete-credentials"), "must delete the stored notarytool profile")
        XCTAssertTrue(source.contains("if: always()"), "cleanup must run even when delivery steps fail")
    }
}
