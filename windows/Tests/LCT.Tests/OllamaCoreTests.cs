using LCT.Core.Models;
using LCT.Core.Speech;
using LCT.Core.Translation;
using Xunit;

namespace LCT.Tests;

public class OllamaEndpointTests
{
    [Fact]
    public void testLoopback_UsesHttpWithoutOptIn()
    {
        Assert.True(OllamaEndpoint.TryValidate("localhost", 11434, false, out var e, out _));
        Assert.Equal("http://localhost:11434", e!.BaseUrl);
        Assert.True(e.IsLoopback);
        Assert.True(OllamaEndpoint.TryValidate("127.0.0.1", 11434, false, out _, out _));
        Assert.True(OllamaEndpoint.TryValidate("::1", 11434, false, out var v6, out _));
        Assert.Equal("http://[::1]:11434", v6!.BaseUrl);
    }

    [Fact]
    public void testRemote_RequiresOptInAndUsesHttps()
    {
        Assert.False(OllamaEndpoint.TryValidate("ollama.example.com", 443, false, out _, out var error));
        Assert.Contains("opt-in", error);
        Assert.True(OllamaEndpoint.TryValidate("ollama.example.com", 11434, true, out var e, out _));
        Assert.Equal("https://ollama.example.com:11434", e!.BaseUrl);
        Assert.Equal("https://ollama.example.com:11434/api/chat", e.Api("api/chat").ToString());
    }

    [Theory]
    [InlineData("http://evil.com")]
    [InlineData("host/path")]
    [InlineData("user@host")]
    [InlineData("host:1234")]
    [InlineData("ho st")]
    [InlineData("")]
    public void testMalformedHosts_AreRejected(string host)
    {
        Assert.False(OllamaEndpoint.TryValidate(host, 11434, true, out _, out _));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(70000)]
    public void testPortRange_IsEnforced(int port)
    {
        Assert.False(OllamaEndpoint.TryValidate("localhost", port, false, out _, out _));
    }

    [Fact]
    public void testParseLoopback_AcceptsOnlyCleanLoopbackUrls()
    {
        Assert.NotNull(OllamaEndpoint.ParseLoopback("http://localhost:11434"));
        Assert.Null(OllamaEndpoint.ParseLoopback("http://remote.example.com:11434"));
        Assert.Null(OllamaEndpoint.ParseLoopback("http://localhost:11434/api"));
        Assert.Null(OllamaEndpoint.ParseLoopback("not a url"));
    }
}

public class PromptTemplateTests
{
    [Fact]
    public void testDefault_SubstitutesTarget()
    {
        var prompt = PromptTemplate.Render("", TargetLanguage.Japanese);
        Assert.Contains("to Japanese.", prompt);
        Assert.DoesNotContain("{TARGET_LANGUAGE}", prompt);
    }

    [Fact]
    public void testCustom_SubstitutesTarget()
    {
        Assert.Equal("Into Korean please", PromptTemplate.Render("Into {TARGET_LANGUAGE} please", TargetLanguage.Korean));
    }
}

public class ModelRecommenderTests
{
    private static HardwareProfile Pc(long ramGb, GpuVendor gpu = GpuVendor.None, long vramGb = 0, int cores = 8)
        => new("Test CPU", cores, ramGb * 1024 * 1024 * 1024, gpu, gpu == GpuVendor.None ? "" : "Test GPU", vramGb * 1024 * 1024 * 1024, false);

    [Fact]
    public void test16GB_Recommends4B()
    {
        var r = ModelRecommender.Recommend(Pc(16));
        Assert.Equal("qwen3.5:4b", r.Recommended.Name);
        Assert.Contains("fits in 16 GB", r.Reason);
    }

    [Fact]
    public void test8GB_Recommends2B()
    {
        var r = ModelRecommender.Recommend(Pc(8));
        Assert.Equal("qwen3.5:2b", r.Recommended.Name);
    }

    [Fact]
    public void test4GB_Recommends08B()
    {
        var r = ModelRecommender.Recommend(Pc(4));
        Assert.Equal("qwen3.5:0.8b", r.Recommended.Name);
        Assert.Contains("Largest model", r.Reason);
    }

    [Fact]
    public void test2GB_FallsBackToSmallestWithTightReason()
    {
        var r = ModelRecommender.Recommend(Pc(2));
        Assert.Equal("qwen3.5:0.8b", r.Recommended.Name);
        Assert.Contains("tight", r.Reason);
    }

    [Fact]
    public void testCapableGpu_Recommends4BEvenWith8GB()
    {
        var r = ModelRecommender.Recommend(Pc(8, GpuVendor.Nvidia, 8));
        Assert.Equal("qwen3.5:4b", r.Recommended.Name);
        Assert.Contains("Test GPU", r.Reason);
    }

    [Fact]
    public void testIntelIgpu_DoesNotCountAsCapable()
    {
        var pc = Pc(8, GpuVendor.Intel, 0);
        Assert.False(pc.HasCapableGpu);
        Assert.True(pc.HasIntelGpu);
        Assert.Equal("qwen3.5:2b", ModelRecommender.Recommend(pc).Recommended.Name);
    }

    [Fact]
    public void testAlternatives_ExcludeRecommendedAndIncludeGemma()
    {
        var r = ModelRecommender.Recommend(Pc(16));
        Assert.DoesNotContain(r.Alternatives, m => m.Name == r.Recommended.Name);
        Assert.Contains(r.Alternatives, m => m.Name == "translategemma:4b-it-q4_K_M");
        Assert.Equal(ModelCatalog.All.Count - 1, r.Alternatives.Count);
    }

    [Fact]
    public void testWhisperRecommendation()
    {
        Assert.Equal("small", WhisperModelCatalog.Recommend(Pc(16)).Name);
        Assert.Equal("base", WhisperModelCatalog.Recommend(Pc(4)).Name);
        Assert.Equal("base", WhisperModelCatalog.Recommend(Pc(16, cores: 2)).Name);
        Assert.Equal("https://huggingface.co/sandrohanea/whisper.net/resolve/v5/classic/ggml-small.bin", WhisperModelCatalog.Small.DownloadUrl);
    }

    [Fact]
    public void testByteFormat()
    {
        Assert.Equal("3.09 GB", ByteFormat.Format(3_320_000_000));
        Assert.Equal("465.4 MB", ByteFormat.Format(488_000_000));
    }
}

public class PullStreamAccumulatorTests
{
    [Fact]
    public void testProgress_IsMonotonicAcrossLayers()
    {
        var acc = new PullStreamAccumulator();
        Assert.Null(acc.Ingest(""));
        Assert.Null(acc.Ingest("not json"));
        var a = acc.Ingest("""{"status":"pulling a","digest":"a","total":1000,"completed":500}""")!;
        Assert.Equal(0.5, a.OverallProgress, 3);
        var b = acc.Ingest("""{"status":"pulling b","digest":"b","total":1000,"completed":0}""")!;
        Assert.Equal(0.5, b.OverallProgress, 3); // high-water mark, not 0.25
        Assert.Equal(2000, b.TotalBytes);
        var c = acc.Ingest("""{"status":"pulling a","digest":"a","total":1000,"completed":1000}""")!;
        Assert.Equal(0.5, c.OverallProgress, 3);
        var d = acc.Ingest("""{"status":"pulling b","digest":"b","total":1000,"completed":1000}""")!;
        Assert.Equal(1.0, d.OverallProgress, 3);
        Assert.False(d.IsComplete);
        var done = acc.Ingest("""{"status":"success"}""")!;
        Assert.True(done.IsComplete);
        acc.Finish();
    }

    [Fact]
    public void testErrorLine_Throws()
    {
        var acc = new PullStreamAccumulator();
        var ex = Assert.Throws<OllamaPullException>(() => acc.Ingest("""{"error":"pull model manifest: file does not exist"}"""));
        Assert.Contains("file does not exist", ex.Message);
    }

    [Fact]
    public void testFinishWithoutSuccess_Throws()
    {
        var acc = new PullStreamAccumulator();
        acc.Ingest("""{"status":"pulling","digest":"a","total":10,"completed":10}""");
        Assert.Throws<OllamaPullException>(() => acc.Finish());
    }
}

public class OllamaRecoveryControllerTests
{
    [Fact]
    public void testUnreachable_RestartsThreeTimesWithBackoffThenGivesUp()
    {
        var c = new OllamaRecoveryController(TimeSpan.FromSeconds(10));
        var s1 = c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable);
        Assert.Equal(OllamaRecoveryController.StepKind.RestartService, s1.Kind);
        Assert.Equal(TimeSpan.FromSeconds(10), s1.Delay);
        Assert.Equal(1, s1.Attempt);
        var s2 = c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable);
        Assert.Equal(TimeSpan.FromSeconds(20), s2.Delay);
        var s3 = c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable);
        Assert.Equal(TimeSpan.FromSeconds(40), s3.Delay);
        Assert.Equal(OllamaRecoveryController.StepKind.GiveUp, c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable).Kind);
        Assert.Equal(OllamaRecoveryController.StepKind.ProbeAgain, c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable).Kind);
        Assert.True(c.GaveUp);
    }

    [Fact]
    public void testHealthyAfterOutage_AnnouncesRecovery()
    {
        var c = new OllamaRecoveryController();
        Assert.Equal(OllamaRecoveryController.StepKind.ProbeAgain, c.Next(OllamaRecoveryController.ProbeOutcome.Healthy).Kind);
        c.Next(OllamaRecoveryController.ProbeOutcome.ServiceUnreachable);
        Assert.Equal(OllamaRecoveryController.StepKind.AnnounceRecovered, c.Next(OllamaRecoveryController.ProbeOutcome.Healthy).Kind);
        Assert.Equal(0, c.RestartAttempts);
        Assert.Equal(OllamaRecoveryController.StepKind.ProbeAgain, c.Next(OllamaRecoveryController.ProbeOutcome.Healthy).Kind);
    }

    [Fact]
    public void testModelNotLoaded_Reloads()
    {
        var c = new OllamaRecoveryController();
        Assert.Equal(OllamaRecoveryController.StepKind.ReloadModel, c.Next(OllamaRecoveryController.ProbeOutcome.ModelNotLoaded).Kind);
        Assert.False(c.IsRecovering);
    }
}
