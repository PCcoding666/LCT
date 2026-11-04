import XCTest
@testable import LCTMac

final class LocalModelStoreTests: XCTestCase, @unchecked Sendable {
    private let fixture = Data("GGUFfixture".utf8)
    private var descriptor: LocalTranslationModel {
        LocalTranslationModel(id: "fixture", filename: "fixture.gguf",
            downloadURL: URL(string: "https://example.invalid/model.gguf")!, byteCount: 11,
            sha256: "006770b014ffd382cd06d5148bb662d33f0b7448a316d85bfd415356b5f2aef1")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testModelValidation_MissingOrSameSizeCorruption_RejectsBeforeLoad() async throws {
        let root = try directory()
        let store = LocalModelStore(directory: root, model: descriptor)
        do { _ = try await store.verifiedModelURL(); XCTFail("Missing model accepted") } catch {}
        try Data("GGUFcorrupt".utf8).write(to: root.appendingPathComponent("fixture.gguf"))
        do { _ = try await store.verifiedModelURL(); XCTFail("Corrupt model accepted") } catch {}
    }

    func testDownload_ValidBytes_InstallsAndCanVerifyOffline() async throws {
        let root = try directory()
        let transport = FixtureModelTransport(directory: root, outcomes: [.file(fixture, 200)])
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        try await store.download()
        let url = try await store.verifiedModelURL()
        XCTAssertEqual(try Data(contentsOf: url), fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("resume.data").path))
    }

    func testDownload_HTTPErrorOrBadChecksum_DoesNotInstall() async throws {
        for outcome in [FixtureModelTransport.Outcome.file(fixture, 503), .file(Data("GGUFcorrupt".utf8), 200)] {
            let root = try directory()
            let transport = FixtureModelTransport(directory: root, outcomes: [outcome])
            let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
            do { try await store.download(); XCTFail("Invalid download accepted") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.gguf").path))
        }
    }

    func testDownload_CancelThenRetry_UsesResumeAndInstallsVerifiedBytes() async throws {
        let root = try directory()
        let transport = FixtureModelTransport(directory: root,
            outcomes: [.cancel(Data("resume-token".utf8)), .resumedFile(fixture)])
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        do { try await store.download(); XCTFail("Cancellation swallowed") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.gguf").path))
        try await store.download()
        let url = try await store.verifiedModelURL()
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }

    func testVerification_CancelledTask_DoesNotReturnLoadableModel() async throws {
        let root = try directory()
        try fixture.write(to: root.appendingPathComponent("fixture.gguf"))
        let store = LocalModelStore(directory: root, model: descriptor)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.verifiedModelURL()
        }
        do { _ = try await task.value; XCTFail("Cancellation swallowed") } catch is CancellationError {}
    }

    func testDownload_CorruptReplacement_PreservesInstalledModel() async throws {
        let root = try directory()
        try fixture.write(to: root.appendingPathComponent("fixture.gguf"))
        let transport = FixtureModelTransport(directory: root, outcomes: [.file(Data("GGUFcorrupt".utf8), 200)])
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        do { try await store.download(); XCTFail("Corrupt replacement accepted") } catch {}
        let url = try await store.verifiedModelURL()
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }

    func testDownload_ExpiredResumeData_RestartsAndRemainsRetryable() async throws {
        let root = try directory()
        try Data("expired".utf8).write(to: root.appendingPathComponent("resume.data"))
        let transport = FixtureModelTransport(directory: root, outcomes: [.invalidResume, .file(fixture, 200)])
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        try await store.download()
        let url = try await store.verifiedModelURL()
        XCTAssertEqual(try Data(contentsOf: url), fixture)
    }

    @MainActor
    func testShutdown_DelayedCancellation_WaitsUntilResumeDataIsPersisted() async throws {
        let root = try directory()
        let transport = DelayedCancellationModelTransport()
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        let service = EmbeddedTranslationService(store: store)
        let download = Task { try await service.downloadModel() }
        await transport.started.wait()
        var shutdownFinished = false
        let shutdown = Task {
            await service.cancelDownloadAndWait()
            shutdownFinished = true
        }
        await transport.cancelled.wait()
        XCTAssertFalse(shutdownFinished, "Quit must await the asynchronous resume-data callback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("resume.data").path))
        await transport.allowCompletion.signal()
        await shutdown.value
        do { try await download.value; XCTFail("Cancellation swallowed") } catch is CancellationError {}
        XCTAssertTrue(shutdownFinished)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("resume.data")), Data("saved-resume".utf8))
        XCTAssertEqual(service.state, .notDownloaded)
    }

    @MainActor
    func testService_InitializationDoesNotDownloadOrVerifyExistingFile() async throws {
        let root = try directory()
        let transport = FixtureModelTransport(directory: root, outcomes: [])
        let store = LocalModelStore(directory: root, model: descriptor, transport: transport)
        let missing = EmbeddedTranslationService(store: store)
        XCTAssertEqual(missing.state, .notDownloaded)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("fixture.gguf"))
        let present = EmbeddedTranslationService(store: store)
        XCTAssertEqual(present.state, .downloaded)
        XCTAssertFalse(present.isReady)
        // Full validation belongs to the explicit load action, away from MainActor.
        do { try await present.loadModel(); XCTFail("Corrupt model loaded") } catch {}
        guard case .failed = present.state else { return XCTFail("Missing actionable failure") }
    }

    func testUTF8Stream_SplitMultibyteTokens_EmitsOnlyCompleteText() throws {
        var decoder = UTF8TokenDecoder()
        XCTAssertEqual(try decoder.append([0xe4]), "")
        XCTAssertEqual(try decoder.append([0xbd]), "")
        XCTAssertEqual(try decoder.append([0xa0, 0x21]), "你!")
        XCTAssertEqual(try decoder.finish(), "")
        XCTAssertThrowsError(try decoder.append([0xff]))
    }

    func testUTF8Stream_TruncatedScalar_FailsInsteadOfReplacingText() throws {
        var decoder = UTF8TokenDecoder()
        XCTAssertEqual(try decoder.append([0xf0, 0x9f]), "")
        XCTAssertThrowsError(try decoder.finish())
    }

    func testRuntime_MissingModelAndUnloadedGeneration_ReturnRecoverableErrors() async throws {
        let runtime = LlamaTranslationRuntime()
        do { try await runtime.load(at: try directory().appendingPathComponent("absent.gguf")); XCTFail("Missing model loaded") } catch {}
        do {
            for try await _ in runtime.stream(messages: [.init(role: "user", content: "Hello")]) {}
            XCTFail("Unloaded inference succeeded")
        } catch LocalRuntimeError.notLoaded {} catch { XCTFail("Unexpected error: \(error)") }
        await runtime.unload()
    }
}

private actor ModelTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private struct DelayedCancellationModelTransport: ModelDownloadTransport {
    let started = ModelTestSignal()
    let cancelled = ModelTestSignal()
    let allowCompletion = ModelTestSignal()
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> ModelDownloadArtifact {
        try await withTaskCancellationHandler {
            await started.signal()
            await allowCompletion.wait()
            throw ModelDownloadFailure(message: "Cancelled", resumeData: Data("saved-resume".utf8), cancelled: true)
        } onCancel: {
            Task { await cancelled.signal() }
        }
    }
}

private actor FixtureModelTransport: ModelDownloadTransport {
    enum Outcome: Sendable { case file(Data, Int), cancel(Data), resumedFile(Data), invalidResume }
    let directory: URL
    var outcomes: [Outcome]
    init(directory: URL, outcomes: [Outcome]) { self.directory = directory; self.outcomes = outcomes }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> ModelDownloadArtifact {
        let outcome = outcomes.removeFirst()
        switch outcome {
        case .invalidResume: throw URLError(.cannotOpenFile)
        case .cancel(let data): throw ModelDownloadFailure(message: "Cancelled", resumeData: data, cancelled: true)
        case .file(let bytes, let status): return try artifact(bytes, status)
        case .resumedFile(let bytes):
            guard resumeData == Data("resume-token".utf8) else { throw URLError(.cannotOpenFile) }
            return try artifact(bytes, 206)
        }
    }
    private func artifact(_ bytes: Data, _ status: Int) throws -> ModelDownloadArtifact {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return ModelDownloadArtifact(url: url, statusCode: status)
    }
}
