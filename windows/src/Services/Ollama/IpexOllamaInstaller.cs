using System.Net.Http;
using System.IO.Compression;
using LCT.Core.Translation;
using Serilog;

namespace LiveCaptionsTranslator.Services.Ollama;

/// <summary>
/// Optional path for PCs with an Intel GPU and no Ollama: download the IPEX-LLM
/// portable Ollama build into %LOCALAPPDATA%\LCT\ollama. Offered in the wizard
/// only; never the default, never forced.
/// </summary>
public sealed class IpexOllamaInstaller
{
    public const string DefaultUrl = "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250725-win.zip";

    private static readonly string[] FallbackUrls =
    {
        "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250724-win.zip",
        "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250630-win.zip",
    };

    private readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };

    public bool IsInstalled => File.Exists(OllamaGuardian.PortableExecutable);

    public async Task InstallAsync(string? customUrl, IProgress<(string Status, double Fraction)>? progress, CancellationToken cancellationToken)
    {
        var urls = new List<string>();
        if (!string.IsNullOrWhiteSpace(customUrl))
        {
            urls.Add(customUrl.Trim());
        }
        urls.Add(DefaultUrl);
        urls.AddRange(FallbackUrls);

        Directory.CreateDirectory(AppPaths.DownloadsDirectory);
        var zip = Path.Combine(AppPaths.DownloadsDirectory, "ollama-ipex-llm.zip");
        Exception? last = null;
        foreach (var url in urls)
        {
            try
            {
                await DownloadAsync(url, zip, progress, cancellationToken).ConfigureAwait(false);
                last = null;
                break;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "[IPEX] Download from {Url} failed", url);
                last = ex;
            }
        }
        if (last != null)
        {
            throw new InvalidOperationException("All download sources failed: " + last.Message, last);
        }

        progress?.Report(("Extracting…", 0.95));
        var target = AppPaths.PortableOllamaDirectory;
        if (Directory.Exists(target))
        {
            Directory.Delete(target, true);
        }
        Directory.CreateDirectory(target);
        await Task.Run(() => ZipFile.ExtractToDirectory(zip, target, overwriteFiles: true), cancellationToken).ConfigureAwait(false);
        // Some archives wrap everything in one top-level folder; flatten it.
        if (!File.Exists(OllamaGuardian.PortableExecutable))
        {
            var nested = Directory.GetFiles(target, "ollama.exe", SearchOption.AllDirectories).FirstOrDefault();
            if (nested != null)
            {
                var nestedDir = Path.GetDirectoryName(nested)!;
                foreach (var entry in Directory.EnumerateFileSystemEntries(nestedDir))
                {
                    var destination = Path.Combine(target, Path.GetFileName(entry));
                    if (Directory.Exists(entry))
                    {
                        Directory.Move(entry, destination);
                    }
                    else
                    {
                        File.Move(entry, destination, true);
                    }
                }
            }
        }
        if (!File.Exists(OllamaGuardian.PortableExecutable))
        {
            throw new InvalidOperationException("The archive did not contain ollama.exe.");
        }
        try { File.Delete(zip); } catch (IOException) { }
        progress?.Report(("Installed", 1.0));
        Log.Information("[IPEX] Portable Ollama installed to {Dir}", target);
    }

    private async Task DownloadAsync(string url, string destination, IProgress<(string, double)>? progress, CancellationToken cancellationToken)
    {
        using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? -1L;
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var file = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true);
        var buffer = new byte[1 << 16];
        long done = 0;
        int read;
        var lastReport = DateTime.MinValue;
        while ((read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            await file.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            done += read;
            if (DateTime.UtcNow - lastReport > TimeSpan.FromMilliseconds(200))
            {
                lastReport = DateTime.UtcNow;
                var fraction = total > 0 ? (double)done / total * 0.9 : 0;
                progress?.Report(($"Downloading Ollama (Intel GPU build) {ByteFormat.Format(done)}{(total > 0 ? " / " + ByteFormat.Format(total) : "")}", fraction));
            }
        }
    }
}
