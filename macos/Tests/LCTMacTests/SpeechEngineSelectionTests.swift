import XCTest
@testable import LCTMac

/// Guards the pure engine-selection rules: which engine runs, and how a dual
/// capture request degrades when the legacy single-task engine is selected.
final class SpeechEngineSelectionTests: XCTestCase {

    // MARK: - Engine kind

    func testEngineKind_TranscriberAvailable_SelectsAnalyzer() {
        XCTAssertEqual(SpeechEngineSelection.engineKind(transcriberEngineAvailable: true),
                       .speechTranscriber)
    }

    func testEngineKind_TranscriberUnavailable_SelectsSfSpeechRecognizer() {
        XCTAssertEqual(SpeechEngineSelection.engineKind(transcriberEngineAvailable: false),
                       .sfSpeechRecognizer)
    }

    // MARK: - Effective sources

    func testEffectiveSources_LegacyEngineDualRequest_KeepsSystemOnly() {
        let (sources, dropped) = SpeechEngineSelection.effectiveSources(
            [.microphone, .system], for: .sfSpeechRecognizer
        )
        XCTAssertEqual(sources, [.system],
                       "the legacy engine runs one task at a time; system audio is the primary lane")
        XCTAssertTrue(dropped, "the caller must be told the mic lane was dropped so it can warn")
    }

    func testEffectiveSources_LegacyEngineSingleSource_Unchanged() {
        let micOnly = SpeechEngineSelection.effectiveSources([.microphone], for: .sfSpeechRecognizer)
        XCTAssertEqual(micOnly.sources, [.microphone])
        XCTAssertFalse(micOnly.droppedMicrophone)

        let systemOnly = SpeechEngineSelection.effectiveSources([.system], for: .sfSpeechRecognizer)
        XCTAssertEqual(systemOnly.sources, [.system])
        XCTAssertFalse(systemOnly.droppedMicrophone)
    }

    func testEffectiveSources_TranscriberEngineDualRequest_Unchanged() {
        let (sources, dropped) = SpeechEngineSelection.effectiveSources(
            [.system, .microphone], for: .speechTranscriber
        )
        XCTAssertEqual(sources, [.system, .microphone],
                       "the SpeechAnalyzer engine runs one analyzer per lane — nothing is dropped")
        XCTAssertFalse(dropped)
    }

    // MARK: - --selftest-engine resolution

    func testSelfTestEngineResolve_AutoFlag_FollowsAvailability() throws {
        XCTAssertEqual(try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.auto, transcriberAvailable: true),
                       .speechTranscriber)
        XCTAssertEqual(try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.auto, transcriberAvailable: false),
                       .sfSpeechRecognizer)
    }

    func testSelfTestEngineResolve_SfFlag_AlwaysSelectsSf() throws {
        XCTAssertEqual(try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.sf, transcriberAvailable: true),
                       .sfSpeechRecognizer)
        XCTAssertEqual(try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.sf, transcriberAvailable: false),
                       .sfSpeechRecognizer)
    }

    func testSelfTestEngineResolve_AnalyzerFlagWhenAvailable_SelectsAnalyzer() throws {
        XCTAssertEqual(try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.analyzer, transcriberAvailable: true),
                       .speechTranscriber)
    }

    func testSelfTestEngineResolve_AnalyzerFlagWhenUnavailable_Throws() {
        XCTAssertThrowsError(
            try SelfTestEngineSelection.resolve(flag: SelfTestEngineFlag.analyzer, transcriberAvailable: false)
        ) { error in
            XCTAssertEqual(error as? SelfTestEngineError, .analyzerUnavailable,
                           "forcing the analyzer engine on an old OS must fail with a clear error")
        }
    }

    func testSelfTestEngineResolve_UnknownFlag_Throws() {
        XCTAssertThrowsError(
            try SelfTestEngineSelection.resolve(flag: "whisper", transcriberAvailable: true)
        ) { error in
            XCTAssertEqual(error as? SelfTestEngineError, .unknownEngine("whisper"))
        }
    }
}
