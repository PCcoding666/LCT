import XCTest
@testable import LCTMac

final class HardwareProfileTests: XCTestCase {

    func testCurrent_PopulatesChipAndMemory() {
        let profile = HardwareProfile.current()
        XCTAssertFalse(profile.chipName.isEmpty)
        XCTAssertGreaterThan(profile.physicalMemoryBytes, 0)
    }

    func testCurrent_IsAppleSiliconMatchesBuildArchitecture() {
        // The test runner does not run under Rosetta, so the runtime probe
        // must agree with the compile-time architecture.
        let profile = HardwareProfile.current()
        #if arch(arm64)
        XCTAssertTrue(profile.isAppleSilicon)
        #else
        XCTAssertFalse(profile.isAppleSilicon)
        #endif
    }

    func testMemoryGB_RoundsToWholeGigabytes() {
        let profile = HardwareProfile(isAppleSilicon: true, physicalMemoryBytes: 17_179_869_184, chipName: "Test Chip")
        XCTAssertEqual(profile.memoryGB, 16)

        let eightGB = HardwareProfile(isAppleSilicon: true, physicalMemoryBytes: 8_589_934_592, chipName: "Test Chip")
        XCTAssertEqual(eightGB.memoryGB, 8)
    }
}

final class ModelRecommenderTests: XCTestCase {

    private func appleSilicon(_ bytes: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: true, physicalMemoryBytes: bytes, chipName: "Apple M2 Pro")
    }

    private func intel(_ bytes: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: false, physicalMemoryBytes: bytes, chipName: "Intel Core i7")
    }

    private func giB(_ value: UInt64) -> UInt64 {
        value * 1_073_741_824
    }

    // MARK: - Recommendation matrix

    func testRecommend_AppleSilicon64GB_Recommends4bMLX() {
        let result = ModelRecommender.recommend(for: appleSilicon(giB(64)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:4b-mlx")
    }

    func testRecommend_AppleSilicon32GB_Recommends4bMLX() {
        let result = ModelRecommender.recommend(for: appleSilicon(giB(32)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:4b-mlx")
    }

    func testRecommend_AppleSilicon16GB_Recommends4bMLX() {
        let result = ModelRecommender.recommend(for: appleSilicon(giB(16)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:4b-mlx")
        XCTAssertTrue(result.reason.contains("16 GB"), "reason should mention the memory size")
    }

    func testRecommend_AppleSilicon8GB_Recommends2bMLX() {
        // 40% of 8 GB is ~3.44 GB: 4b-mlx (3.97 GB) is over, 2b-mlx (3.12 GB) fits.
        let result = ModelRecommender.recommend(for: appleSilicon(giB(8)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:2b-mlx")
    }

    func testRecommend_AppleSilicon4GB_Recommends08bMLX() {
        let result = ModelRecommender.recommend(for: appleSilicon(giB(4)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:0.8b-mlx")
    }

    func testRecommend_Intel16GB_RecommendsSmallestGGUF() {
        let result = ModelRecommender.recommend(for: intel(giB(16)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:0.8b")
        XCTAssertEqual(result.recommended.format, .gguf)
    }

    func testRecommend_Intel8GB_RecommendsSmallestGGUF() {
        let result = ModelRecommender.recommend(for: intel(giB(8)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:0.8b")
    }

    // MARK: - 40% rule boundary

    func testRecommend_ExactlyFortyPercentBudget_IsAccepted() {
        // Memory sized so 40% of it is exactly the 4b-mlx download (≤ is inclusive).
        let memory = UInt64(3_970_000_000.0 / 0.4)
        let result = ModelRecommender.recommend(for: appleSilicon(memory))
        XCTAssertEqual(result.recommended.name, "qwen3.5:4b-mlx")
    }

    func testRecommend_JustBelowFortyPercentBudget_PicksSmaller() {
        // 40% of this is 3.9696 GB — clearly below the 3.97 GB 4b-mlx download.
        let result = ModelRecommender.recommend(for: appleSilicon(9_924_000_000))
        XCTAssertEqual(result.recommended.name, "qwen3.5:2b-mlx")
        XCTAssertTrue(result.reason.contains("comfortably"), "a mid-list pick should explain the fit")
    }

    // MARK: - Fallback when nothing fits

    func testRecommend_NothingFitsAppleSilicon_FallsBackToSmallestMLX() {
        // 40% of 2 GB (~0.86 GB) fits no model; the smallest MLX build wins.
        let result = ModelRecommender.recommend(for: appleSilicon(giB(2)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:0.8b-mlx")
        XCTAssertTrue(result.reason.contains("Smallest"), "the fallback must be labelled as such")
    }

    func testRecommend_NothingFitsIntel_FallsBackToSmallestGGUF() {
        let result = ModelRecommender.recommend(for: intel(giB(2)))
        XCTAssertEqual(result.recommended.name, "qwen3.5:0.8b")
        XCTAssertTrue(result.reason.contains("Smallest"))
    }

    // MARK: - Alternatives

    func testAlternatives_AppleSilicon_ExcludeRecommendedAndStayCompatible() {
        let result = ModelRecommender.recommend(for: appleSilicon(giB(16)))
        XCTAssertFalse(result.alternatives.contains { $0.name == result.recommended.name })
        XCTAssertTrue(result.alternatives.allSatisfy {
            ModelCatalog.isCompatible(modelName: $0.name, with: appleSilicon(giB(16)))
        })
        XCTAssertTrue(result.alternatives.contains { $0.name == "translategemma:4b-it-q4_K_M" })
        XCTAssertTrue(result.alternatives.contains { $0.name == "qwen3.5:4b" })
    }

    func testAlternatives_Intel_ContainNoMLX() {
        let result = ModelRecommender.recommend(for: intel(giB(16)))
        XCTAssertFalse(result.alternatives.isEmpty)
        XCTAssertTrue(result.alternatives.allSatisfy { $0.format == .gguf })
        XCTAssertTrue(result.alternatives.contains { $0.name == "translategemma:4b-it-q4_K_M" })
    }

    func testAlternatives_EveryEntryHasASummary() {
        for profile in [appleSilicon(giB(8)), intel(giB(8))] {
            let result = ModelRecommender.recommend(for: profile)
            for entry in result.alternatives {
                XCTAssertFalse(entry.summary.isEmpty, "\(entry.name) needs a one-line summary")
            }
        }
    }

    // MARK: - Compatibility

    func testIsCompatible_MLXOnIntel_IsIncompatible() {
        XCTAssertFalse(ModelCatalog.isCompatible(modelName: "qwen3.5:4b-mlx", with: intel(giB(16))))
    }

    func testIsCompatible_MLXOnAppleSilicon_IsCompatible() {
        XCTAssertTrue(ModelCatalog.isCompatible(modelName: "qwen3.5:4b-mlx", with: appleSilicon(giB(16))))
    }

    func testIsCompatible_GGUF_IsCompatibleEverywhere() {
        XCTAssertTrue(ModelCatalog.isCompatible(modelName: "qwen3.5:4b", with: intel(giB(8))))
        XCTAssertTrue(ModelCatalog.isCompatible(modelName: "qwen3.5:4b", with: appleSilicon(giB(8))))
    }

    func testIsCompatible_UnknownMLXSuffixOnIntel_IsIncompatible() {
        // Hand-typed names are not in the catalog; the -mlx suffix decides.
        XCTAssertFalse(ModelCatalog.isCompatible(modelName: "custom:7b-mlx", with: intel(giB(16))))
    }

    func testIsCompatible_UnknownGGUFNameOnIntel_IsCompatible() {
        XCTAssertTrue(ModelCatalog.isCompatible(modelName: "llama3.2:3b", with: intel(giB(16))))
    }

    // MARK: - Catalog integrity

    func testCatalog_DownloadSizes_MatchRegistryManifests() {
        let expected: [String: Int64] = [
            "qwen3.5:4b-mlx": 3_970_000_000,
            "qwen3.5:2b-mlx": 3_120_000_000,
            "qwen3.5:0.8b-mlx": 1_240_000_000,
            "qwen3.5:4b": 3_320_000_000,
            "qwen3.5:2b": 2_680_000_000,
            "qwen3.5:0.8b": 1_320_000_000,
            "translategemma:4b-it-q4_K_M": 3_300_000_000,
        ]
        XCTAssertEqual(Set(ModelCatalog.all.map(\.name)), Set(expected.keys))
        for (name, bytes) in expected {
            XCTAssertEqual(ModelCatalog.entry(named: name)?.downloadBytes, bytes, name)
        }
    }

    func testCatalog_MLXEntries_RequireAppleSilicon() {
        for entry in ModelCatalog.all where entry.format == .mlx {
            XCTAssertTrue(entry.requiresAppleSilicon, entry.name)
        }
        for entry in ModelCatalog.all where entry.format == .gguf {
            XCTAssertFalse(entry.requiresAppleSilicon, entry.name)
        }
    }
}
