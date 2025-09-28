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
            _httpClient.DefaultRequestHeaders.Add("User-Agent", "LiveCaptionsTranslator");
            _progress = progress;
        }

        public async Task DownloadOllamaAsync(string destinationPath)
        {
            _progress?.Report("开始下载 Ollama...");
            
            var tempPath = destinationPath + ".temp";
            var downloadedBytes = 0L;
            
            // 获取下载 URL 列表（优先使用用户自定义的 URL）
            var allUrls = GetDownloadUrls();
            
            foreach (var url in allUrls)
            {
                var retryCount = 0;
                downloadedBytes = 0L;
                
                _progress?.Report($"尝试从 {url} 下载...");
                
                while (retryCount < MAX_RETRIES)
                {
                    try
                    {
                        if (File.Exists(tempPath))
                        {
                            downloadedBytes = new FileInfo(tempPath).Length;
                            _progress?.Report($"发现未完成的下载，从 {downloadedBytes} 字节处继续...");
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
                        return; // 成功下载，退出
                    }
                    catch (Exception ex)
                    {
                        retryCount++;
                        if (retryCount < MAX_RETRIES)
                        {
                            _progress?.Report($"从 {url} 下载失败，正在重试 ({retryCount}/{MAX_RETRIES}): {ex.Message}");
                            await Task.Delay(1000 * retryCount); // 递增延迟
                        }
                        else
                        {
                            _progress?.Report($"从 {url} 下载失败: {ex.Message}");
                            break; // 退出重试循环，尝试下一个 URL
                        }
                    }
                }
            }
            
            // 所有 URL 都失败
            throw new Exception("所有下载源都不可用，请检查网络连接或联系开发者获取更新的下载链接。");
        }

        private string[] GetDownloadUrls()
        {
            var urls = new List<string>();
            
            // 如果用户配置了自定义 URL，优先使用
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
                // 忽略配置读取错误
            }
            
            // 添加默认链接
            urls.Add(INTEL_OLLAMA_URL);
            urls.AddRange(BACKUP_URLS);
            
            return urls.ToArray();
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