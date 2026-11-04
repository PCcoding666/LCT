import XCTest
import AVFoundation
@testable import LCTMac

/// Pause is a capture control: no captions are recorded while it is active.
@MainActor
final class PauseResumeTests: XCTestCase {
    func testPendingStateCodableRoundTrip() throws {
        // Old persisted histories containing pending must remain readable.
        let segment = TranslationSegment(sourceText: "Hello", state: .pending)
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranslationSegment.self, from: data)
        XCTAssertEqual(decoded.state, .pending)
        XCTAssertEqual(decoded.sourceText, "Hello")
    }

    func testPause_FinalAndPartialSpeech_DoNotChangeCaptions() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Before pause.")
        let transcript = harness.viewModel.sessionTranscript
        let segments = harness.viewModel.segments

        harness.viewModel.togglePause()
        XCTAssertTrue(harness.viewModel.isPaused)
        harness.speech.emit("Must not appear.")
        harness.speech.emit("Neither should this draft", isVolatile: true)

        XCTAssertEqual(harness.viewModel.sessionTranscript, transcript)
        XCTAssertEqual(harness.viewModel.segments, segments)
        XCTAssertFalse(harness.viewModel.liveSourceText.contains("Neither"))
        await harness.viewModel.stop()
    }

    func testResume_NewSpeech_ContinuesSameSession() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("First line.")
        let startedAt = harness.viewModel.sessionTranscript.startedAt
        let firstID = harness.viewModel.sessionTranscript.entries.first?.id

        harness.viewModel.togglePause()
        harness.speech.emit("Ignored while paused.")
        harness.viewModel.togglePause()
        harness.speech.emit("Next line.")

        XCTAssertFalse(harness.viewModel.isPaused)
        XCTAssertEqual(harness.viewModel.captureState, .capturing)
        XCTAssertEqual(harness.viewModel.sessionTranscript.startedAt, startedAt)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.first?.id, firstID)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["First line.", "Next line."])
        XCTAssertTrue(harness.translator.texts.isEmpty)
        await harness.viewModel.stop()
    }

    func testStop_WhilePaused_PreservesExistingSourceExport() async {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        harness.speech.emit("Keep this line.")
        harness.viewModel.togglePause()
        let transcript = harness.viewModel.sessionTranscript

        await harness.viewModel.stop()

        XCTAssertEqual(harness.viewModel.captureState, .idle)
        XCTAssertEqual(harness.viewModel.sessionTranscript, transcript)
        XCTAssertEqual(harness.viewModel.sessionTranscript.entries.map(\.sourceText), ["Keep this line."])
    }

    func testPause_AudioBuffers_AreDroppedUntilResume() async throws {
        let harness = CaptionOnlyTestHarness()
        await harness.viewModel.start()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        harness.capture.onAudioBuffer?(buffer, .system)
        XCTAssertEqual(harness.speech.buffers.value, 1)

        harness.viewModel.togglePause()
        harness.capture.onAudioBuffer?(buffer, .system)
        XCTAssertEqual(harness.speech.buffers.value, 1, "paused audio must never enter recognition")

        harness.viewModel.togglePause()
        harness.capture.onAudioBuffer?(buffer, .system)
        XCTAssertEqual(harness.speech.buffers.value, 2)
        await harness.viewModel.stop()
    }
}
