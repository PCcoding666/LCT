using System.Text.Json;

namespace LCT.Core.Translation;

public sealed record PullSnapshot(double OverallProgress, long CompletedBytes, long TotalBytes, string Status, bool IsComplete);

/// <summary>
/// Pure NDJSON parsing for /api/pull streams. Ollama reports progress per
/// layer and each layer restarts completed at zero, so a naive read makes the
/// bar jump backwards; per-layer totals are accumulated and a high-water mark
/// keeps the overall fraction monotonic.
/// </summary>
public sealed class PullStreamAccumulator
{
    private sealed class Layer
    {
        public long Total;
        public long Completed;
    }

    private readonly Dictionary<string, Layer> _layers = new();
    private string _status = "";
    private double _peakProgress;
    private bool _sawSuccess;

    /// <summary>Feed one line. Returns a snapshot, or null for blank or unparseable lines. Throws when the stream carries an error.</summary>
    public PullSnapshot? Ingest(string rawLine)
    {
        var line = rawLine.Trim();
        if (line.Length == 0)
        {
            return null;
        }
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line);
        }
        catch (JsonException)
        {
            return null;
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }
            if (root.TryGetProperty("error", out var errorElement) && errorElement.ValueKind == JsonValueKind.String)
            {
                var error = errorElement.GetString();
                if (!string.IsNullOrEmpty(error))
                {
                    throw new OllamaPullException(error);
                }
            }
            if (root.TryGetProperty("status", out var statusElement) && statusElement.ValueKind == JsonValueKind.String)
            {
                _status = statusElement.GetString() ?? _status;
            }
            if (root.TryGetProperty("digest", out var digestElement) && digestElement.ValueKind == JsonValueKind.String)
            {
                var digest = digestElement.GetString() ?? "";
                if (!_layers.TryGetValue(digest, out var layer))
                {
                    layer = new Layer();
                    _layers[digest] = layer;
                }
                if (root.TryGetProperty("total", out var total) && total.TryGetInt64(out var totalValue))
                {
                    layer.Total = Math.Max(layer.Total, totalValue);
                }
                if (root.TryGetProperty("completed", out var completed) && completed.TryGetInt64(out var completedValue))
                {
                    layer.Completed = Math.Max(layer.Completed, completedValue);
                }
            }
            if (_status == "success")
            {
                _sawSuccess = true;
                _peakProgress = 1.0;
            }
        }

        long completedBytes = 0, totalBytes = 0;
        foreach (var layer in _layers.Values)
        {
            completedBytes += layer.Completed;
            totalBytes += layer.Total;
        }
        if (totalBytes > 0)
        {
            _peakProgress = Math.Max(_peakProgress, Math.Min((double)completedBytes / totalBytes, 1.0));
        }
        return new PullSnapshot(_peakProgress, completedBytes, totalBytes, _status, _sawSuccess);
    }

    /// <summary>Validate the stream once it ends: a pull that never reported success did not finish.</summary>
    public void Finish()
    {
        if (!_sawSuccess)
        {
            throw new OllamaPullException("Download ended before completing");
        }
    }
}

public sealed class OllamaPullException : Exception
{
    public OllamaPullException(string message) : base($"Failed to pull model: {message}") { }
}
