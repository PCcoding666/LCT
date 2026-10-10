import XCTest
@testable import LCTMac

/// Tests for SessionExporter: full documents for all three formats, Markdown
/// escaping, SRT cue timing rules, and file name generation. All dates are
/// pinned to UTC so the expectations hold in any host time zone.
final class SessionExporterTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-11 14:03:00 UTC
    private let start = Date(timeIntervalSince1970: 1_791_727_380)

    override func setUp() {
        super.setUp()
        // Guard the fixture constant: it must really be 2026-10-11 14:03 UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 3)
    }

    private struct Line {
        let lane: AudioSource
        let text: String
        var translation: String = ""
        /// Seconds after session start when the caption was finalized.
        let offset: TimeInterval
    }

    private func makeTranscript(lines: [Line], withStart: Bool = true) -> SessionTranscript {
        var transcript = SessionTranscript()
        if withStart {
            transcript.begin(at: start)
        }
        for line in lines {
            let id = UUID()
            transcript.append(id: id, source: line.lane, sourceText: line.text, finalizedAt: start.addingTimeInterval(line.offset))
            if !line.translation.isEmpty {
                transcript.updateTranslation(id: id, text: line.translation)
            }
        }
        return transcript
    }

    private func bilingualTranscript() -> SessionTranscript {
        makeTranscript(lines: [
            Line(lane: .system,
                 text: "大家好，今天我们来聊一聊大语言模型。",
                 translation: "Hello everyone, today we'll talk about large language models.",
                 offset: 83),
            Line(lane: .microphone,
                 text: "No translation here.",
                 offset: 754),
        ])
    }

    // MARK: - Markdown

    func testSessionExporter_Markdown_FullDocument() {
        let output = SessionExporter.export(
            bilingualTranscript(),
            format: .markdown,
            sourceLanguages: "ZH",
            targetLanguage: "EN",
            timeZone: utc
        )

        let expected = """
        # LCT Session — 2026-10-11 14:03

        - Duration: 00:12:34
        - Languages: ZH → EN
        - Lines: 2

        **[00:01:23] SYS** 大家好，今天我们来聊一聊大语言模型。
        > Hello everyone, today we'll talk about large language models.

        **[00:12:34] MIC** No translation here.

        """
        XCTAssertEqual(output, expected)
    }

    func testSessionExporter_Markdown_LeadingMarkers_AreEscaped() {
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "# Heading", offset: 1),
            Line(lane: .system, text: "> quoted", offset: 2),
            Line(lane: .system, text: "- list", offset: 3),
            Line(lane: .system, text: "* bullet", translation: "# 译", offset: 4),
        ])

        let output = SessionExporter.export(
            transcript,
            format: .markdown,
            sourceLanguages: "EN",
            targetLanguage: "ZH",
            timeZone: utc
        )

        XCTAssertTrue(output.contains("** \\# Heading"), "leading # must not become a heading")
        XCTAssertTrue(output.contains("** \\> quoted"), "leading > must not become a quote")
        XCTAssertTrue(output.contains("** \\- list"), "leading - must not become a list item")
        XCTAssertTrue(output.contains("** \\* bullet"), "leading * must not become a list item")
        XCTAssertTrue(output.contains("> \\# 译"), "the translation line must escape its leading marker too")
    }

    func testSessionExporter_Markdown_EmptyTranscript_HasZeroCounts() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)

        let output = SessionExporter.export(
            transcript,
            format: .markdown,
            sourceLanguages: "ZH",
            targetLanguage: "EN",
            timeZone: utc
        )

        let expected = """
        # LCT Session — 2026-10-11 14:03

        - Duration: 00:00:00
        - Languages: ZH → EN
        - Lines: 0

        """
        XCTAssertEqual(output, expected)
    }

    // MARK: - Plain text

    func testSessionExporter_PlainText_FullDocument() {
        let output = SessionExporter.export(
            bilingualTranscript(),
            format: .plainText,
            sourceLanguages: "ZH",
            targetLanguage: "EN",
            timeZone: utc
        )

        let expected = """
        LCT Session — 2026-10-11 14:03 (ZH → EN)

        [00:01:23] [SYS] 大家好，今天我们来聊一聊大语言模型。
                         Hello everyone, today we'll talk about large language models.

        [00:12:34] [MIC] No translation here.

        """
        XCTAssertEqual(output, expected)
    }

    // MARK: - SRT

    func testSessionExporter_SRT_FullDocument() {
        let output = SessionExporter.export(
            bilingualTranscript(),
            format: .srt,
            sourceLanguages: "ZH",
            targetLanguage: "EN",
            timeZone: utc
        )

        // Cue 1: 18 chars × 0.07s = 1.26s before its 83.0s end → 81.74s.
        // Cue 2: 20 chars × 0.07s = 1.4s before its 754.0s end → 752.6s.
        let expected = """
        1
        00:01:21,740 --> 00:01:23,000
        大家好，今天我们来聊一聊大语言模型。
        Hello everyone, today we'll talk about large language models.

        2
        00:12:32,600 --> 00:12:34,000
        No translation here.

        """
        XCTAssertEqual(output, expected)
    }

    func testSessionExporter_SRT_DurationEstimate_ClampedBelow() {
        // 5 chars × 0.07s = 0.35s → clamped to 1.0s.
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "Short", offset: 10),
        ])

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        XCTAssertTrue(output.contains("00:00:09,000 --> 00:00:10,000"), "got:\n\(output)")
    }

    func testSessionExporter_SRT_DurationEstimate_ClampedAbove() {
        // 200 chars × 0.07s = 14s → clamped to 7.0s.
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: String(repeating: "a", count: 200), offset: 20),
        ])

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        XCTAssertTrue(output.contains("00:00:13,000 --> 00:00:20,000"), "got:\n\(output)")
    }

    func testSessionExporter_SRT_SameLaneCues_NeverOverlap() {
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "First cue!", offset: 10.0),
            Line(lane: .system, text: "Second cue", offset: 10.2),
        ])

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        // The second cue may not start before the first one ends (10.0s).
        XCTAssertTrue(output.contains("00:00:09,000 --> 00:00:10,000"), "got:\n\(output)")
        XCTAssertTrue(output.contains("00:00:10,000 --> 00:00:10,200"), "got:\n\(output)")
    }

    func testSessionExporter_SRT_ZeroLengthCue_IsExtended() {
        // Finalized exactly at session start: start == end → end pushed +0.5s.
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "Instant", offset: 0),
        ])

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        XCTAssertTrue(output.contains("00:00:00,000 --> 00:00:00,500"), "got:\n\(output)")
    }

    func testSessionExporter_SRT_CrossLaneCues_SortedByStartBeforeNumbering() {
        // The mic cue starts earlier (long estimated duration) although it was
        // finalized second — it must be numbered first. Lanes may overlap.
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "Short", offset: 10),                       // [9, 10]
            Line(lane: .microphone, text: String(repeating: "b", count: 200), offset: 12), // [5, 12]
        ])

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        let expected = """
        1
        00:00:05,000 --> 00:00:12,000
        \(String(repeating: "b", count: 200))

        2
        00:00:09,000 --> 00:00:10,000
        Short

        """
        XCTAssertEqual(output, expected)
    }

    func testSessionExporter_SRT_EmptyTranscript_IsEmpty() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)

        let output = SessionExporter.export(transcript, format: .srt, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        XCTAssertEqual(output, "")
    }

    // MARK: - Session-start fallback

    func testSessionExporter_NoStartTime_OffsetsFallBackToFirstEntry() {
        // clear() mid-session erases startedAt; later captions still export
        // with sensible offsets measured from the first surviving entry.
        let transcript = makeTranscript(lines: [
            Line(lane: .system, text: "New base", offset: 100),
            Line(lane: .system, text: "Later", offset: 160),
        ], withStart: false)

        let output = SessionExporter.export(transcript, format: .plainText, sourceLanguages: "EN", targetLanguage: "ZH", timeZone: utc)

        XCTAssertTrue(output.contains("[00:00:00] [SYS] New base"), "got:\n\(output)")
        XCTAssertTrue(output.contains("[00:01:00] [SYS] Later"), "got:\n\(output)")
    }

    // MARK: - File name

    func testSessionExporter_SuggestedFileName_UsesSessionStartAndFormatExtension() {
        XCTAssertEqual(
            SessionExporter.suggestedFileName(for: .markdown, sessionStart: start, timeZone: utc),
            "LCT Session 2026-10-11 14.03.md"
        )
        XCTAssertEqual(
            SessionExporter.suggestedFileName(for: .plainText, sessionStart: start, timeZone: utc),
            "LCT Session 2026-10-11 14.03.txt"
        )
        XCTAssertEqual(
            SessionExporter.suggestedFileName(for: .srt, sessionStart: start, timeZone: utc),
            "LCT Session 2026-10-11 14.03.srt"
        )
    }
}
