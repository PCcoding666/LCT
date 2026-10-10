import Foundation
import XCTest
@testable import LCTMac

/// End-to-end pull tests for OllamaModelManager against a stubbed URLSession.
/// Nothing here touches a real Ollama server or downloads a real model.
@MainActor
final class OllamaModelManagerPullTests: XCTestCase {

    private let log = RecordedRequestLog()

    override func setUp() {
        super.setUp()
        PullMockURLProtocol.log = log
        PullMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        PullMockURLProtocol.requestHandler = nil
        PullMockURLProtocol.log = nil
        super.tearDown()
    }

    private func makeManager() -> OllamaModelManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PullMockURLProtocol.self]
        return OllamaModelManager(endpoint: .local, session: URLSession(configuration: config))
    }

    /// A non-catalog model name: skips the disk-space check, which reads the
    /// real home volume and does not belong in an offline test.
    private let testModel = "pull-test-model:1b"

    private func stubPull(_ ndjson: String) {
        PullMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/api/pull") {
                return .respond(200, Data(ndjson.utf8))
            }
            if path.hasSuffix("/api/tags") {
                return .respond(200, Data(#"{"models": []}"#.utf8))
            }
            return .respond(200, Data())
        }
    }

    // MARK: - Success

    func testPullModel_SuccessStream_CompletesAndRefreshesModels() async throws {
        stubPull("""
        {"status":"pulling manifest"}
        {"status":"downloading","digest":"sha256:aaa","total":100,"completed":100}
        {"status":"downloading","digest":"sha256:bbb","total":300,"completed":300}
        {"status":"success"}

        """)
        let manager = makeManager()

        try await manager.pullModel(testModel)

        XCTAssertFalse(manager.isPulling)
        XCTAssertNil(manager.currentPullingModel)
        XCTAssertEqual(manager.pullProgress, 1.0)
        XCTAssertEqual(manager.pullStatus, "Download complete!")
        XCTAssertEqual(manager.pullCompletedBytes, 400)
        XCTAssertEqual(manager.pullTotalBytes, 400)
        XCTAssertNil(manager.lastError)

        let pull = log.snapshot.first { $0.path.hasSuffix("/api/pull") }
        XCTAssertEqual(pull?.method, "POST")
        let tags = log.snapshot.first { $0.path.hasSuffix("/api/tags") }
        XCTAssertNotNil(tags, "a successful pull must refresh the installed list")
    }

    // MARK: - Failure surfaces

    func testPullModel_ErrorLineInStream_ThrowsAndRecordsError() async {
        stubPull("""
        {"status":"pulling manifest"}
        {"error":"pull model manifest: file does not exist"}

        """)
        let manager = makeManager()

        do {
            try await manager.pullModel(testModel)
            XCTFail("the pull must fail when the stream carries an error object")
        } catch let error as OllamaModelError {
            guard case .pullFailed(let message) = error else {
                return XCTFail("expected pullFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("file does not exist"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(manager.isPulling)
        XCTAssertEqual(manager.lastError, OllamaModelError.pullFailed("pull model manifest: file does not exist").localizedDescription)
    }

    func testPullModel_StreamEndsWithoutSuccess_Throws() async {
        stubPull("""
        {"status":"downloading","digest":"sha256:aaa","total":100,"completed":100}
        {"status":"verifying sha256 digest"}

        """)
        let manager = makeManager()

        do {
            try await manager.pullModel(testModel)
            XCTFail("a stream without a success line must not count as downloaded")
        } catch let error as OllamaModelError {
            guard case .pullFailed(let message) = error else {
                return XCTFail("expected pullFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("ended before completing"), message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(manager.isPulling)
    }

    func testPullModel_HTTPError_Throws() async {
        PullMockURLProtocol.requestHandler = { _ in .respond(500, Data()) }
        let manager = makeManager()

        do {
            try await manager.pullModel(testModel)
            XCTFail("a non-200 response must fail the pull")
        } catch {
            XCTAssertFalse(manager.isPulling)
        }
    }

    func testPullModel_WhilePullInFlight_ThrowsAlreadyPulling() async throws {
        PullMockURLProtocol.requestHandler = { _ in .hang }
        let manager = makeManager()

        let firstPull = Task { try await manager.pullModel(testModel) }
        let started = await waitForCondition { manager.isPulling }
        XCTAssertTrue(started)

        do {
            try await manager.pullModel(testModel)
            XCTFail("a second concurrent pull must be rejected")
        } catch let error as OllamaModelError {
            guard case .alreadyPulling = error else {
                return XCTFail("expected alreadyPulling, got \(error)")
            }
        }

        manager.cancelPull()
        _ = try? await firstPull.value
    }

    // MARK: - Cancellation

    func testPullModel_Cancel_ThrowsCancellationAndResetsState() async {
        PullMockURLProtocol.requestHandler = { _ in .hang }
        let manager = makeManager()

        let pull = Task { try await manager.pullModel(testModel) }
        let started = await waitForCondition { manager.isPulling }
        XCTAssertTrue(started, "the pull must be in flight before cancelling")

        manager.cancelPull()

        do {
            try await pull.value
            XCTFail("a cancelled pull must throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertFalse(manager.isPulling)
        XCTAssertNil(manager.currentPullingModel)
        XCTAssertEqual(manager.pullProgress, 0)
        XCTAssertEqual(manager.pullStatus, "Cancelled")
    }
}
