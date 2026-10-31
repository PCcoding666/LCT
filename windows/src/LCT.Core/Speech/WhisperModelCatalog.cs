using LCT.Core.Translation;

namespace LCT.Core.Speech;

/// <summary>One downloadable whisper.cpp ggml model.</summary>
public sealed record WhisperModelInfo(string Name, string FileName, long DownloadBytes, string Summary)
{
    /// <summary>Whisper.net's Hugging Face mirror; the same files whisper.cpp publishes.</summary>
    public string DownloadUrl => $"https://huggingface.co/sandrohanea/whisper.net/resolve/v5/classic/{FileName}";

    public string FormattedDownloadSize => ByteFormat.Format(DownloadBytes);
}

/// <summary>The multilingual ggml models LCT offers, smallest first.</summary>
public static class WhisperModelCatalog
{
    public static readonly WhisperModelInfo Tiny = new("tiny", "ggml-tiny.bin", 77_700_000, "Fastest; rough on anything but clear English");
    public static readonly WhisperModelInfo Base = new("base", "ggml-base.bin", 148_000_000, "Fast; fine for clear speech on low-end PCs");
    public static readonly WhisperModelInfo Small = new("small", "ggml-small.bin", 488_000_000, "Best balance of speed and accuracy on CPU");
    public static readonly WhisperModelInfo Medium = new("medium", "ggml-medium.bin", 1_530_000_000, "Higher accuracy; needs a fast CPU to keep up");
    public static readonly WhisperModelInfo LargeV3Turbo = new("large-v3-turbo", "ggml-large-v3-turbo.bin", 1_620_000_000, "Highest accuracy; realistic only with a GPU build");

    public static readonly IReadOnlyList<WhisperModelInfo> All = new[] { Tiny, Base, Small, Medium, LargeV3Turbo };

    public static WhisperModelInfo? Entry(string name)
        => All.FirstOrDefault(m => string.Equals(m.Name, name, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Pick a speech model the machine can run in real time on the CPU:
    /// <c>small</c> by default, <c>base</c> below 8 GB of RAM or 4 cores.
    /// </summary>
    public static WhisperModelInfo Recommend(HardwareProfile hardware)
    {
        if (hardware.PhysicalMemoryBytes < 8L * 1024 * 1024 * 1024 || hardware.LogicalCores < 4)
        {
            return Base;
        }
        return Small;
    }
}
