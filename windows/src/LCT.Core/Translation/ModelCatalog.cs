namespace LCT.Core.Translation;

/// <summary>One downloadable translation model. DownloadBytes is the pull size from the Ollama registry.</summary>
public sealed record TranslationModelInfo(string Name, string DisplayName, string Summary, long DownloadBytes)
{
    public string FormattedDownloadSize => ByteFormat.Format(DownloadBytes);
}

/// <summary>Known translation models. Windows has no MLX, so these are all GGUF builds.</summary>
public static class ModelCatalog
{
    public static readonly TranslationModelInfo Qwen35_4b = new("qwen3.5:4b", "Qwen3.5 4B", "Best accuracy; comfortable with 16 GB RAM or a GPU", 3_320_000_000);
    public static readonly TranslationModelInfo Qwen35_2b = new("qwen3.5:2b", "Qwen3.5 2B", "Balanced build for 8–16 GB PCs", 2_680_000_000);
    public static readonly TranslationModelInfo Qwen35_08b = new("qwen3.5:0.8b", "Qwen3.5 0.8B", "Fastest on CPU; weakest on proper nouns", 1_320_000_000);
    public static readonly TranslationModelInfo TranslateGemma4b = new("translategemma:4b-it-q4_K_M", "TranslateGemma 4B", "Google's specialized translation model (55 languages)", 3_300_000_000);

    public static readonly IReadOnlyList<TranslationModelInfo> All = new[] { Qwen35_4b, Qwen35_2b, Qwen35_08b, TranslateGemma4b };

    public static TranslationModelInfo? Entry(string name) => All.FirstOrDefault(m => m.Name == name);

    public static bool IsTranslateGemma(string modelName) => modelName.Contains("translategemma", StringComparison.OrdinalIgnoreCase);
}

/// <summary>The recommender's pick plus the other models this PC can run.</summary>
public sealed record ModelRecommendation(TranslationModelInfo Recommended, IReadOnlyList<TranslationModelInfo> Alternatives, string Reason);

/// <summary>
/// Picks a translation model for a PC. Pure and offline. The first model in
/// preference order whose download fits in 35% of physical memory wins; a
/// capable discrete GPU prefers the 4B model outright; when nothing fits, the
/// smallest model is the fallback.
/// </summary>
public static class ModelRecommender
{
    public const double MemoryBudgetFraction = 0.35;

    private static readonly string[] PreferenceNames = { "qwen3.5:4b", "qwen3.5:2b", "qwen3.5:0.8b" };

    public static ModelRecommendation Recommend(HardwareProfile hardware)
    {
        var preferences = PreferenceNames.Select(ModelCatalog.Entry).Where(m => m != null).Cast<TranslationModelInfo>().ToList();
        var budget = hardware.PhysicalMemoryBytes * MemoryBudgetFraction;

        TranslationModelInfo? fitting = hardware.HasCapableGpu
            ? preferences[0]
            : preferences.FirstOrDefault(m => m.DownloadBytes <= budget);
        var recommended = fitting ?? preferences.MinBy(m => m.DownloadBytes)!;

        string reason;
        if (fitting == null)
        {
            reason = $"Smallest model — {hardware.MemoryGB} GB of memory is tight for local translation";
        }
        else if (hardware.HasCapableGpu)
        {
            reason = $"Best accuracy; {hardware.GpuName} ({hardware.VideoMemoryGB} GB) runs it fast";
        }
        else if (recommended.Name == preferences[0].Name)
        {
            reason = $"Best accuracy that fits in {hardware.MemoryGB} GB of memory";
        }
        else
        {
            reason = $"Largest model that runs comfortably in {hardware.MemoryGB} GB of memory";
        }

        var alternatives = preferences.Where(m => m.Name != recommended.Name).ToList();
        alternatives.AddRange(ModelCatalog.All.Where(m => m.Name != recommended.Name && !PreferenceNames.Contains(m.Name)));
        return new ModelRecommendation(recommended, alternatives, reason);
    }
}
