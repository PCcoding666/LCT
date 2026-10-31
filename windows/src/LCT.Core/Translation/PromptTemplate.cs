using LCT.Core.Models;

namespace LCT.Core.Translation;

public static class PromptTemplate
{
    public const string TargetPlaceholder = "{TARGET_LANGUAGE}";

    /// <summary>Default system prompt, identical to the macOS app.</summary>
    public static readonly string Default =
        "You are a professional simultaneous interpreter. Translate the text enclosed in 🔤 markers to {TARGET_LANGUAGE}.\n\n" +
        "CRITICAL RULES:\n" +
        "1. Output ONLY the translated text, never the original text\n" +
        "2. Handle incomplete sentences naturally and professionally\n" +
        "3. Preserve technical terms, company names, and proper nouns accurately\n" +
        "4. Maintain appropriate tone and formality\n" +
        "5. For unclear speech, provide the most likely interpretation\n\n" +
        "OUTPUT FORMAT: Single line translation only, remove all 🔤 markers, no explanations.";

    /// <summary>Custom prompt when set, else the default; the placeholder is replaced by the target's display name.</summary>
    public static string Render(string? customPrompt, TargetLanguage target)
    {
        var template = string.IsNullOrWhiteSpace(customPrompt) ? Default : customPrompt;
        return template.Replace(TargetPlaceholder, target.DisplayName());
    }
}
