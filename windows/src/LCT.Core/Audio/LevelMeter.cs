namespace LCT.Core.Audio;

/// <summary>RMS level helpers for the channel meters.</summary>
public static class LevelMeter
{
    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty)
        {
            return 0;
        }
        double sum = 0;
        foreach (var s in samples)
        {
            sum += (double)s * s;
        }
        return (float)Math.Sqrt(sum / samples.Length);
    }

    /// <summary>Map RMS to 0…1 over a -60…0 dBFS range (the macOS meters use the same scale).</summary>
    public static float Normalized(float rms)
    {
        if (rms <= 0)
        {
            return 0;
        }
        var db = 20 * Math.Log10(rms);
        return (float)Math.Clamp((db + 60) / 60, 0, 1);
    }

    /// <summary>Readout for the meter ("-∞" when effectively silent).</summary>
    public static string DbText(float normalized)
        => normalized <= 0.001f ? "-∞" : ((int)(normalized * 60 - 60)).ToString();
}
