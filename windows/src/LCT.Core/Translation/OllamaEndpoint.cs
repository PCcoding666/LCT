namespace LCT.Core.Translation;

/// <summary>
/// A validated Ollama endpoint. Loopback endpoints use HTTP; every non-loopback
/// endpoint requires the explicit remote opt-in and is built with HTTPS only.
/// Malformed input never produces an endpoint, so no request can be sent.
/// </summary>
public sealed record OllamaEndpoint(string Host, int Port, bool IsLoopback)
{
    private static readonly HashSet<string> LoopbackHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "localhost", "127.0.0.1", "::1", "[::1]",
    };

    public static readonly OllamaEndpoint Local = new("localhost", 11434, true);

    public string Scheme => IsLoopback ? "http" : "https";

    public string BaseUrl
    {
        get
        {
            var host = Host.StartsWith('[') ? Host : Host.Contains(':') ? $"[{Host}]" : Host;
            return $"{Scheme}://{host}:{Port}";
        }
    }

    public Uri Api(string path) => new($"{BaseUrl}/{path.TrimStart('/')}");

    public static bool TryValidate(string rawHost, int port, bool remoteOptIn, out OllamaEndpoint? endpoint, out string? error)
    {
        endpoint = null;
        error = null;
        if (port is < 1 or > 65535)
        {
            error = "Invalid Ollama port. Enter a number between 1 and 65535.";
            return false;
        }
        var host = (rawHost ?? "").Trim();
        if (host.Length == 0)
        {
            error = "Invalid Ollama host. Enter a bare host name without scheme, path, port, or credentials.";
            return false;
        }
        var isLoopback = LoopbackHosts.Contains(host);
        if (!isLoopback)
        {
            var forbidden = host.Contains("://") || host.Contains('/') || host.Contains('@') || host.Contains(':') || host.Contains(' ');
            var validCharset = host.All(c => char.IsLetterOrDigit(c) || c == '.' || c == '-');
            if (forbidden || !validCharset)
            {
                error = "Invalid Ollama host. Enter a bare host name without scheme, path, port, or credentials.";
                return false;
            }
            if (!remoteOptIn)
            {
                error = "Remote Ollama is disabled. Enable the remote opt-in to connect over HTTPS.";
                return false;
            }
        }
        endpoint = new OllamaEndpoint(host, port, isLoopback);
        return true;
    }

    /// <summary>Parse a loopback URL such as http://localhost:11434. Remote URLs are rejected.</summary>
    public static OllamaEndpoint? ParseLoopback(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return null;
        }
        if (uri.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(uri.UserInfo)
            || (uri.AbsolutePath != "/" && uri.AbsolutePath.Length > 0) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
        {
            return null;
        }
        return TryValidate(uri.Host, uri.Port, false, out var endpoint, out _) ? endpoint : null;
    }
}
