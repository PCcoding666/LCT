import XCTest
@testable import LCTMac

final class OnboardingModelSelectionTests: XCTestCase {

    private let hardware = HardwareProfile(
        isAppleSilicon: true,
        physicalMemoryBytes: 17_179_869_184,
        chipName: "Apple M2 Pro"
    )

    private var recommendation: ModelRecommendation {
        ModelRecommender.recommend(for: hardware)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "LCTMacSettings")
        super.tearDown()
    }

    // MARK: - Picking among installed models

    func testPreferredInstalledModel_RecommendedInstalled_ReturnsRecommended() {
        let installed: Set<String> = ["qwen3.5:4b-mlx", "qwen3.5:2b-mlx"]
        let choice = OnboardingModelSelection.preferredInstalledModel(recommendation: recommendation) {
            installed.contains($0)
        }
        XCTAssertEqual(choice, "qwen3.5:4b-mlx")
    }

    func testPreferredInstalledModel_OnlyAlternativeInstalled_ReturnsAlternative() {
        let installed: Set<String> = ["translategemma:4b-it-q4_K_M"]
        let choice = OnboardingModelSelection.preferredInstalledModel(recommendation: recommendation) {
            installed.contains($0)
        }
        XCTAssertEqual(choice, "translategemma:4b-it-q4_K_M")
    }

    func testPreferredInstalledModel_NoneInstalled_ReturnsNil() {
        let choice = OnboardingModelSelection.preferredInstalledModel(recommendation: recommendation) { _ in
            false
        }
        XCTAssertNil(choice)
    }

    func testPreferredInstalledModel_IncompatibleNameInstalled_IsIgnored() {
        // An Intel machine must never settle on an MLX build, installed or not.
        let intelHardware = HardwareProfile(isAppleSilicon: false, physicalMemoryBytes: 17_179_869_184, chipName: "Intel Core i7")
        let intelRecommendation = ModelRecommender.recommend(for: intelHardware)
        let installed: Set<String> = ["qwen3.5:4b-mlx", "qwen3.5:0.8b"]
        let choice = OnboardingModelSelection.preferredInstalledModel(recommendation: intelRecommendation) {
            installed.contains($0)
        }
        XCTAssertEqual(choice, "qwen3.5:0.8b")
    }

    // MARK: - Persisting the choice

    func testSaveChosenModel_PersistsModelName() {
        let saveError = OnboardingModelSelection.saveChosenModel("qwen3.5:2b-mlx")
        XCTAssertNil(saveError)
        XCTAssertEqual(AppSettings.load().ollamaModel, "qwen3.5:2b-mlx")
    }

    func testSaveChosenModel_LeavesOtherSettingsUntouched() {
        var settings = AppSettings()
        settings.targetLanguage = .japanese
        XCTAssertTrue(settings.save())

        XCTAssertNil(OnboardingModelSelection.saveChosenModel("qwen3.5:0.8b-mlx"))

        let reloaded = AppSettings.load()
        XCTAssertEqual(reloaded.ollamaModel, "qwen3.5:0.8b-mlx")
        XCTAssertEqual(reloaded.targetLanguage, .japanese)
    }
}
