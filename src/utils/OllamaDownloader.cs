using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace LiveCaptionsTranslator.utils
{
    public class OllamaDownloader
    {
        // 指向 Intel Arc / iGPU 专用的 IPEX-LLM Ollama 便携版
        private const string INTEL_OLLAMA_URL = "https://github.com/ipex-llm/ipex-llm/releases/download/v2.3.0-nightly/ollama-ipex-llm-2.3.0b20250415-win.zip";
        private readonly HttpClient _httpClient;
        private readonly IProgress<string>? _progress;
        private const int MAX_RETRIES = 3;
        private const int TIMEOUT_SECONDS = 300; // 5分钟超时
        private const int BUFFER_SIZE = 8192;

        public OllamaDownloader(IProgress<string>? progress = null)
        {
            _httpClient = new HttpClient();
            _httpClient.Timeout = TimeSpan.FromSeconds(TIMEOUT_SECONDS);
            _httpClient.DefaultRequestHeaders.Add("User-Agent", "LiveCaptionsTranslator");
            _progress = progress;
        }

        public async Task DownloadOllamaAsync(string destinationPath)
        {
            _progress?.Report("开始下载 Ollama...");
            
            var tempPath = destinationPath + ".temp";
            var retryCount = 0;
            var downloadedBytes = 0L;

            while (retryCount < MAX_RETRIES)
            {
                try
                {
                    if (File.Exists(tempPath))
                    {
                        downloadedBytes = new FileInfo(tempPath).Length;
                        _progress?.Report($"发现未完成的下载，从 {downloadedBytes} 字节处继续...");
                    }

                    using var request = new HttpRequestMessage(HttpMethod.Get, INTEL_OLLAMA_URL);
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
                                _progress?.Report($"下载Ollama引擎: {percentage}% ({downloadedBytes / 1024 / 1024}MB / {totalBytes / 1024 / 1024}MB)");
                            }
                        }
                        while (isMoreToRead);
                    }

                    // 下载完成后，将临时文件重命名为目标文件
                    if (File.Exists(destinationPath))
                    {
                        File.Delete(destinationPath);
                    }
                    File.Move(tempPath, destinationPath);

                    _progress?.Report("下载完成！");
                    return;
                }
                catch (Exception ex)
                {
                    retryCount++;
                    if (retryCount < MAX_RETRIES)
                    {
                        _progress?.Report($"下载失败，正在重试 ({retryCount}/{MAX_RETRIES}): {ex.Message}");
                        await Task.Delay(1000 * retryCount); // 递增延迟
                    }
                    else
                    {
                        _progress?.Report($"下载失败: {ex.Message}");
                        throw;
                    }
                }
            }
        }

        public async Task<bool> ValidateDownloadAsync(string filePath)
        {
            _progress?.Report("验证下载文件...");
            
            if (!File.Exists(filePath))
            {
                _progress?.Report("下载文件不存在！");
                return false;
            }

            try
            {
                using var fileStream = File.OpenRead(filePath);
                // TODO: 添加文件校验逻辑（如果Intel提供了校验和）
                return true;
            }
            catch (Exception ex)
            {
                _progress?.Report($"文件验证失败: {ex.Message}");
                return false;
            }
        }
    }
} 