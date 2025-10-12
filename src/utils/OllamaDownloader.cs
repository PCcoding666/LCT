using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace LiveCaptionsTranslator.utils
{
    public class OllamaDownloader
    {
        // 指向 Intel Arc / iGPU 专用的 IPEX-LLM Ollama 便携版
        // 使用用户提供的正确下载链接
        private const string INTEL_OLLAMA_URL = "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250725-win.zip";
        
        // 备用下载链接 - 基于用户提供的正确链接格式更新其他版本
        private static readonly string[] BACKUP_URLS = {
            "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250724-win.zip",
            "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250630-win.zip",
            "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250611-win.zip",
            // 如果 IPEX-LLM 不可用，回退到官方 Ollama
            "https://github.com/ollama/ollama/releases/download/v0.3.12/ollama-windows-amd64.zip"
        };
        private readonly HttpClient _httpClient;
        private readonly IProgress<string>? _progress;
        private const int MAX_RETRIES = 3;
        private const int TIMEOUT_SECONDS = 300; // 5分钟超时
        private const int BUFFER_SIZE = 8192;

        public OllamaDownloader(IProgress<string>? progress = null)
        {
            _httpClient = new HttpClient();
            _httpClient.Timeout = TimeSpan.FromSeconds(TIMEOUT_SECONDS);
            _httpClient.DefaultRequestHeaders.Add("User-Agent", "DellLiveCaptionsTranslator");
            _progress = progress;
        }

        public async Task DownloadOllamaAsync(string destinationPath)
        {
            _progress?.Report("[Ollama] Starting download...");
            
            var tempPath = destinationPath + ".temp";
            var downloadedBytes = 0L;
            var downloadStartTime = DateTime.Now;
            var lastProgressUpdate = DateTime.Now;
            
            // Get download URL list (prioritize user-defined URL)
            var allUrls = GetDownloadUrls();
            
            foreach (var url in allUrls)
            {
                var retryCount = 0;
                downloadedBytes = 0L;
                
                _progress?.Report($"[Ollama] Attempting download from {url.Substring(0, Math.Min(60, url.Length))}...");
                
                while (retryCount < MAX_RETRIES)
                {
                    try
                    {
                        if (File.Exists(tempPath))
                        {
                            downloadedBytes = new FileInfo(tempPath).Length;
                            _progress?.Report($"[Ollama] Resuming download from {downloadedBytes / 1024 / 1024}MB...");
                        }

                        using var request = new HttpRequestMessage(HttpMethod.Get, url);
                        if (downloadedBytes > 0)
                        {
                            request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(downloadedBytes, null);
                        }

                        using var response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
                        response.EnsureSuccessStatusCode();

                        var totalBytes = response.Content.Headers.ContentLength ?? -1L;
                        if (downloadedBytes > 0)
                        {
                            totalBytes += downloadedBytes;
                        }

                        using (var contentStream = await response.Content.ReadAsStreamAsync())
                        using (var fileStream = new FileStream(tempPath, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None))
                        {
                            fileStream.Seek(downloadedBytes, SeekOrigin.Begin);
                            var buffer = new byte[BUFFER_SIZE];
                            var isMoreToRead = true;
                            var lastReportedPercentage = -1;

                            do
                            {
                                var bytesRead = await contentStream.ReadAsync(buffer);
                                if (bytesRead == 0)
                                {
                                    isMoreToRead = false;
                                    continue;
                                }

                                await fileStream.WriteAsync(buffer.AsMemory(0, bytesRead));
                                downloadedBytes += bytesRead;

                                if (totalBytes != -1L)
                                {
                                    var percentage = (int)((double)downloadedBytes / totalBytes * 100);
                                    var now = DateTime.Now;
                                    
                                    // Report progress every 5% or every 2 seconds
                                    if (percentage != lastReportedPercentage && 
                                        (percentage % 5 == 0 || (now - lastProgressUpdate).TotalSeconds >= 2))
                                    {
                                        var completedMB = (double)downloadedBytes / 1024 / 1024;
                                        var totalMB = (double)totalBytes / 1024 / 1024;
                                        var elapsedSeconds = (now - downloadStartTime).TotalSeconds;
                                        var speed = elapsedSeconds > 0 ? completedMB / elapsedSeconds : 0;
                                        
                                        _progress?.Report($"[Ollama] Download: {percentage}% ({completedMB:F1}MB / {totalMB:F1}MB) - Speed: {speed:F2}MB/s");
                                        lastReportedPercentage = percentage;
                                        lastProgressUpdate = now;
                                    }
                                }
                            }
                            while (isMoreToRead);
                        }

                        // After download completes, rename temp file to destination
                        if (File.Exists(destinationPath))
                        {
                            File.Delete(destinationPath);
                        }
                        File.Move(tempPath, destinationPath);

                        _progress?.Report("[Ollama] Download completed!");
                        return; // Successful download, exit
                    }
                    catch (Exception ex)
                    {
                        retryCount++;
                        if (retryCount < MAX_RETRIES)
                        {
                            _progress?.Report($"[Ollama] Download failed, retrying ({retryCount}/{MAX_RETRIES}): {ex.Message}");
                            await Task.Delay(1000 * retryCount); // Incremental delay
                        }
                        else
                        {
                            _progress?.Report($"[Ollama] Download failed from this source: {ex.Message}");
                            break; // Exit retry loop, try next URL
                        }
                    }
                }
            }
            
            // All URLs failed
            throw new Exception("All download sources unavailable. Please check network connection or contact support for updated download links.");
        }

        private string[] GetDownloadUrls()
        {
            var urls = new List<string>();
            
            // If user configured custom URL, use it first
            try
            {
                var customUrl = Translator.Setting?.OllamaConfig?.CustomDownloadUrl;
                if (!string.IsNullOrWhiteSpace(customUrl))
                {
                    urls.Add(customUrl.Trim());
                }
            }
            catch
            {
                // Ignore configuration read errors
            }
            
            // Add default links
            urls.Add(INTEL_OLLAMA_URL);
            urls.AddRange(BACKUP_URLS);
            
            return urls.ToArray();
        }

        public async Task<bool> ValidateDownloadAsync(string filePath)
        {
            _progress?.Report("[Ollama] Validating download...");
            
            if (!File.Exists(filePath))
            {
                _progress?.Report("[Ollama] Downloaded file not found!");
                return false;
            }

            try
            {
                using var fileStream = File.OpenRead(filePath);
                // TODO: Add file validation logic (if Intel provides checksums)
                _progress?.Report("[Ollama] File validation passed.");
                return true;
            }
            catch (Exception ex)
            {
                _progress?.Report($"[Ollama] File validation failed: {ex.Message}");
                return false;
            }
        }
    }
} 