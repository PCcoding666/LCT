using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using LCT.Core.Models;

namespace LCT.Core.Translation;

public enum OllamaErrorKind
{
    InvalidEndpoint,
    ServerNotRunning,
    Timeout,
    ModelNotFound,
    Http,
    InvalidResponse,
    Network,
}

public sealed class OllamaException : Exception
{
    public OllamaErrorKind Kind { get; }
    public int StatusCode { get; }

    public OllamaException(OllamaErrorKind kind, string message, int statusCode = 0, Exception? inner = null) : base(message, inner)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public static OllamaException InvalidEndpoint() => new(OllamaErrorKind.InvalidEndpoint, "Invalid Ollama API URL");
    public static OllamaException ServerNotRunning() => new(OllamaErrorKind.ServerNotRunning, "Ollama server is not running");
    public static OllamaException Timeout() => new(OllamaErrorKind.Timeout, "Request timed out");
    public static OllamaException ModelNotFound(string model) => new(OllamaErrorKind.ModelNotFound, $"Model '{model}' is not installed", 404);
    public static OllamaException Http(int status) => new(OllamaErrorKind.Http, $"HTTP error: {status}", status);
    public static OllamaException InvalidResponse() => new(OllamaErrorKind.InvalidResponse, "Invalid response from Ollama");
}

/// <summary>What the client needs from settings; a snapshot so it can be swapped atomically.</summary>
public sealed record OllamaClientOptions(
    OllamaEndpoint? Endpoint,
    string Model,
    ModelKeepAlive KeepAlive,
    double Temperature,
    int NumCtx,
    TimeSpan Timeout,
    string SystemPrompt,
    bool ContextAware,
    int MaxContextEntries,
    TranslationModelType ModelType,
    TargetLanguage Target)
{
    public static OllamaClientOptions From(AppSettings s) => new(
        s.ValidatedOllamaEndpoint,
        s.OllamaModel,
        s.ModelKeepAlive,
        s.OllamaTemperature,
        s.OllamaNumCtx,
        TimeSpan.FromSeconds(Math.Max(5, s.OllamaTimeout)),
        s.TranslationPrompt,
        s.ContextAware,
        s.MaxContextEntries,
        s.TranslationModelType,
        s.TargetLanguage);
}

/// <summary>Anything that can stream a translation; the queue depends on this, not on HTTP.</summary>
public interface ITranslator
{
    /// <summary>Stream a translation. onToken is called in order; returns latency in ms.</summary>
    Task<int> TranslateStreamingAsync(string text, IReadOnlyList<TranslationEntry> context, Action<string> onToken, CancellationToken cancellationToken);
}

/// <summary>
/// Ollama HTTP client. Every model-loading request carries think:false, the
/// configured keep_alive and options.num_ctx. Takes an HttpClient so tests can
/// inject a handler.
/// </summary>
public sealed class OllamaClient : ITranslator
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _http;
    private volatile OllamaClientOptions _options;

    public OllamaClientOptions Options => _options;
    public bool IsConnected { get; private set; }
    public string? LastError { get; private set; }

    public OllamaClient(HttpClient http, OllamaClientOptions options)
    {
        _http = http;
        _http.Timeout = System.Threading.Timeout.InfiniteTimeSpan; // per-request timeouts below
        _options = options;
    }

    public void Configure(OllamaClientOptions options) => _options = options;

    // ---- Request/response shapes ----

    private sealed record ChatMessage(string Role, string Content);

    private sealed class ChatRequest
    {
        public string Model { get; init; } = "";
        public List<ChatMessage> Messages { get; init; } = new();
        public bool Stream { get; init; }
        public bool Think { get; init; }
        [JsonPropertyName("keep_alive")] public string? KeepAlive { get; init; }
        public Dictionary<string, object> Options { get; init; } = new();
    }

    private sealed class ChatChunk
    {
        public ChatMessage? Message { get; init; }
        public bool Done { get; init; }
        public string? Error { get; init; }
    }

    private sealed class TagsResponse
    {
        public List<TagModel> Models { get; init; } = new();
    }

    public sealed class TagModel
    {
        public string Name { get; init; } = "";
        public long? Size { get; init; }
        [JsonPropertyName("modified_at")] public string? ModifiedAt { get; init; }
    }

    private sealed class PsResponse
    {
        public List<PsModel> Models { get; init; } = new();
    }

    private sealed class PsModel
    {
        public string? Name { get; init; }
        public string? Model { get; init; }
    }

    // ---- Message building ----

    /// <summary>Build the chat messages for a request. Exposed for tests.</summary>
    public static IReadOnlyList<(string Role, string Content)> BuildMessages(OllamaClientOptions options, string text, IReadOnlyList<TranslationEntry> context)
    {
        var useGemma = options.ModelType == TranslationModelType.TranslateGemma || ModelCatalog.IsTranslateGemma(options.Model);
        if (useGemma)
        {
            return new[] { ("user", $"<2{options.Target.IsoCode()}> {text}") };
        }
        var messages = new List<(string, string)> { ("system", options.SystemPrompt) };
        if (options.ContextAware)
        {
            foreach (var entry in context.TakeLast(Math.Max(0, options.MaxContextEntries)))
            {
                messages.Add(("user", $"🔤 {entry.SourceText} 🔤"));
                messages.Add(("assistant", entry.TranslatedText));
            }
        }
        messages.Add(("user", $"🔤 {text} 🔤"));
        return messages;
    }

    /// <summary>The JSON body for a chat request. Exposed so tests can assert think/keep_alive/num_ctx.</summary>
    public static string BuildChatBody(OllamaClientOptions options, string text, IReadOnlyList<TranslationEntry> context, bool stream)
    {
        var useGemma = options.ModelType == TranslationModelType.TranslateGemma || ModelCatalog.IsTranslateGemma(options.Model);
        var request = new ChatRequest
        {
            Model = options.Model,
            Messages = BuildMessages(options, text, context).Select(m => new ChatMessage(m.Role, m.Content)).ToList(),
            Stream = stream,
            Think = false,
            KeepAlive = options.KeepAlive.OllamaValue(),
            Options = new Dictionary<string, object>
            {
                ["temperature"] = useGemma ? 0.1 : options.Temperature,
                ["num_ctx"] = options.NumCtx,
            },
        };
        return JsonSerializer.Serialize(request, Json);
    }

    // ---- Health / listing ----

    public async Task<bool> CheckHealthAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint;
        if (endpoint == null)
        {
            IsConnected = false;
            return false;
        }
        try
        {
            using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(3));
            using var response = await _http.GetAsync(endpoint.Api("api/tags"), cts.Token).ConfigureAwait(false);
            IsConnected = response.StatusCode == HttpStatusCode.OK;
            return IsConnected;
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            IsConnected = false;
            return false;
        }
    }

    public async Task<string?> GetVersionAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint;
        if (endpoint == null)
        {
            return null;
        }
        try
        {
            using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(3));
            using var document = await _http.GetFromJsonAsync<JsonDocument>(endpoint.Api("api/version"), cts.Token).ConfigureAwait(false);
            return document?.RootElement.TryGetProperty("version", out var v) == true ? v.GetString() : null;
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    public async Task<IReadOnlyList<TagModel>> GetInstalledModelsAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(5));
        using var response = await SendAsync(() => new HttpRequestMessage(HttpMethod.Get, endpoint.Api("api/tags")), cts.Token).ConfigureAwait(false);
        var tags = await response.Content.ReadFromJsonAsync<TagsResponse>(Json, cts.Token).ConfigureAwait(false) ?? throw OllamaException.InvalidResponse();
        return tags.Models.OrderBy(m => m.Name, StringComparer.Ordinal).ToList();
    }

    public async Task<IReadOnlyList<string>> GetLoadedModelsAsync(CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(5));
        using var response = await SendAsync(() => new HttpRequestMessage(HttpMethod.Get, endpoint.Api("api/ps")), cts.Token).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
        return ParseLoadedModels(body);
    }

    /// <summary>Parse /api/ps. Accepts both the name and the model field spelling.</summary>
    public static IReadOnlyList<string> ParseLoadedModels(string json)
    {
        var response = JsonSerializer.Deserialize<PsResponse>(json, Json) ?? throw OllamaException.InvalidResponse();
        return response.Models.Select(m => m.Name ?? m.Model).Where(n => !string.IsNullOrEmpty(n)).Cast<string>().ToList();
    }

    /// <summary>Installed when the exact name matches, or when the name has no tag and a tagged variant exists.</summary>
    public static bool IsModelInstalled(string modelName, IEnumerable<string> installed)
        => installed.Any(n => n == modelName || (!modelName.Contains(':') && n.StartsWith(modelName + ":", StringComparison.Ordinal)));

    // ---- Load / unload ----

    /// <summary>Map the model into memory without inference: /api/generate with no prompt.</summary>
    public async Task LoadModelAsync(string model, CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var body = new Dictionary<string, object> { ["model"] = model, ["keep_alive"] = _options.KeepAlive.OllamaValue(), ["options"] = new Dictionary<string, object> { ["num_ctx"] = _options.NumCtx } };
        using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(120));
        using var response = await SendAsync(() => JsonPost(endpoint.Api("api/generate"), body), cts.Token, model).ConfigureAwait(false);
    }

    /// <summary>keep_alive: 0 is Ollama's documented "unload immediately" form; runs no inference.</summary>
    public async Task UnloadModelAsync(string model, CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var body = new Dictionary<string, object> { ["model"] = model, ["keep_alive"] = 0 };
        using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(5));
        using var response = await SendAsync(() => JsonPost(endpoint.Api("api/generate"), body), cts.Token, model).ConfigureAwait(false);
    }

    /// <summary>Load the configured model with a trivial prompt so the first real request is fast. Returns ms.</summary>
    public async Task<int> PrewarmAsync(CancellationToken cancellationToken = default)
    {
        var options = _options;
        var endpoint = options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var started = DateTime.UtcNow;
        var body = BuildChatBody(options with { ContextAware = false }, "hi", Array.Empty<TranslationEntry>(), stream: false);
        using var cts = Linked(cancellationToken, TimeSpan.FromSeconds(Math.Max(options.Timeout.TotalSeconds * 2, 60)));
        using var response = await SendAsync(() => RawPost(endpoint.Api("api/chat"), body), cts.Token, options.Model).ConfigureAwait(false);
        LastError = null;
        return (int)(DateTime.UtcNow - started).TotalMilliseconds;
    }

    // ---- Translation ----

    public async Task<int> TranslateStreamingAsync(string text, IReadOnlyList<TranslationEntry> context, Action<string> onToken, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return 0;
        }
        var options = _options;
        var endpoint = options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var started = DateTime.UtcNow;
        var body = BuildChatBody(options, text, context, stream: true);

        try
        {
            using var cts = Linked(cancellationToken, options.Timeout);
            using var response = await SendAsync(() => RawPost(endpoint.Api("api/chat"), body), cts.Token, options.Model, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
            await using var stream = await response.Content.ReadAsStreamAsync(cts.Token).ConfigureAwait(false);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var thinkFilter = new ThinkTagFilter();
            while (!reader.EndOfStream)
            {
                cts.Token.ThrowIfCancellationRequested();
                var line = await reader.ReadLineAsync(cts.Token).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }
                ChatChunk? chunk;
                try
                {
                    chunk = JsonSerializer.Deserialize<ChatChunk>(line, Json);
                }
                catch (JsonException)
                {
                    continue;
                }
                if (chunk == null)
                {
                    continue;
                }
                if (!string.IsNullOrEmpty(chunk.Error))
                {
                    throw new OllamaException(OllamaErrorKind.Http, chunk.Error);
                }
                var content = chunk.Message?.Content;
                if (!string.IsNullOrEmpty(content))
                {
                    var clean = thinkFilter.Push(content.Replace("🔤", ""));
                    if (clean.Length > 0)
                    {
                        onToken(clean);
                    }
                }
                if (chunk.Done)
                {
                    break;
                }
            }
            LastError = null;
            return (int)(DateTime.UtcNow - started).TotalMilliseconds;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            LastError = "Request timed out";
            throw OllamaException.Timeout();
        }
        catch (OllamaException ex)
        {
            LastError = ex.Message;
            throw;
        }
    }

    // ---- Pull / delete ----

    /// <summary>Stream /api/pull, reporting progress; throws OllamaPullException on a server error or an early end.</summary>
    public async Task PullModelAsync(string model, IProgress<PullSnapshot>? progress, CancellationToken cancellationToken)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var body = JsonSerializer.Serialize(new Dictionary<string, object> { ["name"] = model, ["stream"] = true }, Json);
        using var response = await SendAsync(() => RawPost(endpoint.Api("api/pull"), body), cancellationToken, model, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var accumulator = new PullStreamAccumulator();
        while (!reader.EndOfStream)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line == null)
            {
                break;
            }
            var snapshot = accumulator.Ingest(line);
            if (snapshot != null)
            {
                progress?.Report(snapshot);
                if (snapshot.IsComplete)
                {
                    break;
                }
            }
        }
        accumulator.Finish();
    }

    public async Task DeleteModelAsync(string model, CancellationToken cancellationToken = default)
    {
        var endpoint = _options.Endpoint ?? throw OllamaException.InvalidEndpoint();
        var body = JsonSerializer.Serialize(new Dictionary<string, object> { ["name"] = model }, Json);
        using var response = await SendAsync(() =>
        {
            var request = new HttpRequestMessage(HttpMethod.Delete, endpoint.Api("api/delete"))
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
            return request;
        }, cancellationToken, model).ConfigureAwait(false);
    }

    // ---- Plumbing ----

    private static HttpRequestMessage JsonPost(Uri uri, object body)
        => RawPost(uri, JsonSerializer.Serialize(body, Json));

    private static HttpRequestMessage RawPost(Uri uri, string json)
        => new(HttpMethod.Post, uri) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    private async Task<HttpResponseMessage> SendAsync(Func<HttpRequestMessage> makeRequest, CancellationToken cancellationToken, string? model = null, HttpCompletionOption completion = HttpCompletionOption.ResponseContentRead)
    {
        HttpResponseMessage response;
        try
        {
            using var request = makeRequest();
            response = await _http.SendAsync(request, completion, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            IsConnected = false;
            LastError = "Ollama server is not running";
            throw new OllamaException(OllamaErrorKind.ServerNotRunning, "Ollama server is not running", 0, ex);
        }
        if (response.StatusCode == HttpStatusCode.NotFound && model != null)
        {
            response.Dispose();
            throw OllamaException.ModelNotFound(model);
        }
        if (!response.IsSuccessStatusCode)
        {
            var status = (int)response.StatusCode;
            string detail = "";
            try
            {
                detail = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Status alone is enough.
            }
            response.Dispose();
            throw new OllamaException(OllamaErrorKind.Http, string.IsNullOrWhiteSpace(detail) ? $"HTTP error: {status}" : $"HTTP {status}: {Truncate(detail, 200)}", status);
        }
        IsConnected = true;
        return response;
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";

    private static CancellationTokenSource Linked(CancellationToken token, TimeSpan timeout)
    {
        var cts = CancellationTokenSource.CreateLinkedTokenSource(token);
        cts.CancelAfter(timeout);
        return cts;
    }
}

/// <summary>
/// Strips &lt;think&gt;…&lt;/think&gt; blocks from a token stream even when the
/// tags straddle chunk boundaries. Everything outside the tags passes through.
/// </summary>
public sealed class ThinkTagFilter
{
    private readonly StringBuilder _pending = new();
    private bool _inside;

    private const string Open = "<think>";
    private const string Close = "</think>";

    public string Push(string token)
    {
        _pending.Append(token);
        var output = new StringBuilder();
        while (true)
        {
            var text = _pending.ToString();
            if (_inside)
            {
                var close = text.IndexOf(Close, StringComparison.Ordinal);
                if (close < 0)
                {
                    // Keep only a tail that could be the start of the close tag.
                    _pending.Clear();
                    _pending.Append(text[Math.Max(0, text.Length - (Close.Length - 1))..]);
                    return output.ToString();
                }
                _pending.Clear();
                _pending.Append(text[(close + Close.Length)..]);
                _inside = false;
                continue;
            }

            var open = text.IndexOf(Open, StringComparison.Ordinal);
            if (open >= 0)
            {
                output.Append(text[..open]);
                _pending.Clear();
                _pending.Append(text[(open + Open.Length)..]);
                _inside = true;
                continue;
            }

            // No tag. Emit everything except a tail that could become "<think>".
            var keep = 0;
            for (var len = Math.Min(Open.Length - 1, text.Length); len > 0; len--)
            {
                if (Open.StartsWith(text[^len..], StringComparison.Ordinal))
                {
                    keep = len;
                    break;
                }
            }
            output.Append(text[..^keep]);
            _pending.Clear();
            _pending.Append(text[^keep..]);
            return output.ToString();
        }
    }

    /// <summary>Remove complete think blocks from a finished string (non-streaming fallback).</summary>
    public static string Strip(string text)
        => Regex.Replace(Regex.Replace(text, "<think>.*?</think>", "", RegexOptions.Singleline), @"\[thinking\].*?\[/thinking\]", "", RegexOptions.Singleline | RegexOptions.IgnoreCase).Trim();
}
