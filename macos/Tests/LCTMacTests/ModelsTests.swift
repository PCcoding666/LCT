import XCTest
@testable import LCTMac

/// Tests for Models
final class ModelsTests: XCTestCase {

    // MARK: - TranslationEntry Tests

    func testTranslationEntry_Initialization() {
        let entry = TranslationEntry(
            sourceText: "Hello",
            translatedText: "你好",
            speaker: "Speaker 1",
            targetLanguage: "Chinese",
            latencyMs: 150
        )

        XCTAssertEqual(entry.sourceText, "Hello")
        XCTAssertEqual(entry.translatedText, "你好")
        XCTAssertEqual(entry.speaker, "Speaker 1")
        XCTAssertEqual(entry.targetLanguage, "Chinese")
        XCTAssertEqual(entry.latencyMs, 150)
        XCTAssertNotNil(entry.id)
    }

    func testTranslationEntry_FormattedLatency() {
        let entry = TranslationEntry(
            sourceText: "Test",
            translatedText: "测试",
            targetLanguage: "Chinese",
            latencyMs: 250
        )

        XCTAssertEqual(entry.formattedLatency, "250 ms")
    }

    func testTranslationEntry_FormattedTimestamp() {
        let entry = TranslationEntry(
            sourceText: "Test",
            translatedText: "测试",
            targetLanguage: "Chinese"
        )

        // Just verify it returns a non-empty string
        XCTAssertFalse(entry.formattedTimestamp.isEmpty)
    }

    func testTranslationEntry_Equatable() {
        let id = UUID()
        let date = Date()

        let entry1 = TranslationEntry(
            id: id,
            sourceText: "Hello",
            translatedText: "你好",
            targetLanguage: "Chinese",
            timestamp: date,
            latencyMs: 100
        )

        let entry2 = TranslationEntry(
            id: id,
            sourceText: "Hello",
            translatedText: "你好",
            targetLanguage: "Chinese",
            timestamp: date,
            latencyMs: 100
        )

        XCTAssertEqual(entry1, entry2)
    }

    func testTranslationEntry_Codable() throws {
        let entry = TranslationEntry(
            sourceText: "Hello",
            translatedText: "你好",
            speaker: "Test Speaker",
            targetLanguage: "Chinese",
            latencyMs: 200
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TranslationEntry.self, from: data)

        XCTAssertEqual(entry.id, decoded.id)
        XCTAssertEqual(entry.sourceText, decoded.sourceText)
        XCTAssertEqual(entry.translatedText, decoded.translatedText)
        XCTAssertEqual(entry.speaker, decoded.speaker)
        XCTAssertEqual(entry.targetLanguage, decoded.targetLanguage)
        XCTAssertEqual(entry.latencyMs, decoded.latencyMs)
    }

    // MARK: - TranslationHistory Tests

    func testTranslationHistory_Add() {
        var history = TranslationHistory()

        let entry = TranslationEntry(
            sourceText: "Test",
            translatedText: "测试",
            targetLanguage: "Chinese"
        )

        history.add(entry)

        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.sourceText, "Test")
    }

    func testTranslationHistory_Search() {
        var history = TranslationHistory()

        history.add(TranslationEntry(
            sourceText: "Hello world",
            translatedText: "你好世界",
            targetLanguage: "Chinese"
        ))

        history.add(TranslationEntry(
            sourceText: "Good morning",
            translatedText: "早上好",
            targetLanguage: "Chinese"
        ))

        let results = history.search("hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceText, "Hello world")
    }

    func testTranslationHistory_SearchTranslatedText() {
        var history = TranslationHistory()

        history.add(TranslationEntry(
            sourceText: "Hello",
            translatedText: "你好世界",
            targetLanguage: "Chinese"
        ))

        let results = history.search("世界")
        XCTAssertEqual(results.count, 1)
    }

    func testTranslationHistory_DateRange() {
        var history = TranslationHistory()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        history.add(TranslationEntry(
            sourceText: "Today's entry",
            translatedText: "今天的条目",
            targetLanguage: "Chinese",
            timestamp: now
        ))

        let results = history.entries(from: yesterday, to: tomorrow)
        XCTAssertEqual(results.count, 1)
    }

    func testTranslationHistory_ExportToCSV() {
        var history = TranslationHistory()

        history.add(TranslationEntry(
            sourceText: "Hello",
            translatedText: "你好",
            speaker: "Speaker 1",
            targetLanguage: "Chinese",
            latencyMs: 100
        ))

        let csv = history.exportToCSV()

        XCTAssertTrue(csv.contains("Source Text"))
        XCTAssertTrue(csv.contains("Translated Text"))
        XCTAssertTrue(csv.contains("Hello"))
        XCTAssertTrue(csv.contains("你好"))
    }

    func testTranslationHistory_ExportToCSV_EscapesAllTextFields() {
        var history = TranslationHistory()

        history.add(TranslationEntry(
            sourceText: "Hello, \"team\"",
            translatedText: "你好\n团队",
            speaker: "Speaker \"A\"",
            targetLanguage: "Chinese, Simplified",
            latencyMs: 100
        ))

        let csv = history.exportToCSV()

        XCTAssertTrue(csv.contains("\"Hello, \"\"team\"\"\""))
        XCTAssertTrue(csv.contains("\"你好\n团队\""))
        XCTAssertTrue(csv.contains("\"Speaker \"\"A\"\"\""))
        XCTAssertTrue(csv.contains("\"Chinese, Simplified\""))
    }

    // MARK: - SourceLanguage Tests

    func testSourceLanguage_DisplayName() {
        XCTAssertEqual(SourceLanguage.english.displayName, "English (US)")
        XCTAssertEqual(SourceLanguage.chinese.displayName, "Chinese (Simplified)")
        XCTAssertEqual(SourceLanguage.japanese.displayName, "Japanese")
    }

    func testSourceLanguage_RawValue() {
        XCTAssertEqual(SourceLanguage.english.rawValue, "en-US")
        XCTAssertEqual(SourceLanguage.chinese.rawValue, "zh-CN")
        XCTAssertEqual(SourceLanguage.japanese.rawValue, "ja-JP")
    }

    func testSourceLanguage_AllCases() {
        XCTAssertEqual(SourceLanguage.allCases.count, 14)
    }

    // MARK: - TargetLanguage Tests

    func testTargetLanguage_DisplayName() {
        XCTAssertEqual(TargetLanguage.chinese.displayName, "Chinese")
        XCTAssertEqual(TargetLanguage.english.displayName, "English")
    }

    func testTargetLanguage_NativeName() {
        XCTAssertEqual(TargetLanguage.chinese.nativeName, "中文")
        XCTAssertEqual(TargetLanguage.japanese.nativeName, "日本語")
        XCTAssertEqual(TargetLanguage.korean.nativeName, "한국어")
    }

    func testTargetLanguage_AllCases() {
        XCTAssertEqual(TargetLanguage.allCases.count, 10)
    }

    // MARK: - AppSettings Tests

    func testAppSettings_DefaultValues() {
        let settings = AppSettings()

        XCTAssertTrue(settings.captureSystemAudio)
        XCTAssertTrue(settings.captureMicrophone)
        XCTAssertEqual(settings.sourceLanguage, .english)
        XCTAssertEqual(settings.ollamaHost, "localhost")
        XCTAssertEqual(settings.ollamaPort, 11434)
        XCTAssertEqual(settings.ollamaModel, "qwen3.5:4b-mlx")
        XCTAssertEqual(settings.ollamaTimeout, 30)
        XCTAssertEqual(settings.ollamaTemperature, 0.3)
        XCTAssertEqual(settings.targetLanguage, .chinese)
        XCTAssertTrue(settings.contextAware)
        XCTAssertEqual(settings.maxContextEntries, 5)
        XCTAssertEqual(settings.historyRetentionDays, 30)
        XCTAssertEqual(settings.historyMaxEntries, 5000)
        XCTAssertTrue(settings.showOverlay)
    }

    func testAppSettings_OllamaURL() {
        let settings = AppSettings()

        XCTAssertEqual(settings.ollamaURL, "http://localhost:11434")
        XCTAssertEqual(settings.ollamaAPIEndpoint, "http://localhost:11434/api/chat")
    }

    func testAppSettings_OllamaURL_CustomHostPort() {
        var settings = AppSettings()
        settings.ollamaHost = "192.168.1.100"
        settings.ollamaPort = 8080

        XCTAssertEqual(settings.ollamaURL, "http://192.168.1.100:8080")
        XCTAssertEqual(settings.ollamaAPIEndpoint, "http://192.168.1.100:8080/api/chat")
    }

    func testAppSettings_TranslationPrompt_Default() {
        let settings = AppSettings()
        let prompt = settings.translationPrompt

        XCTAssertTrue(prompt.contains("Chinese"))
        XCTAssertTrue(prompt.contains("professional"))
    }

    func testAppSettings_TranslationPrompt_CustomLanguage() {
        var settings = AppSettings()
        settings.targetLanguage = .japanese

        let prompt = settings.translationPrompt
        XCTAssertTrue(prompt.contains("Japanese"))
    }

    func testAppSettings_TranslationPrompt_Custom() {
        var settings = AppSettings()
        settings.customPrompt = "Custom prompt for {TARGET_LANGUAGE}"

        let prompt = settings.translationPrompt
        XCTAssertEqual(prompt, "Custom prompt for Chinese")
    }

    func testAppSettings_Codable() throws {
        let settings = AppSettings()

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppSettings.self, from: data)

        XCTAssertEqual(settings, decoded)
    }

    func testAppSettings_Equatable() {
        let settings1 = AppSettings()
        let settings2 = AppSettings()

        XCTAssertEqual(settings1, settings2)
    }
}
