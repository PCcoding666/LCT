import XCTest
@testable import LCTMac

@MainActor
final class TranslationEngineQueueTests: XCTestCase {
    private let historyDatabase = TemporaryHistoryDatabase()
    /// A native boundary that delivers buffered tokens even after cancellation.
    /// Real queue generation checks must prevent those tokens reaching the UI.
    private final class LateStreamEngine: TranslationEngine {
        struct Call {
            let onToken: @MainActor (String) -> Void
            var continuation: CheckedContinuation<Int, Error>?
        }
        var calls: [Call] = []
        func updateSettings(_ settings: AppSettings) {}
        func translate(text: String, context: [TranslationEntry]) async throws -> (String, Int) {
            throw URLError(.unsupportedURL)
        }
        func translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int {
            try await withCheckedThrowingContinuation { continuation in
                calls.append(Call(onToken: onToken, continuation: continuation))
                onToken("Partial output")
            }
        }
        func finish(_ index: Int, token: String) {
            calls[index].onToken(token)
            let continuation = calls[index].continuation
            calls[index].continuation = nil
            continuation?.resume(returning: 1)
        }
        func releaseAll() {
            for index in calls.indices where calls[index].continuation != nil {
                let continuation = calls[index].continuation
                calls[index].continuation = nil
                continuation?.resume(throwing: CancellationError())
            }
        }
    }

    private func makeViewModel(engine: LateStreamEngine) -> (TranscriptionViewModel, CaptionOnlyTestHarness.Speech) {
        var settings = CaptionOnlyTestHarness.settings()
        settings.translationEnabled = true
        let speech = CaptionOnlyTestHarness.Speech()
        let capture = AudioCaptureService(makeSystemAudioTap: { CaptionOnlyTestHarness.Tap() })
        let viewModel = TranscriptionViewModel(
            settings: settings, audioCaptureService: capture, speechEngine: speech,
            translationEngine: engine, translationReadiness: { true },
            historyService: historyDatabase.service,
            persistSettings: { _ in true }
        )
        return (viewModel, speech)
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testTranslation_DisabledDuringStream_DiscardsLateTokensAndCompletion() async {
        let engine = LateStreamEngine()
        defer { engine.releaseAll() }
        let (viewModel, speech) = makeViewModel(engine: engine)
        await viewModel.start()
        speech.emit("Keep the source.")
        let began = await waitFor { engine.calls.count == 1 }
        guard began else { XCTFail("translation did not start"); await viewModel.stop(); return }
        XCTAssertEqual(viewModel.segments.first?.translatedText, "Partial output")

        var settings = viewModel.settings
        settings.translationEnabled = false
        viewModel.updateSettings(settings)
        engine.finish(0, token: "LATE OBSOLETE OUTPUT")
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(viewModel.captureState, .capturing)
        XCTAssertEqual(viewModel.segments.first?.state, .captionOnly)
        XCTAssertEqual(viewModel.segments.first?.translatedText, "")
        XCTAssertEqual(viewModel.sessionTranscript.entries.first?.sourceText, "Keep the source.")
        XCTAssertEqual(viewModel.sessionTranscript.entries.first?.translatedText, "")
        XCTAssertEqual(viewModel.liveTranslation, "")
        await viewModel.stop()
    }

    func testTranslation_TargetChangedDuringStream_OldTokensCannotContaminateNewRequest() async {
        let engine = LateStreamEngine()
        defer { engine.releaseAll() }
        let (viewModel, speech) = makeViewModel(engine: engine)
        await viewModel.start()
        let startedAt = viewModel.sessionTranscript.startedAt
        speech.emit("Old language source.")
        let oldBegan = await waitFor { engine.calls.count == 1 }
        guard oldBegan else { XCTFail("old translation did not start"); await viewModel.stop(); return }

        viewModel.setTargetLanguage(.japanese)
        speech.emit("New language source.")
        let newBegan = await waitFor { engine.calls.count == 2 }
        guard newBegan else { XCTFail("new translation did not start"); await viewModel.stop(); return }
        engine.finish(0, token: "STALE TRANSLATION")
        engine.finish(1, token: " in the new language")
        let completed = await waitFor { viewModel.segments.last?.state == .translated }

        XCTAssertTrue(completed)
        XCTAssertEqual(viewModel.sessionTranscript.startedAt, startedAt)
        XCTAssertEqual(viewModel.segments.first?.state, .captionOnly)
        XCTAssertEqual(viewModel.sessionTranscript.entries.first?.translatedText, "")
        XCTAssertEqual(viewModel.sessionTranscript.entries.last?.translatedText, "Partial output in the new language")
        XCTAssertEqual(viewModel.segments.last?.translatedText, "Partial output in the new language")
        XCTAssertFalse(viewModel.segments.contains { $0.translatedText.contains("STALE") })
        await viewModel.stop()
    }
}
