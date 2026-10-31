using LCT.Core.Models;

namespace LCT.Core.Session;

/// <summary>Pure formatting for the HUD language label and the empty-state listening line.</summary>
public static class LanguageLabel
{
    /// <summary>"ZH → EN" when both channels share a language; "SYS ZH · MIC EN → EN" when the mic differs.</summary>
    public static string Format(SourceLanguage system, SourceLanguage? microphone, TargetLanguage target, bool microphoneActive)
    {
        var sys = system.IsoCode().ToUpperInvariant();
        var mic = (microphone ?? system).IsoCode().ToUpperInvariant();
        var tgt = target.IsoCode().ToUpperInvariant();
        return microphoneActive && mic != sys ? $"SYS {sys} · MIC {mic} → {tgt}" : $"{sys} → {tgt}";
    }

    /// <summary>"// listening (ZH)…" or "// listening (SYS ZH · MIC EN)…".</summary>
    public static string Listening(SourceLanguage system, SourceLanguage? microphone, bool microphoneActive)
    {
        var sys = system.IsoCode().ToUpperInvariant();
        var mic = (microphone ?? system).IsoCode().ToUpperInvariant();
        return microphoneActive && mic != sys ? $"// listening (SYS {sys} · MIC {mic})…" : $"// listening ({sys})…";
    }

    /// <summary>"rec 01:23" / "rec 01:02:03".</summary>
    public static string Elapsed(TimeSpan elapsed)
    {
        var total = (int)Math.Max(0, elapsed.TotalSeconds);
        var h = total / 3600;
        var m = total % 3600 / 60;
        var s = total % 60;
        return h > 0 ? $"{h:00}:{m:00}:{s:00}" : $"{m:00}:{s:00}";
    }
}
