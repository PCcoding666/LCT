import XCTest
import AVFoundation
@testable import LCTMac

/// Guards the speech self-test diagnostics mode: argument parsing, the JSON
/// report shape, and the audio chunking helpers that feed the real
/// recognition lane.
final class SpeechSelfTestTests: XCTestCase {

    // MARK: - Argument parsing

    func testParse_NoSelfTestFlag_ReturnsNil() {
        XCTAssertNil(SpeechSelfTestOptions.parse(arguments: ["/usr/bin/LCTMac"]))
    }

    func testParse_FlagWithoutAudioPath_ReturnsNil() {
        XCTAssertNil(SpeechSelfTestOptions.parse(arguments: ["/usr/bin/LCTMac", "--speech-selftest"]))
    }

    func testParse_AnotherFlagInPathSlot_ReturnsNil() {
        XCTAssertNil(SpeechSelfTestOptions.parse(arguments: ["/usr/bin/LCTMac", "--speech-selftest", "--selftest-locale", "en-US"]),
                     "a flag in the audio-path slot means the path is missing")
    }

    func testParse_FullArguments_ReturnsAllValues() {
        let options = SpeechSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac",
            "--speech-selftest", "/tmp/sample.wav",
            "--selftest-locale", "en-GB",
            "--selftest-output", "/tmp/report.json",
        ])
        XCTAssertEqual(options, SpeechSelfTestOptions(
            audioPath: "/tmp/sample.wav",
            localeIdentifier: "en-GB",
            outputPath: "/tmp/report.json"
        ))
    }

    func testParse_MissingOptionalArguments_UsesDefaults() {
        let options = SpeechSelfTestOptions.parse(arguments: ["/usr/bin/LCTMac", "--speech-selftest", "/tmp/sample.wav"])
        XCTAssertEqual(options?.localeIdentifier, "en-US")
        XCTAssertEqual(options?.outputPath, "/tmp/sample.wav.selftest.json")
    }

    // MARK: - JSON report

    func testReportEncoding_SuccessCase_ContainsAllRequiredKeys() throws {
        let report = SpeechSelfTestReport(
            locale: "en-US",
            finalTexts: ["hello world"],
            partialCount: 3,
            error1110Count: 1,
            restartCount: 2,
            staleCallbacksDropped: 4,
            durationSeconds: 5.5
        )
        let json = String(data: try report.encoded(), encoding: .utf8) ?? ""
        for key in ["\"locale\"", "\"finalTexts\"", "\"partialCount\"", "\"error1110Count\"",
                    "\"restartCount\"", "\"staleCallbacksDropped\"", "\"durationSeconds\""] {
            XCTAssertTrue(json.contains(key), "report is missing key \(key)")
        }
        XCTAssertTrue(json.contains("\"hello world\""), "final texts must be included in the diagnostic file")
    }

    func testReportEncoding_ErrorCase_ContainsErrorField() throws {
        var report = SpeechSelfTestReport(locale: "en-US")
        report.error = "Speech recognition not authorized (status 2)"
        let json = String(data: try report.encoded(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"error\""), "failure runs must still write an error field")
    }

    // MARK: - Audio helpers

    func testAudioChunking_OneSecondBuffer_ProducesFiftyFullChunks() {
        let buffer = AVAudioPCMBuffer(pcmFormat: SelfTestAudio.makeTargetFormat(), frameCapacity: 16_000)!
        buffer.frameLength = 16_000

        let chunks = SelfTestAudio.chunk(buffer)

        XCTAssertEqual(chunks.count, 50)
        XCTAssertTrue(chunks.allSatisfy { $0.frameLength == SelfTestAudio.framesPerChunk })
    }

    func testAudioChunking_PartialTail_KeepsRemainderFrames() {
        let buffer = AVAudioPCMBuffer(pcmFormat: SelfTestAudio.makeTargetFormat(), frameCapacity: 1_000)!
        buffer.frameLength = 1_000

        let chunks = SelfTestAudio.chunk(buffer)

        XCTAssertEqual(chunks.count, 4) // 320 + 320 + 320 + 40
        XCTAssertEqual(chunks.last?.frameLength, 40)
    }

    func testSilenceChunk_Format_Is20msOfZeros() {
        guard let chunk = SelfTestAudio.makeSilenceChunk() else {
            XCTFail("could not allocate silence chunk")
            return
        }
        XCTAssertEqual(chunk.frameLength, SelfTestAudio.framesPerChunk)
        XCTAssertEqual(chunk.format.sampleRate, SelfTestAudio.sampleRate)
        XCTAssertEqual(chunk.format.channelCount, 1)
        if let data = chunk.floatChannelData {
            for frame in 0 ..< Int(chunk.frameLength) {
                XCTAssertEqual(data[0][frame], 0, "silence chunk must be all zeros")
            }
        } else {
            XCTFail("silence chunk has no channel data")
        }
    }

    func testSilencePadding_TwoSeconds_IsHundredChunks() {
        XCTAssertEqual(SelfTestAudio.silenceChunkCount, 100,
                       "2s of padding at 20ms per chunk must be exactly 100 chunks")
    }
}
