namespace LCT.Core.Models;

/// <summary>
/// Origin of a captured audio stream. The pipeline runs two independent
/// channels; every frame, recognition event and segment carries its source so
/// the channels stay distinguishable end to end.
/// </summary>
public enum AudioSource
{
    /// <summary>What the PC plays (WASAPI loopback on the default render device).</summary>
    System,
    /// <summary>The selected input device (WASAPI capture).</summary>
    Microphone,
}

public static class AudioSourceExtensions
{
    /// <summary>Short badge shown next to transcript lines.</summary>
    public static string Label(this AudioSource source) => source switch
    {
        AudioSource.System => "SYS",
        AudioSource.Microphone => "MIC",
        _ => source.ToString().ToUpperInvariant(),
    };
}
