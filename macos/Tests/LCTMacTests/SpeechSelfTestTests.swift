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

    // MARK: - --selftest-engine on the single self-test

    func testParse_EngineFlag_DefaultsToAuto() {
        let options = SpeechSelfTestOptions.parse(arguments: ["/usr/bin/LCTMac", "--speech-selftest", "/tmp/a.wav"])
        XCTAssertEqual(options?.engine, SelfTestEngineFlag.auto)
    }

    func testParse_EngineFlag_ReturnsRequestedEngine() {
        let options = SpeechSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--speech-selftest", "/tmp/a.wav", "--selftest-engine", "sf",
        ])
        XCTAssertEqual(options?.engine, "sf")
    }

    // MARK: - Dual self-test argument parsing

    func testDualParse_NoDualFlag_ReturnsNil() {
        XCTAssertNil(SpeechDualSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--selftest-a", "/tmp/a.wav", "--selftest-b", "/tmp/b.wav",
        ]))
    }

    func testDualParse_MissingPathB_ReturnsNil() {
        XCTAssertNil(SpeechDualSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--speech-selftest-dual", "--selftest-a", "/tmp/a.wav",
        ]))
    }

    func testDualParse_FlagInPathSlot_ReturnsNil() {
        XCTAssertNil(SpeechDualSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--speech-selftest-dual",
            "--selftest-a", "--selftest-b", "/tmp/b.wav",
        ]), "a flag in the path slot means the path is missing")
    }

    func testDualParse_FullArguments_ReturnsAllValues() {
        let options = SpeechDualSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--speech-selftest-dual",
            "--selftest-a", "/tmp/a.wav",
            "--selftest-b", "/tmp/b.wav",
            "--selftest-locale", "en-US",
            "--selftest-locale-b", "zh-CN",
            "--selftest-engine", "analyzer",
            "--selftest-output", "/tmp/dual.json",
        ])
        XCTAssertEqual(options, SpeechDualSelfTestOptions(
            pathA: "/tmp/a.wav",
            pathB: "/tmp/b.wav",
            localeIdentifierA: "en-US",
            localeIdentifierB: "zh-CN",
            engine: "analyzer",
            outputPath: "/tmp/dual.json"
        ))
    }

    func testDualParse_MissingOptionals_UsesDefaults() {
        let options = SpeechDualSelfTestOptions.parse(arguments: [
            "/usr/bin/LCTMac", "--speech-selftest-dual",
            "--selftest-a", "/tmp/a.wav", "--selftest-b", "/tmp/b.wav",
        ])
        XCTAssertEqual(options?.localeIdentifierA, "en-US")
        XCTAssertEqual(options?.localeIdentifierB, "en-US",
                       "lane B's locale defaults to lane A's")
        XCTAssertEqual(options?.engine, SelfTestEngineFlag.auto)
        XCTAssertEqual(options?.outputPath, "/tmp/a.wav.dual-selftest.json")
    }

    // MARK: - Dual feed schedule

    func testDualSchedule_LaneBStartsAfterLaneA() {
        XCTAssertEqual(DualSelfTestSchedule.defaultOffsetSecondsB, 1.5,
                       "lane B must start 1.5s late so the lanes' tasks interleave")

        // 1s clips (50 chunks), 2s lead silence (100 chunks), 1.5s offset (75 chunks)
        let schedule = DualSelfTestSchedule.make(
            aChunkCount: 50, bChunkCount: 50, leadSilenceChunks: 100, offsetChunksB: 75
        )
        XCTAssertEqual(schedule.leadChunksA, 100)
        XCTAssertEqual(schedule.leadChunksB, 175)
        XCTAssertEqual(schedule.totalChunks, 325)

        let trailingA = schedule.totalChunks - schedule.leadChunksA - 50
        let trailingB = schedule.totalChunks - schedule.leadChunksB - 50
        XCTAssertGreaterThanOrEqual(trailingA, 100, "lane A must end with at least 2s of silence")
        XCTAssertGreaterThanOrEqual(trailingB, 100, "lane B must end with at least 2s of silence")
    }

    func testDualSchedule_LongerClipA_PadsLaneBToSameTotal() {
        let schedule = DualSelfTestSchedule.make(
            aChunkCount: 500, bChunkCount: 50, leadSilenceChunks: 100, offsetChunksB: 75
        )
        XCTAssertEqual(schedule.totalChunks, 700)

        let laneALength = schedule.leadChunksA + 500
        let laneBLength = schedule.leadChunksB + 50
        XCTAssertLessThanOrEqual(laneALength, schedule.totalChunks)
        XCTAssertLessThanOrEqual(laneBLength, schedule.totalChunks)
        XCTAssertEqual(schedule.totalChunks - laneALength, 100,
                       "the longer lane keeps exactly its trailing silence")
    }

    // MARK: - Stats merge

    func testStatsMerge_FieldWiseMaxWins() {
        var before: [AudioSource: LaneStats] = [.system: LaneStats(resultCount: 5, error1110Count: 1)]
        let after: [AudioSource: LaneStats] = [.system: LaneStats(resultCount: 3, finalCount: 2, restartCount: 1)]

        let merged = SelfTestStatsMerge.merge(before, after)

        XCTAssertEqual(merged[.system]?.resultCount, 5, "the larger count must survive")
        XCTAssertEqual(merged[.system]?.finalCount, 2)
        XCTAssertEqual(merged[.system]?.error1110Count, 1)
        XCTAssertEqual(merged[.system]?.restartCount, 1)

        before[.microphone] = LaneStats(resultCount: 7)
        let withMic = SelfTestStatsMerge.merge(before, after)
        XCTAssertEqual(withMic[.microphone]?.resultCount, 7,
                       "lanes present in only one snapshot must be kept")
    }

    // MARK: - Dual report

    func testDualReportEncoding_ContainsEngineAndPerLaneKeys() throws {
        var report = SpeechDualSelfTestReport(engine: "analyzer", localeA: "en-US", localeB: "zh-CN")
        report.laneA.segmentTexts = ["hello"]
        report.laneB.finalTexts = ["你好"]
        report.runtimeErrors = ["boom"]

        let json = String(data: try report.encoded(), encoding: .utf8) ?? ""
        for key in ["\"engine\"", "\"localeA\"", "\"localeB\"", "\"laneA\"", "\"laneB\"",
                    "\"segmentTexts\"", "\"finalTexts\"", "\"resultCount\"", "\"error1110Count\"",
                    "\"runtimeErrors\"", "\"elapsedSeconds\""] {
            XCTAssertTrue(json.contains(key), "dual report is missing key \(key)")
        }
        XCTAssertTrue(json.contains("\"analyzer\""))
    }
}
