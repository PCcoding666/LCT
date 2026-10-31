using System.Net;
using System.Text;
using System.Text.Json;
using LCT.Core.Models;
using LCT.Core.Translation;
using Xunit;

namespace LCT.Tests;

/// <summary>Scripted HTTP handler: records requests and returns canned responses.</summary>
internal sealed class FakeHandler : HttpMessageHandler
{
    public List<(HttpRequestMessage Request, string Body)> Requests { get; } = new();
    public Func<HttpRequestMessage, string, HttpResponseMessage> Respond { get; set; } = (_, _) => new HttpResponseMessage(HttpStatusCode.OK);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add((request, body));
        return Respond(request, body);
    }

    public static HttpResponseMessage Ndjson(params object[] lines)
    {
        var text = string.Join("\n", lines.Select(l => JsonSerializer.Serialize(l))) + "\n";
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/x-ndjson") };
    }
}

public class OllamaClientTests
{
    private static OllamaClientOptions Options(AppSettings? settings = null) => OllamaClientOptions.From(settings ?? new AppSettings());

    [Fact]
    public void testChatBody_CarriesThinkFalseKeepAliveAndNumCtx()
    {
        var body = OllamaClient.BuildChatBody(Options(new AppSettings { ModelKeepAlive = ModelKeepAlive.Hour1, OllamaNumCtx = 2048, OllamaTemperature = 0.2 }), "hello", Array.Empty<TranslationEntry>(), true);
        using var doc = JsonDocument.Parse(body);
        var root = doc.RootElement;
        Assert.False(root.GetProperty("think").GetBoolean());
        Assert.True(root.GetProperty("stream").GetBoolean());
        Assert.Equal("60m", root.GetProperty("keep_alive").GetString());
        Assert.Equal(2048, root.GetProperty("options").GetProperty("num_ctx").GetInt32());
        Assert.Equal(0.2, root.GetProperty("options").GetProperty("temperature").GetDouble(), 3);
        Assert.Equal("qwen3.5:4b", root.GetProperty("model").GetString());
    }

    [Fact]
    public void testMessages_StandardIncludesSystemAndContext()
    {
        var context = new List<TranslationEntry>
        {
            new(Guid.NewGuid(), "one", "一", "Chinese", DateTime.UtcNow, 10),
            new(Guid.NewGuid(), "two", "二", "Chinese", DateTime.UtcNow, 10),
            new(Guid.NewGuid(), "three", "三", "Chinese", DateTime.UtcNow, 10),
        };
        var messages = OllamaClient.BuildMessages(Options(new AppSettings { MaxContextEntries = 2 }), "four", context);
        Assert.Equal("system", messages[0].Role);
        Assert.Contains("to Chinese", messages[0].Content);
        Assert.Equal(6, messages.Count); // system + 2×(user,assistant) + user
        Assert.Equal("🔤 two 🔤", messages[1].Content);
        Assert.Equal("二", messages[2].Content);
        Assert.Equal("🔤 four 🔤", messages[^1].Content);
    }

    [Fact]
    public void testMessages_ContextDisabled_OmitsHistory()
    {
        var context = new List<TranslationEntry> { new(Guid.NewGuid(), "one", "一", "Chinese", DateTime.UtcNow, 10) };
        var messages = OllamaClient.BuildMessages(Options(new AppSettings { ContextAware = false }), "two", context);
        Assert.Equal(2, messages.Count);
    }

    [Fact]
    public void testMessages_TranslateGemma_UsesLanguageTag()
    {
        var messages = OllamaClient.BuildMessages(Options(new AppSettings { OllamaModel = "translategemma:4b-it-q4_K_M", TargetLanguage = TargetLanguage.Japanese }), "hello", Array.Empty<TranslationEntry>());
        Assert.Single(messages);
        Assert.Equal("<2ja> hello", messages[0].Content);
        var body = OllamaClient.BuildChatBody(Options(new AppSettings { OllamaModel = "translategemma:4b-it-q4_K_M" }), "x", Array.Empty<TranslationEntry>(), false);
        Assert.Contains("\"temperature\":0.1", body);
    }

    [Fact]
    public async Task testTranslateStreaming_ConcatenatesTokensAndStripsMarkers()
    {
        var handler = new FakeHandler
        {
            Respond = (_, _) => FakeHandler.Ndjson(
                new { message = new { role = "assistant", content = "你" }, done = false },
                new { message = new { role = "assistant", content = "好🔤" }, done = false },
                new { message = new { role = "assistant", content = "" }, done = true }),
        };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var sb = new StringBuilder();
        var latency = await client.TranslateStreamingAsync("hello", Array.Empty<TranslationEntry>(), t => sb.Append(t), CancellationToken.None);
        Assert.Equal("你好", sb.ToString());
        Assert.True(latency >= 0);
        Assert.True(client.IsConnected);
        Assert.Equal("http://localhost:11434/api/chat", handler.Requests[0].Request.RequestUri!.ToString());
    }

    [Fact]
    public async Task testTranslateStreaming_RemovesThinkBlocksAcrossChunks()
    {
        var handler = new FakeHandler
        {
            Respond = (_, _) => FakeHandler.Ndjson(
                new { message = new { content = "<thi" }, done = false },
                new { message = new { content = "nk>pondering</th" }, done = false },
                new { message = new { content = "ink>Hola" }, done = false },
                new { message = new { content = "" }, done = true }),
        };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var sb = new StringBuilder();
        await client.TranslateStreamingAsync("hi", Array.Empty<TranslationEntry>(), t => sb.Append(t), CancellationToken.None);
        Assert.Equal("Hola", sb.ToString());
    }

    [Fact]
    public async Task testTranslateStreaming_404_IsModelNotFound()
    {
        var handler = new FakeHandler { Respond = (_, _) => new HttpResponseMessage(HttpStatusCode.NotFound) };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var ex = await Assert.ThrowsAsync<OllamaException>(() => client.TranslateStreamingAsync("hi", Array.Empty<TranslationEntry>(), _ => { }, CancellationToken.None));
        Assert.Equal(OllamaErrorKind.ModelNotFound, ex.Kind);
    }

    [Fact]
    public async Task testTranslateStreaming_ConnectionRefused_IsServerNotRunning()
    {
        var handler = new FakeHandler { Respond = (_, _) => throw new HttpRequestException("refused") };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var ex = await Assert.ThrowsAsync<OllamaException>(() => client.TranslateStreamingAsync("hi", Array.Empty<TranslationEntry>(), _ => { }, CancellationToken.None));
        Assert.Equal(OllamaErrorKind.ServerNotRunning, ex.Kind);
        Assert.False(await client.CheckHealthAsync());
    }

    [Fact]
    public async Task testInvalidEndpoint_NeverSendsRequests()
    {
        var handler = new FakeHandler();
        var client = new OllamaClient(new HttpClient(handler), Options(new AppSettings { OllamaHost = "remote.example.com" }));
        Assert.False(await client.CheckHealthAsync());
        await Assert.ThrowsAsync<OllamaException>(() => client.TranslateStreamingAsync("hi", Array.Empty<TranslationEntry>(), _ => { }, CancellationToken.None));
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task testLoadAndUnload_SendKeepAliveForms()
    {
        var handler = new FakeHandler();
        var client = new OllamaClient(new HttpClient(handler), Options(new AppSettings { ModelKeepAlive = ModelKeepAlive.UntilQuit }));
        await client.LoadModelAsync("qwen3.5:4b");
        await client.UnloadModelAsync("qwen3.5:4b");
        Assert.Contains("\"keep_alive\":\"-1m\"", handler.Requests[0].Body);
        Assert.Contains("\"num_ctx\":4096", handler.Requests[0].Body);
        Assert.DoesNotContain("prompt", handler.Requests[0].Body);
        Assert.Contains("\"keep_alive\":0", handler.Requests[1].Body);
        Assert.All(handler.Requests, r => Assert.EndsWith("/api/generate", r.Request.RequestUri!.ToString()));
    }

    [Fact]
    public async Task testPull_ReportsProgressAndCompletes()
    {
        var handler = new FakeHandler
        {
            Respond = (_, _) => FakeHandler.Ndjson(
                new { status = "pulling manifest" },
                new { status = "pulling x", digest = "x", total = 100, completed = 50 },
                new { status = "pulling x", digest = "x", total = 100, completed = 100 },
                new { status = "success" }),
        };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var snapshots = new List<PullSnapshot>();
        await client.PullModelAsync("qwen3.5:2b", new SyncProgress<PullSnapshot>(snapshots.Add), CancellationToken.None);
        Assert.True(snapshots.Last().IsComplete);
        Assert.Contains(snapshots, s => Math.Abs(s.OverallProgress - 0.5) < 0.01);
        Assert.Contains("\"name\":\"qwen3.5:2b\"", handler.Requests[0].Body);
    }

    [Fact]
    public async Task testPull_ServerError_Throws()
    {
        var handler = new FakeHandler { Respond = (_, _) => FakeHandler.Ndjson(new { error = "manifest not found" }) };
        var client = new OllamaClient(new HttpClient(handler), Options());
        await Assert.ThrowsAsync<OllamaPullException>(() => client.PullModelAsync("nope", null, CancellationToken.None));
    }

    [Fact]
    public async Task testInstalledModels_ParsedAndSorted()
    {
        var handler = new FakeHandler
        {
            Respond = (_, _) => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("""{"models":[{"name":"qwen3.5:4b","size":3320000000},{"name":"gemma:2b"}]}""", Encoding.UTF8, "application/json"),
            },
        };
        var client = new OllamaClient(new HttpClient(handler), Options());
        var models = await client.GetInstalledModelsAsync();
        Assert.Equal(new[] { "gemma:2b", "qwen3.5:4b" }, models.Select(m => m.Name));
    }

    [Fact]
    public void testParseLoadedModels_AcceptsNameOrModel()
    {
        var names = OllamaClient.ParseLoadedModels("""{"models":[{"name":"a:1"},{"model":"b:2"}]}""");
        Assert.Equal(new[] { "a:1", "b:2" }, names);
    }

    [Fact]
    public void testIsModelInstalled_HandlesUntaggedNames()
    {
        var installed = new[] { "qwen3.5:4b", "gemma:latest" };
        Assert.True(OllamaClient.IsModelInstalled("qwen3.5:4b", installed));
        Assert.True(OllamaClient.IsModelInstalled("gemma", installed));
        Assert.False(OllamaClient.IsModelInstalled("qwen3.5", new[] { "qwen3.5-x:4b" }));
        Assert.False(OllamaClient.IsModelInstalled("qwen3.5:2b", installed));
    }

    [Fact]
    public void testThinkTagFilter_PassesPlainTextAndKeepsPossiblePrefix()
    {
        var f = new ThinkTagFilter();
        Assert.Equal("Hello ", f.Push("Hello "));
        Assert.Equal("", f.Push("<th"));
        Assert.Equal("", f.Push("ink>hidden</think>"));
        Assert.Equal("World", f.Push("World"));
        Assert.Equal("a<b", f.Push("a<b"));
    }
}

internal sealed class SyncProgress<T> : IProgress<T>
{
    private readonly Action<T> _handler;
    public SyncProgress(Action<T> handler) => _handler = handler;
    public void Report(T value) => _handler(value);
}
