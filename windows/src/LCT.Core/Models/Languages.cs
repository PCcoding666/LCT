using System.Text.Json.Serialization;

namespace LCT.Core.Models;

/// <summary>Recognition languages. Values are stored as BCP-47 tags in settings.</summary>
[JsonConverter(typeof(SourceLanguageJsonConverter))]
public enum SourceLanguage
{
    English,
    EnglishUK,
    Chinese,
    ChineseTW,
    Japanese,
    Korean,
    Spanish,
    French,
    German,
    Russian,
    Portuguese,
    Italian,
    Arabic,
    Hindi,
}

/// <summary>Translation targets. Stored by display name, like the macOS app.</summary>
[JsonConverter(typeof(TargetLanguageJsonConverter))]
public enum TargetLanguage
{
    Chinese,
    English,
    Japanese,
    Korean,
    Spanish,
    French,
    German,
    Russian,
    Arabic,
    Portuguese,
}

public enum TranslationModelType
{
    Standard,
    TranslateGemma,
}

/// <summary>
/// How long Ollama keeps the translation model in memory after the last
/// request. Ollama's keep_alive is an idle timeout reset by every request.
/// </summary>
public enum ModelKeepAlive
{
    Minutes5,
    Minutes15,
    Minutes30,
    Hour1,
    UntilQuit,
}

public static class LanguageInfo
{
    public static readonly IReadOnlyList<SourceLanguage> AllSources = Enum.GetValues<SourceLanguage>();
    public static readonly IReadOnlyList<TargetLanguage> AllTargets = Enum.GetValues<TargetLanguage>();
    public static readonly IReadOnlyList<ModelKeepAlive> AllKeepAlive = Enum.GetValues<ModelKeepAlive>();

    /// <summary>BCP-47 tag, also the persisted settings value.</summary>
    public static string Tag(this SourceLanguage language) => language switch
    {
        SourceLanguage.English => "en-US",
        SourceLanguage.EnglishUK => "en-GB",
        SourceLanguage.Chinese => "zh-CN",
        SourceLanguage.ChineseTW => "zh-TW",
        SourceLanguage.Japanese => "ja-JP",
        SourceLanguage.Korean => "ko-KR",
        SourceLanguage.Spanish => "es-ES",
        SourceLanguage.French => "fr-FR",
        SourceLanguage.German => "de-DE",
        SourceLanguage.Russian => "ru-RU",
        SourceLanguage.Portuguese => "pt-BR",
        SourceLanguage.Italian => "it-IT",
        SourceLanguage.Arabic => "ar-SA",
        SourceLanguage.Hindi => "hi-IN",
        _ => "en-US",
    };

    public static string DisplayName(this SourceLanguage language) => language switch
    {
        SourceLanguage.English => "English (US)",
        SourceLanguage.EnglishUK => "English (UK)",
        SourceLanguage.Chinese => "Chinese (Simplified)",
        SourceLanguage.ChineseTW => "Chinese (Traditional)",
        SourceLanguage.Japanese => "Japanese",
        SourceLanguage.Korean => "Korean",
        SourceLanguage.Spanish => "Spanish",
        SourceLanguage.French => "French",
        SourceLanguage.German => "German",
        SourceLanguage.Russian => "Russian",
        SourceLanguage.Portuguese => "Portuguese (Brazil)",
        SourceLanguage.Italian => "Italian",
        SourceLanguage.Arabic => "Arabic",
        SourceLanguage.Hindi => "Hindi",
        _ => language.ToString(),
    };

    /// <summary>ISO 639-1 code; also what whisper.cpp expects as the language hint.</summary>
    public static string IsoCode(this SourceLanguage language) => language switch
    {
        SourceLanguage.English or SourceLanguage.EnglishUK => "en",
        SourceLanguage.Chinese or SourceLanguage.ChineseTW => "zh",
        SourceLanguage.Japanese => "ja",
        SourceLanguage.Korean => "ko",
        SourceLanguage.Spanish => "es",
        SourceLanguage.French => "fr",
        SourceLanguage.German => "de",
        SourceLanguage.Russian => "ru",
        SourceLanguage.Portuguese => "pt",
        SourceLanguage.Italian => "it",
        SourceLanguage.Arabic => "ar",
        SourceLanguage.Hindi => "hi",
        _ => "en",
    };

    public static bool TryParseSource(string? value, out SourceLanguage language)
    {
        foreach (var candidate in AllSources)
        {
            if (string.Equals(candidate.Tag(), value, StringComparison.OrdinalIgnoreCase)
                || string.Equals(candidate.ToString(), value, StringComparison.OrdinalIgnoreCase))
            {
                language = candidate;
                return true;
            }
        }
        language = SourceLanguage.English;
        return false;
    }

    public static string DisplayName(this TargetLanguage language) => language.ToString();

    public static string NativeName(this TargetLanguage language) => language switch
    {
        TargetLanguage.Chinese => "中文",
        TargetLanguage.English => "English",
        TargetLanguage.Japanese => "日本語",
        TargetLanguage.Korean => "한국어",
        TargetLanguage.Spanish => "Español",
        TargetLanguage.French => "Français",
        TargetLanguage.German => "Deutsch",
        TargetLanguage.Russian => "Русский",
        TargetLanguage.Arabic => "العربية",
        TargetLanguage.Portuguese => "Português",
        _ => language.ToString(),
    };

    public static string IsoCode(this TargetLanguage language) => language switch
    {
        TargetLanguage.Chinese => "zh",
        TargetLanguage.English => "en",
        TargetLanguage.Japanese => "ja",
        TargetLanguage.Korean => "ko",
        TargetLanguage.Spanish => "es",
        TargetLanguage.French => "fr",
        TargetLanguage.German => "de",
        TargetLanguage.Russian => "ru",
        TargetLanguage.Arabic => "ar",
        TargetLanguage.Portuguese => "pt",
        _ => "en",
    };

    public static bool TryParseTarget(string? value, out TargetLanguage language)
    {
        foreach (var candidate in AllTargets)
        {
            if (string.Equals(candidate.ToString(), value, StringComparison.OrdinalIgnoreCase))
            {
                language = candidate;
                return true;
            }
        }
        language = TargetLanguage.Chinese;
        return false;
    }

    public static string DisplayName(this ModelKeepAlive keepAlive) => keepAlive switch
    {
        ModelKeepAlive.Minutes5 => "5 minutes",
        ModelKeepAlive.Minutes15 => "15 minutes",
        ModelKeepAlive.Minutes30 => "30 minutes",
        ModelKeepAlive.Hour1 => "1 hour",
        ModelKeepAlive.UntilQuit => "Until LCT quits",
        _ => keepAlive.ToString(),
    };

    /// <summary>Value sent as keep_alive. A negative duration keeps the model loaded indefinitely.</summary>
    public static string OllamaValue(this ModelKeepAlive keepAlive) => keepAlive switch
    {
        ModelKeepAlive.Minutes5 => "5m",
        ModelKeepAlive.Minutes15 => "15m",
        ModelKeepAlive.Minutes30 => "30m",
        ModelKeepAlive.Hour1 => "60m",
        ModelKeepAlive.UntilQuit => "-1m",
        _ => "30m",
    };

    public static string DisplayName(this TranslationModelType type) => type switch
    {
        TranslationModelType.Standard => "Standard (Chat)",
        TranslationModelType.TranslateGemma => "TranslateGemma",
        _ => type.ToString(),
    };
}

/// <summary>Persist <see cref="SourceLanguage"/> as its BCP-47 tag ("zh-CN").</summary>
public sealed class SourceLanguageJsonConverter : JsonConverter<SourceLanguage>
{
    public override SourceLanguage Read(ref System.Text.Json.Utf8JsonReader reader, Type typeToConvert, System.Text.Json.JsonSerializerOptions options)
    {
        var raw = reader.TokenType == System.Text.Json.JsonTokenType.String ? reader.GetString() : null;
        return LanguageInfo.TryParseSource(raw, out var language) ? language : SourceLanguage.English;
    }

    public override void Write(System.Text.Json.Utf8JsonWriter writer, SourceLanguage value, System.Text.Json.JsonSerializerOptions options)
        => writer.WriteStringValue(value.Tag());
}

/// <summary>Persist <see cref="TargetLanguage"/> by name ("Chinese"), matching the macOS settings.</summary>
public sealed class TargetLanguageJsonConverter : JsonConverter<TargetLanguage>
{
    public override TargetLanguage Read(ref System.Text.Json.Utf8JsonReader reader, Type typeToConvert, System.Text.Json.JsonSerializerOptions options)
    {
        var raw = reader.TokenType == System.Text.Json.JsonTokenType.String ? reader.GetString() : null;
        return LanguageInfo.TryParseTarget(raw, out var language) ? language : TargetLanguage.Chinese;
    }

    public override void Write(System.Text.Json.Utf8JsonWriter writer, TargetLanguage value, System.Text.Json.JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString());
}
