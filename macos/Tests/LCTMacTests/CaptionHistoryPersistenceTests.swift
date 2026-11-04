import XCTest
@testable import LCTMac

@MainActor
final class CaptionHistoryPersistenceTests: XCTestCase {
    private final class DeferredTranslator: CaptionOnlyTestHarness.Translator {
        private var completion: (() -> Void)?
        var isWaiting: Bool { completion != nil }
        override func translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int {
            await withCheckedContinuation { continuation in
                completion = {
                    onToken("The completed translation.")
                    continuation.resume(returning: 12)
                }
            }
        }
        func finish() {
            let callback = completion
            completion = nil
            callback?()
        }
    }

    private func settings(translation: Bool = false, history: Bool = true) -> AppSettings {
        var settings = CaptionOnlyTestHarness.settings()
        settings.historyEnabled = history
        settings.translationEnabled = translation
        return settings
    }

    func testHistory_CaptionOnlyWithConsent_PersistsSourceUsingSegmentID() async throws {
        let harness = CaptionOnlyTestHarness(settings: settings())
        await harness.viewModel.start()
        harness.speech.emit("Persist the original caption.")

        await harness.viewModel.flushHistoryPersistence()
        let rows = try harness.historyDatabase.service.loadAllTranslations()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sourceText, "Persist the original caption.")
        XCTAssertEqual(rows.first?.translatedText, "")
        XCTAssertEqual(rows.first?.id, harness.viewModel.segments.first?.id)
        await harness.viewModel.stop()

        let reopened = HistoryService(databasePath: harness.historyDatabase.directory.appendingPathComponent("history.sqlite").path)
        XCTAssertEqual(try reopened.loadAllTranslations(), rows, "a newly opened database connection must see retained source-only captions")
    }

    func testHistory_TranslationFailure_KeepsSourceWithoutErrorText() async throws {
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        translator.shouldFail = true
        let harness = CaptionOnlyTestHarness(settings: settings(translation: true), translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("Keep source when inference fails.")
        let failed = await harness.waitFor { harness.viewModel.segments.first?.state == .failed }
        XCTAssertTrue(failed)

        await harness.viewModel.flushHistoryPersistence()
        let rows = try harness.historyDatabase.service.loadAllTranslations()

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sourceText, "Keep source when inference fails.")
        XCTAssertEqual(rows.first?.translatedText, "")
        XCTAssertEqual(rows.first?.id, harness.viewModel.segments.first?.id)
        await harness.viewModel.stop()
    }

    func testHistory_TranslationCompletes_UpdatesPersistedSourceRowWithoutDuplicate() async throws {
        let translator = DeferredTranslator()
        translator.ready = true
        defer { translator.finish() }
        let harness = CaptionOnlyTestHarness(settings: settings(translation: true), translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("Persist before inference finishes.")
        let waiting = await harness.waitFor { translator.isWaiting }
        XCTAssertTrue(waiting)
        await harness.viewModel.flushHistoryPersistence()
        let sourceRows = try harness.historyDatabase.service.loadAllTranslations()
        XCTAssertEqual(sourceRows.count, 1, "the source must be durable before slow translation completes")
        XCTAssertEqual(sourceRows.first?.translatedText, "")

        translator.finish()
        let translated = await harness.waitFor { harness.viewModel.segments.first?.state == .translated }
        XCTAssertTrue(translated)
        await harness.viewModel.flushHistoryPersistence()
        let completedRows = try harness.historyDatabase.service.loadAllTranslations()

        XCTAssertEqual(completedRows.count, 1)
        XCTAssertEqual(completedRows.first?.id, sourceRows.first?.id)
        XCTAssertEqual(completedRows.first?.id, harness.viewModel.segments.first?.id)
        XCTAssertEqual(completedRows.first?.timestamp, sourceRows.first?.timestamp)
        XCTAssertEqual(completedRows.first?.translatedText, "The completed translation.")
        await harness.viewModel.stop()
    }

    func testHistory_ConsentOff_CaptionsAndTranslationsDoNotCreateRows() async throws {
        let translator = CaptionOnlyTestHarness.Translator()
        translator.ready = true
        let harness = CaptionOnlyTestHarness(settings: settings(translation: true, history: false), translator: translator)
        await harness.viewModel.start()
        harness.speech.emit("In-memory session only.")
        let translated = await harness.waitFor { harness.viewModel.segments.first?.state == .translated }
        XCTAssertTrue(translated)

        await harness.viewModel.flushHistoryPersistence()

        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.count, 1)
        XCTAssertEqual(try harness.historyDatabase.service.getCount(), 0)
        await harness.viewModel.stop()
    }

    func testHistory_ConsentOff_PreservesPreviouslyRetainedRows() async throws {
        let harness = CaptionOnlyTestHarness(settings: settings(history: false))
        let retained = TranslationEntry(sourceText: "Earlier consented history", translatedText: "", targetLanguage: "English", latencyMs: 0)
        try harness.historyDatabase.service.logTranslation(retained)
        let retainedRows = try harness.historyDatabase.service.loadAllTranslations()
        await harness.viewModel.start()
        harness.speech.emit("Do not retain this new session.")

        await harness.viewModel.flushHistoryPersistence()

        XCTAssertEqual(try harness.historyDatabase.service.loadAllTranslations(), retainedRows)
        await harness.viewModel.stop()
    }

    func testHistory_ASRRollback_DeletesRevokedSourceBeforeReplacement() async throws {
        let harness = CaptionOnlyTestHarness(settings: settings())
        await harness.viewModel.start()
        let taskID = UUID()
        harness.speech.emit("Hello world.", taskID: taskID)
        await harness.viewModel.flushHistoryPersistence()
        XCTAssertEqual(try harness.historyDatabase.service.getCount(), 1)

        harness.speech.emit("Hallo something entirely different", isVolatile: true, taskID: taskID)
        await harness.viewModel.flushHistoryPersistence()

        XCTAssertTrue(harness.viewModel.sessionTranscript.entries.isEmpty)
        XCTAssertEqual(try harness.historyDatabase.service.getCount(), 0, "revoked source-only captions must be removed from retained history")
        await harness.viewModel.stop()
        await harness.viewModel.flushHistoryPersistence()
        XCTAssertEqual(try harness.historyDatabase.service.loadAllTranslations().map(\.sourceText), ["Hallo something entirely different"])
    }
}
