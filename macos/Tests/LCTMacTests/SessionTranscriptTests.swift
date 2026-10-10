import XCTest
@testable import LCTMac

/// Tests for the SessionTranscript value type: begin/append/update/remove/clear
/// semantics that the capture pipeline relies on for session export.
final class SessionTranscriptTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testSessionTranscript_Begin_SetsStartAndDropsPreviousEntries() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        transcript.append(id: UUID(), source: .system, sourceText: "Old session", finalizedAt: start)

        let newStart = start.addingTimeInterval(3600)
        transcript.begin(at: newStart)

        XCTAssertEqual(transcript.startedAt, newStart)
        XCTAssertTrue(transcript.entries.isEmpty, "a new session must not carry over previous entries")
    }

    func testSessionTranscript_Append_PreservesFinalizationOrderAndLane() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        transcript.append(id: UUID(), source: .system, sourceText: "First", finalizedAt: start.addingTimeInterval(1))
        transcript.append(id: UUID(), source: .microphone, sourceText: "Second", finalizedAt: start.addingTimeInterval(2))

        XCTAssertEqual(transcript.entries.map(\.sourceText), ["First", "Second"])
        XCTAssertEqual(transcript.entries.map(\.source), [.system, .microphone])
        XCTAssertEqual(transcript.entries.map(\.translatedText), ["", ""], "translations start empty")
    }

    func testSessionTranscript_UpdateTranslation_WritesFinalText() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        let id = UUID()
        transcript.append(id: id, source: .system, sourceText: "你好", finalizedAt: start)

        transcript.updateTranslation(id: id, text: "Hello")

        XCTAssertEqual(transcript.entries.first?.translatedText, "Hello")
    }

    func testSessionTranscript_UpdateTranslation_UnknownId_IsIgnored() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        transcript.append(id: UUID(), source: .system, sourceText: "你好", finalizedAt: start)

        transcript.updateTranslation(id: UUID(), text: "Hello")

        XCTAssertEqual(transcript.entries.first?.translatedText, "", "a stale result must not touch other entries")
    }

    func testSessionTranscript_Remove_DropsOnlyMatchingIds() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        let keep = UUID()
        let revokedA = UUID()
        let revokedB = UUID()
        transcript.append(id: keep, source: .system, sourceText: "Keep", finalizedAt: start)
        transcript.append(id: revokedA, source: .system, sourceText: "Revoked A", finalizedAt: start)
        transcript.append(id: revokedB, source: .microphone, sourceText: "Revoked B", finalizedAt: start)

        transcript.remove(ids: [revokedA, revokedB])

        XCTAssertEqual(transcript.entries.map(\.id), [keep])
    }

    func testSessionTranscript_Remove_EmptyIdSet_KeepsEverything() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        transcript.append(id: UUID(), source: .system, sourceText: "Keep", finalizedAt: start)

        transcript.remove(ids: [])

        XCTAssertEqual(transcript.entries.count, 1)
    }

    func testSessionTranscript_Clear_ResetsStartAndEntries() {
        var transcript = SessionTranscript()
        transcript.begin(at: start)
        transcript.append(id: UUID(), source: .system, sourceText: "Line", finalizedAt: start)

        transcript.clear()

        XCTAssertNil(transcript.startedAt)
        XCTAssertTrue(transcript.entries.isEmpty)
    }
}
