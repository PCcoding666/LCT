using System.Net.Http;
using LCT.Core.Speech;
using Serilog;

namespace LiveCaptionsTranslator.Services.Speech;

public sealed record DownloadProgress(long CompletedBytes, long TotalBytes)
{
    public double Fraction => TotalBytes > 0 ? Math.Min(1.0, (double)CompletedBytes / TotalBytes) : 0;
}

/// <summary>Whisper ggml models on disk, with on-demand download (progress, cancel, resume-safe temp file).</summary>
public sealed class WhisperModelStore
{
    private readonly string _directory;
    private readonly HttpClient _http;

    public WhisperModelStore(string directory, HttpClient? http = null)
    {
        _directory = directory;
        _http = http ?? new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("LCT/" + AppInfo.Version);
    }

    public string PathFor(WhisperModelInfo model) => Path.Combine(_directory, model.FileName);

    public bool IsDownloaded(WhisperModelInfo model)
    {
        var path = PathFor(model);
        // A truncated download is not a model; require most of the expected size.
        return File.Exists(path) && new FileInfo(path).Length > model.DownloadBytes * 0.9;
    }

    public bool IsDownloaded(string modelName)
    {
        var model = WhisperModelCatalog.Entry(modelName);
        return model != null && IsDownloaded(model);
    }

    public async Task DownloadAsync(WhisperModelInfo model, IProgress<DownloadProgress>? progress, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_directory);
        var target = PathFor(model);
        var temp = target + ".part";
        Log.Information("[Whisper] Downloading {Model} from {Url}", model.Name, model.DownloadUrl);

        using var response = await _http.GetAsync(model.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? model.DownloadBytes;

        try
        {
            await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
            await using (var file = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
            {
                var buffer = new byte[1 << 16];
                long done = 0;
                var lastReport = DateTime.MinValue;
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
                {
                    await file.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    done += read;
                    if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(100))
                    {
                        lastReport = DateTime.UtcNow;
                        progress?.Report(new DownloadProgress(done, total));
                    }
                }
                progress?.Report(new DownloadProgress(done, total));
            }
            File.Move(temp, target, overwrite: true);
            Log.Information("[Whisper] {Model} downloaded to {Path}", model.Name, target);
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { }
            throw;
        }
    }

    public void Delete(WhisperModelInfo model)
    {
        var path = PathFor(model);
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
