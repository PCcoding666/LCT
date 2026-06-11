import XCTest
@testable import LCTMac

/// Tests for HistoryService SQLite CRUD operations
final class HistoryServiceTests: XCTestCase {

    var historyService: HistoryService!
    var databaseDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCTMacTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        let databasePath = databaseDirectory.appendingPathComponent("history.sqlite").path
        historyService = HistoryService(databasePath: databasePath)
    }

    override func tearDownWithError() throws {
        historyService = nil
        if let databaseDirectory {
            try? FileManager.default.removeItem(at: databaseDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Create Tests

    func testLogTranslation() throws {
        let entry = makeEntry(source: "Hello", translated: "你好")

        try historyService.logTranslation(entry)

        let count = try historyService.getCount()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testLogMultipleTranslations() throws {
        let entries = [
            makeEntry(source: "Hello", translated: "你好"),
            makeEntry(source: "World", translated: "世界"),
            makeEntry(source: "Good morning", translated: "早上好"),
        ]

        for entry in entries {
            try historyService.logTranslation(entry)
        }

        let count = try historyService.getCount()
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    // MARK: - Read Tests

    func testLoadRecentTranslations() throws {
        try historyService.clearHistory()

        let entries = (1...5).map { i in
            makeEntry(source: "Text \(i)", translated: "翻译 \(i)")
        }
        for entry in entries {
            try historyService.logTranslation(entry)
        }

        let loaded = try historyService.loadRecentTranslations(limit: 3)
        XCTAssertEqual(loaded.count, 3)
    }

    func testLoadAllTranslations() throws {
        try historyService.clearHistory()

        let entries = (1...3).map { i in
            makeEntry(source: "Text \(i)", translated: "翻译 \(i)")
        }
        for entry in entries {
            try historyService.logTranslation(entry)
        }

        let loaded = try historyService.loadAllTranslations()
        XCTAssertEqual(loaded.count, 3)
    }

    // MARK: - Search Tests

    func testSearchBySourceText() throws {
        try historyService.clearHistory()

        try historyService.logTranslation(makeEntry(source: "Hello world", translated: "你好世界"))
        try historyService.logTranslation(makeEntry(source: "Goodbye", translated: "再见"))

        let results = try historyService.searchTranslations(query: "Hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceText, "Hello world")
    }

    func testSearchByTranslatedText() throws {
        try historyService.clearHistory()

        try historyService.logTranslation(makeEntry(source: "Hello", translated: "你好"))
        try historyService.logTranslation(makeEntry(source: "World", translated: "世界"))

        let results = try historyService.searchTranslations(query: "世界")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.translatedText, "世界")
    }

    func testSearchNoResults() throws {
        try historyService.clearHistory()

        try historyService.logTranslation(makeEntry(source: "Hello", translated: "你好"))

        let results = try historyService.searchTranslations(query: "nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Delete Tests

    func testDeleteById() throws {
        try historyService.clearHistory()

        let entry = makeEntry(source: "Delete me", translated: "删除我")
        try historyService.logTranslation(entry)

        let countBefore = try historyService.getCount()
        XCTAssertEqual(countBefore, 1)

        try historyService.deleteTranslation(withId: entry.id)

        let countAfter = try historyService.getCount()
        XCTAssertEqual(countAfter, 0)
    }

    func testClearHistory() throws {
        for i in 1...5 {
            try historyService.logTranslation(makeEntry(source: "Text \(i)", translated: "翻译 \(i)"))
        }

        try historyService.clearHistory()

        let count = try historyService.getCount()
        XCTAssertEqual(count, 0)
    }

    func testPruneHistory_RemovesOldEntriesAndKeepsNewestMaxEntries() throws {
        let oldDate = Calendar.current.date(byAdding: .day, value: -10, to: Date())!

        try historyService.logTranslation(makeEntry(source: "Old", translated: "旧", timestamp: oldDate))
        for i in 1...5 {
            try historyService.logTranslation(makeEntry(source: "Recent \(i)", translated: "最近 \(i)"))
        }

        try historyService.pruneHistory(retentionDays: 7, maxEntries: 3)

        let loaded = try historyService.loadAllTranslations()
        XCTAssertEqual(loaded.count, 3)
        XCTAssertFalse(loaded.contains { $0.sourceText == "Old" })
    }

    func testGetLastTranslation() throws {
        try historyService.clearHistory()

        try historyService.logTranslation(makeEntry(source: "First", translated: "第一"))
        try historyService.logTranslation(makeEntry(source: "Last", translated: "最后"))

        let last = try historyService.getLastTranslation()
        XCTAssertNotNil(last)
        XCTAssertEqual(last?.sourceText, "Last")
    }

    // MARK: - Export Tests

    func testExportToCSV() throws {
        try historyService.clearHistory()

        try historyService.logTranslation(makeEntry(source: "Hello", translated: "你好"))

        let csv = try historyService.exportToCSV()

        // Should contain header
        XCTAssertTrue(csv.contains("Source Text"))
        XCTAssertTrue(csv.contains("Translated Text"))
        // Should contain data
        XCTAssertTrue(csv.contains("Hello"))
        XCTAssertTrue(csv.contains("你好"))
    }

    // MARK: - Async Tests

    func testLogTranslationAsync() async throws {
        let entry = makeEntry(source: "Async hello", translated: "异步你好")

        try await historyService.logTranslationAsync(entry)

        let count = try historyService.getCount()
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testLoadRecentTranslationsAsync() async throws {
        try historyService.clearHistory()

        for i in 1...3 {
            try historyService.logTranslation(makeEntry(source: "Async \(i)", translated: "异步 \(i)"))
        }

        let loaded = try await historyService.loadRecentTranslationsAsync(limit: 10)
        XCTAssertGreaterThanOrEqual(loaded.count, 3)
    }

    // MARK: - Helpers

    private func makeEntry(source: String, translated: String, timestamp: Date = Date()) -> TranslationEntry {
        TranslationEntry(
            sourceText: source,
            translatedText: translated,
            speaker: nil,
            targetLanguage: "Chinese (Simplified)",
            timestamp: timestamp,
            latencyMs: 100
        )
    }
}
