using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using LiveCaptionsTranslator.models;

namespace LiveCaptionsTranslator.utils
{
    public static class TranslateAPI
    {
        // The application is now hard-coded to use Ollama exclusively.
        public static Func<string, CancellationToken, Task<string>> TranslateFunction => Ollama;
        public static bool IsLLMBased => true;
        public static string Prompt => Translator.Setting.Prompt;

        // 🔧 关键修复：移除全局HttpClient，防止并发冲突
        // private static readonly HttpClient client = new HttpClient();

        public static async Task<string> Ollama(string text, CancellationToken token = default)
        {
            var config = Translator.Setting.OllamaConfig;
            if (config == null)
            {
                return "[ERROR] Translation Failed: Ollama configuration not found.";
            }
            
            Console.WriteLine($"TranslateAPI.Ollama: Starting translation for text: '{text.Substring(0, Math.Min(20, text.Length))}...'" );
            
            // 🔥 修复：为每个请求创建独立的HttpClient实例，防止并发状态冲突
            using var client = new HttpClient()
            {
                Timeout = TimeSpan.FromSeconds(config.TimeoutSeconds)
            };
            
            Console.WriteLine($"TranslateAPI.Ollama: Created new HttpClient with timeout {config.TimeoutSeconds}s");
            
            string language = OllamaConfig.SupportedLanguages.TryGetValue(
                Translator.Setting.TargetLanguage, out var langValue) ? langValue : Translator.Setting.TargetLanguage;
            string apiUrl = $"http://{config.Host}:{config.Port}/api/chat";
            
            var messages = new List<BaseLLMConfig.Message>
            {
                new BaseLLMConfig.Message { role = "system", content = string.Format(Prompt, language) },
                new BaseLLMConfig.Message { role = "user", content = $"🔤 {text} 🔤" }
            };
            if (Translator.Setting.ContextAware)
            {
                foreach (var entry in Translator.Caption.DisplayContexts)
                {
                    string translatedText = entry.TranslatedText;
                    if (translatedText.Contains("[ERROR]") || translatedText.Contains("[WARNING]"))
                        continue;
                    translatedText = RegexPatterns.NoticePrefix().Replace(translatedText, "");
                        
                    messages.InsertRange(1, [
                        new BaseLLMConfig.Message { role = "user", content = $"🔤 {entry.SourceText} 🔤" },
                        new BaseLLMConfig.Message { role = "assistant", content = $"{translatedText}" }
                    ]);
                }
            }

            var requestData = new
            {
                model = config.ModelName,
                messages = messages,
                temperature = config.Temperature,
                max_tokens = 64,
                stream = false,
                keep_alive = "5m"  // 降低为5分钟，更快释放显存
            };

            string jsonContent = JsonSerializer.Serialize(requestData);
            var content = new StringContent(jsonContent, Encoding.UTF8, "application/json");
            client.DefaultRequestHeaders.Clear();

            HttpResponseMessage response;
            const int maxRetries = 1; // Only retry once
            int retryCount = 0;

            while (true)
            {
                try
                {
                    Console.WriteLine($"TranslateAPI.Ollama: Sending POST request to {apiUrl}");
                    response = await client.PostAsync(apiUrl, content, token);
                    Console.WriteLine($"TranslateAPI.Ollama: Request completed with status {response.StatusCode}");
                    break; // Success, exit loop
                }
                catch (OperationCanceledException ex)
                {
                    Console.WriteLine($"TranslateAPI.Ollama: Request canceled: {ex.Message}");
                    if (ex.Message.StartsWith("The request"))
                        return $"[ERROR] Translation Failed: The request was canceled due to timeout (> {config.TimeoutSeconds} seconds), please use a faster API or increase timeout in settings.";
                    throw;
                }
                catch (HttpRequestException ex) when (ex.InnerException is System.Net.Sockets.SocketException se && se.SocketErrorCode == System.Net.Sockets.SocketError.ConnectionRefused && retryCount < maxRetries)
                {
                    Console.WriteLine($"TranslateAPI.Ollama: Connection refused. Attempting to restart Ollama service. Retry {retryCount + 1}/{maxRetries}");
                    retryCount++;

                    // Attempt to restart the server
                    if (!OllamaGuardian.StartServer(null))
                    {
                        return "[ERROR] Translation Failed: Ollama service could not be restarted.";
                    }

                    // Wait for the server to become healthy
                    int healthCheckRetries = 0;
                    while (healthCheckRetries < 30) // Wait up to 30 seconds
                    {
                        if (OllamaGuardian.IsServerHealthy())
                        {
                            Console.WriteLine("TranslateAPI.Ollama: Ollama service restarted and is healthy.");
                            await Task.Delay(1000); // Give it an extra second to be safe
                            break;
                        }
                        await Task.Delay(1000);
                        healthCheckRetries++;
                    }

                    if (healthCheckRetries >= 30)
                    {
                        return "[ERROR] Translation Failed: Ollama service restarted but did not become healthy in time.";
                    }
                    
                    // Continue to the next iteration to retry the request
                    continue; 
                }
                catch (HttpRequestException ex)
                {
                    Console.WriteLine($"TranslateAPI.Ollama: HTTP request error: {ex.Message}");
                    return $"[ERROR] Translation Failed: HTTP Request Error - {ex.Message}";
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"TranslateAPI.Ollama: Unexpected error: {ex.Message}");
                    // 🔥 特别检测HttpClient并发冲突错误
                    if (ex.Message.Contains("already started one or more requests"))
                    {
                        return $"[ERROR] Translation Failed: HttpClient concurrent conflict - {ex.Message}. Please try again.";
                    }
                    return $"[ERROR] Translation Failed: {ex.Message}";
                }
            }

            if (response.IsSuccessStatusCode)
            {
                string responseString = await response.Content.ReadAsStringAsync();
                var responseObj = JsonSerializer.Deserialize<OllamaConfig.Response>(responseString);
                var output = responseObj?.message?.content ?? "[ERROR] Empty response from Ollama";
                return RegexPatterns.ModelThinking().Replace(output, "");
            }
            else
                return $"[ERROR] Translation Failed: HTTP Error - {response.StatusCode}";
        }
        
        // 🔥 新增：卸载模型方法，释放GPU显存
        public static async Task<bool> UnloadModel()
        {
            var config = Translator.Setting?.OllamaConfig;
            if (config == null)
            {
                Console.WriteLine("TranslateAPI.UnloadModel: Ollama configuration not found");
                return false;
            }
            
            try
            {
                Console.WriteLine("🎯 TranslateAPI.UnloadModel: Attempting to unload model and free GPU memory");
                
                using var client = new HttpClient()
                {
                    Timeout = TimeSpan.FromSeconds(10) // 短超时时间
                };
                
                string apiUrl = $"http://{config.Host}:{config.Port}/api/chat";
                
                // 发送一个简单请求，keep_alive=0 表示立即卸载模型
                var unloadRequest = new
                {
                    model = config.ModelName,
                    messages = new[]
                    {
                        new BaseLLMConfig.Message { role = "user", content = "exit" }
                    },
                    stream = false,
                    keep_alive = 0  // 🔥 关键：设置为0表示立即卸载模型
                };
                
                string jsonContent = JsonSerializer.Serialize(unloadRequest);
                var content = new StringContent(jsonContent, Encoding.UTF8, "application/json");
                
                var response = await client.PostAsync(apiUrl, content);
                
                if (response.IsSuccessStatusCode)
                {
                    Console.WriteLine("✅ TranslateAPI.UnloadModel: Model unload request sent successfully, GPU memory should be freed");
                    return true;
                }
                else
                {
                    Console.WriteLine($"⚠️ TranslateAPI.UnloadModel: Unload request failed with status {response.StatusCode}");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"❌ TranslateAPI.UnloadModel: Failed to unload model: {ex.Message}");
                return false;
            }
        }
    }
}