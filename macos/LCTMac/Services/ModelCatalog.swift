import Foundation

/// Shared byte formatting for download sizes and progress ("3.97 GB").
enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// One downloadable translation model. `downloadBytes` is the exact pull size
/// from the Ollama registry manifest.
struct TranslationModelInfo: Equatable, Identifiable, Sendable {
    enum Format: String, Sendable {
        case mlx
        case gguf
    }

    let name: String
    let displayName: String
    /// One-line guidance shown next to the model in pickers.
    let summary: String
    let downloadBytes: Int64
    let format: Format

    var id: String { name }

    /// MLX builds only run on Apple Silicon.
    var requiresAppleSilicon: Bool { format == .mlx }

    var formattedDownloadSize: String {
        ByteFormatting.string(downloadBytes)
    }
}

/// The known translation models with their registry download sizes.
enum ModelCatalog {
    static let qwen35_4bMLX = TranslationModelInfo(
        name: "qwen3.5:4b-mlx",
        displayName: "Qwen3.5 4B MLX",
        summary: "Best speed and accuracy on Apple Silicon",
        downloadBytes: 3_970_000_000,
        format: .mlx
    )

    static let qwen35_2bMLX = TranslationModelInfo(
        name: "qwen3.5:2b-mlx",
        displayName: "Qwen3.5 2B MLX",
        summary: "Smaller MLX build for Macs with less memory",
        downloadBytes: 3_120_000_000,
        format: .mlx
    )

    static let qwen35_08bMLX = TranslationModelInfo(
        name: "qwen3.5:0.8b-mlx",
        displayName: "Qwen3.5 0.8B MLX",
        summary: "Tiny and fast; lower translation quality",
        downloadBytes: 1_240_000_000,
        format: .mlx
    )

    static let qwen35_4b = TranslationModelInfo(
        name: "qwen3.5:4b",
        displayName: "Qwen3.5 4B",
        summary: "Full-quality GGUF build that runs on any Mac",
        downloadBytes: 3_320_000_000,
        format: .gguf
    )

    static let qwen35_2b = TranslationModelInfo(
        name: "qwen3.5:2b",
        displayName: "Qwen3.5 2B",
        summary: "Balanced GGUF build that runs on any Mac",
        downloadBytes: 2_680_000_000,
        format: .gguf
    )

    static let qwen35_08b = TranslationModelInfo(
        name: "qwen3.5:0.8b",
        displayName: "Qwen3.5 0.8B",
        summary: "Fastest on Intel; weakest on proper nouns",
        downloadBytes: 1_320_000_000,
        format: .gguf
    )

    static let translateGemma4b = TranslationModelInfo(
        name: "translategemma:4b-it-q4_K_M",
        displayName: "TranslateGemma 4B",
        summary: "Google's specialized translation model (55 languages)",
        downloadBytes: 3_300_000_000,
        format: .gguf
    )

    static let all: [TranslationModelInfo] = [
        qwen35_4bMLX,
        qwen35_2bMLX,
        qwen35_08bMLX,
        qwen35_4b,
        qwen35_2b,
        qwen35_08b,
        translateGemma4b,
    ]

    static func entry(named name: String) -> TranslationModelInfo? {
        all.first { $0.name == name }
    }

    /// A model is MLX when the catalog says so, or — for names typed by hand —
    /// when it carries the `-mlx` suffix.
    static func isMLXModel(_ name: String) -> Bool {
        if let entry = entry(named: name) {
            return entry.format == .mlx
        }
        return name.lowercased().hasSuffix("-mlx")
    }

    static func isCompatible(modelName: String, with hardware: HardwareProfile) -> Bool {
        !isMLXModel(modelName) || hardware.isAppleSilicon
    }
}

/// The recommender's pick plus the other models this Mac can run.
struct ModelRecommendation: Equatable {
    let recommended: TranslationModelInfo
    let alternatives: [TranslationModelInfo]
    /// One sentence explaining the pick ("Best speed and accuracy on …").
    let reason: String
}

/// Picks a translation model for a Mac. Pure and offline: the first model in
/// the architecture's preference order whose download fits in 40% of physical
/// memory wins; when nothing fits, the smallest compatible model is the
/// fallback. Apple Silicon prefers MLX builds (fastest); Intel prefers small
/// GGUF builds (CPU-only inference, where small means low latency).
enum ModelRecommender {
    /// Fraction of physical memory a model download may take at most.
    static let memoryBudgetFraction: Double = 0.4

    private static let appleSiliconPreferenceNames = [
        "qwen3.5:4b-mlx",
        "qwen3.5:2b-mlx",
        "qwen3.5:0.8b-mlx",
    ]

    private static let intelPreferenceNames = [
        "qwen3.5:0.8b",
        "qwen3.5:2b",
    ]

    static func recommend(for hardware: HardwareProfile) -> ModelRecommendation {
        let preferenceNames = hardware.isAppleSilicon ? appleSiliconPreferenceNames : intelPreferenceNames
        let preferences = preferenceNames.compactMap { ModelCatalog.entry(named: $0) }
        let budget = Double(hardware.physicalMemoryBytes) * memoryBudgetFraction

        let fitting = preferences.first { Double($0.downloadBytes) <= budget }
        // The preference lists are static and non-empty, so a smallest entry
        // always exists for the fallback.
        let recommended = fitting ?? preferences.min(by: { $0.downloadBytes < $1.downloadBytes })!

        let reason: String
        if fitting == nil {
            reason = "Smallest compatible model — \(hardware.memoryGB) GB of memory is tight for local translation"
        } else if recommended.name == preferences.first?.name {
            reason = hardware.isAppleSilicon
                ? "Best speed and accuracy on \(hardware.chipName) with \(hardware.memoryGB) GB"
                : "Fastest option on Intel — small models have the lowest latency on CPU"
        } else {
            reason = "Largest model that runs comfortably in \(hardware.memoryGB) GB of memory"
        }

        var alternatives = preferences.filter { $0.name != recommended.name }
        alternatives.append(contentsOf: ModelCatalog.all.filter { entry in
            entry.name != recommended.name
                && !preferenceNames.contains(entry.name)
                && ModelCatalog.isCompatible(modelName: entry.name, with: hardware)
        })

        return ModelRecommendation(recommended: recommended, alternatives: alternatives, reason: reason)
    }
}
