namespace LCT.Core.Session;

/// <summary>Text helpers for caption processing (ported from the macOS TextUtils).</summary>
public static class TextUtils
{
    public static readonly HashSet<char> EndOfSentencePunctuation = new()
    {
        '.', '!', '?', '。', '！', '？', '．', '｡', '…', '‥',
    };

    public static bool IsCjk(char c)
    {
        int v = c;
        return (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x3040 && v <= 0x309F) || (v >= 0x30A0 && v <= 0x30FF)
            || (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0x1100 && v <= 0x11FF)
            || char.IsHighSurrogate(c); // CJK extension B lives in the astral plane
    }

    public static bool ContainsCjk(string text) => text.Any(IsCjk);

    public static bool IsPrimarilyCjk(string text)
    {
        var total = text.Count(c => !char.IsWhiteSpace(c));
        if (total == 0)
        {
            return false;
        }
        return (double)text.Count(IsCjk) / total > 0.5;
    }

    /// <summary>Whether the text contains anything worth captioning — at least one letter or digit.</summary>
    public static bool HasSpeechContent(string text) => text.Any(char.IsLetterOrDigit);

    public static bool HasEndPunctuation(string text) => text.Length > 0 && EndOfSentencePunctuation.Contains(text[^1]);

    public static string EnsureEndPunctuation(string text)
    {
        if (text.Length == 0 || HasEndPunctuation(text))
        {
            return text;
        }
        return text + (IsCjk(text[^1]) ? "。" : ".");
    }

    public static string SeparatorFor(string text) => IsPrimarilyCjk(text) ? "。" : ". ";

    /// <summary>Remove marker emoji and the prefixes some models add.</summary>
    public static string CleanTranslationOutput(string text)
    {
        var result = text.Replace("\U0001F524", "");
        foreach (var prefix in new[] { "Translation:", "翻译：", "译文：", "Here is the translation:", "The translation is:" })
        {
            if (result.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                result = result[prefix.Length..];
            }
        }
        return result.Trim();
    }

    public static string ConcatenateSentences(IEnumerable<string> sentences)
    {
        var result = "";
        foreach (var current in sentences)
        {
            if (string.IsNullOrEmpty(current))
            {
                continue;
            }
            if (result.Length > 0)
            {
                if (!HasEndPunctuation(result))
                {
                    result += SeparatorFor(result);
                }
                else if (!IsCjk(LastLetter(result)))
                {
                    result += " ";
                }
            }
            result += current;
        }
        return result;
    }

    private static char LastLetter(string text)
    {
        for (var i = text.Length - 1; i >= 0; i--)
        {
            if (char.IsLetterOrDigit(text[i]))
            {
                return text[i];
            }
        }
        return text.Length > 0 ? text[^1] : ' ';
    }

    /// <summary>Whisper emits bracketed non-speech markers like [BLANK_AUDIO] or (music); drop them.</summary>
    public static string StripNonSpeechMarkers(string text)
    {
        var result = System.Text.RegularExpressions.Regex.Replace(text, @"\[[^\]]*\]|\([^)]*\)|♪+", " ");
        return System.Text.RegularExpressions.Regex.Replace(result, @"\s+", " ").Trim();
    }
}
