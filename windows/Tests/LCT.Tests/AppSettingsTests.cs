using LCT.Core.Models;
using Xunit;

namespace LCT.Tests;

public class AppSettingsTests
{
    [Fact]
    public void testDefaults_MatchMacOS_Defaults()
    {
        var s = new AppSettings();
        Assert.True(s.CaptureSystemAudio);
        Assert.True(s.CaptureMicrophone);
        Assert.Equal(SourceLanguage.English, s.SourceLanguage);
        Assert.Null(s.MicrophoneSourceLanguage);
        Assert.Equal("localhost", s.OllamaHost);
        Assert.Equal(11434, s.OllamaPort);
        Assert.False(s.RemoteOllamaOptIn);
        Assert.Equal(ModelKeepAlive.Minutes30, s.ModelKeepAlive);
        Assert.True(s.UnloadModelOnQuit);
        Assert.Equal(TargetLanguage.Chinese, s.TargetLanguage);
        Assert.True(s.ContextAware);
        Assert.Equal(5, s.MaxContextEntries);
        Assert.True(s.LiveDraftTranslation);
        Assert.False(s.HistoryEnabled);
        Assert.Equal(30, s.HistoryRetentionDays);
        Assert.Equal(5000, s.HistoryMaxEntries);
        Assert.Equal(0.85, s.OverlayOpacity);
        Assert.Equal(4096, s.OllamaNumCtx);
        Assert.Equal("small", s.WhisperModel);
    }

    [Fact]
    public void testRoundTrip_PreservesEveryValue()
    {
        var s = new AppSettings
        {
            SourceLanguage = SourceLanguage.Chinese,
            MicrophoneSourceLanguage = SourceLanguage.Japanese,
            TargetLanguage = TargetLanguage.Korean,
            ModelKeepAlive = ModelKeepAlive.UntilQuit,
            OllamaModel = "qwen3.5:2b",
            CustomPrompt = "Translate to {TARGET_LANGUAGE}",
            OverlayPositionX = 120.5,
            HistoryEnabled = true,
            RemoteOllamaOptIn = true,
            OllamaHost = "ollama.example.com",
        };
        var json = s.ToJson();
        var back = AppSettings.FromJson(json);
        Assert.Equal(s.SourceLanguage, back.SourceLanguage);
        Assert.Equal(s.MicrophoneSourceLanguage, back.MicrophoneSourceLanguage);
        Assert.Equal(s.TargetLanguage, back.TargetLanguage);
        Assert.Equal(s.ModelKeepAlive, back.ModelKeepAlive);
        Assert.Equal(s.OllamaModel, back.OllamaModel);
        Assert.Equal(s.CustomPrompt, back.CustomPrompt);
        Assert.Equal(s.OverlayPositionX, back.OverlayPositionX);
        Assert.True(back.HistoryEnabled);
        Assert.Equal("ollama.example.com", back.OllamaHost);
    }

    [Fact]
    public void testLanguages_PersistAsTagsAndNames()
    {
        var json = new AppSettings { SourceLanguage = SourceLanguage.ChineseTW, TargetLanguage = TargetLanguage.Japanese }.ToJson();
        Assert.Contains("\"SourceLanguage\": \"zh-TW\"", json);
        Assert.Contains("\"TargetLanguage\": \"Japanese\"", json);
        Assert.Contains("\"ModelKeepAlive\": \"Minutes30\"", json);
    }

    [Fact]
    public void testMissingAndUnknownKeys_LoadWithDefaults()
    {
        var back = AppSettings.FromJson("""{"SourceLanguage":"ja-JP","FutureKey":123,"HistoryEnabled":true}""");
        Assert.Equal(SourceLanguage.Japanese, back.SourceLanguage);
        Assert.True(back.HistoryEnabled);
        Assert.Equal(11434, back.OllamaPort);
        Assert.Equal(TargetLanguage.Chinese, back.TargetLanguage);
    }

    [Fact]
    public void testInvalidJson_YieldsDefaults()
    {
        var back = AppSettings.FromJson("{ not json");
        Assert.Equal(TargetLanguage.Chinese, back.TargetLanguage);
    }

    [Fact]
    public void testUnknownLanguageValue_FallsBackToDefault()
    {
        var back = AppSettings.FromJson("""{"SourceLanguage":"xx-YY","TargetLanguage":"Klingon"}""");
        Assert.Equal(SourceLanguage.English, back.SourceLanguage);
        Assert.Equal(TargetLanguage.Chinese, back.TargetLanguage);
    }

    [Fact]
    public void testLanguageFor_MicrophoneFollowsSystemWhenNull()
    {
        var s = new AppSettings { SourceLanguage = SourceLanguage.German };
        Assert.Equal(SourceLanguage.German, s.LanguageFor(AudioSource.Microphone));
        s.MicrophoneSourceLanguage = SourceLanguage.French;
        Assert.Equal(SourceLanguage.French, s.LanguageFor(AudioSource.Microphone));
        Assert.Equal(SourceLanguage.German, s.LanguageFor(AudioSource.System));
    }

    [Fact]
    public void testSaveLoad_FileRoundTrip()
    {
        var path = Path.Combine(Path.GetTempPath(), "lct-tests", Guid.NewGuid().ToString("N"), "settings.json");
        var s = new AppSettings { OllamaModel = "translategemma:4b-it-q4_K_M" };
        s.Save(path);
        Assert.True(File.Exists(path));
        Assert.False(File.Exists(path + ".tmp"));
        Assert.Equal("translategemma:4b-it-q4_K_M", AppSettings.Load(path).OllamaModel);
        Directory.Delete(Path.GetDirectoryName(path)!, true);
    }

    [Fact]
    public void testRemoteWithoutOptIn_IsInvalidEndpoint()
    {
        var s = new AppSettings { OllamaHost = "ollama.example.com" };
        Assert.Null(s.ValidatedOllamaEndpoint);
        Assert.Contains("Remote Ollama is disabled", s.OllamaEndpointError);
        Assert.Equal("lct-invalid://endpoint-disabled", s.OllamaUrl);
        s.RemoteOllamaOptIn = true;
        Assert.Equal("https://ollama.example.com:11434", s.OllamaUrl);
        Assert.False(s.IsLocalOllama);
    }
}
