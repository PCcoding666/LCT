using System;
using System.Diagnostics;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using Serilog;

namespace LiveCaptionsTranslator.utils
{
    public class StartupManager
    {
        private const string DEFAULT_MODEL = "qwen2.5:3b";
        private readonly IProgress<string>? _progress;
        private readonly Window _splashWindow;
        private readonly ILogger _log;

        public StartupManager(Window splashWindow, IProgress<string>? progress = null)
        {
            _splashWindow = splashWindow;
            _progress = progress;
            _log = Log.ForContext<StartupManager>();
        }

        public async Task<bool> PerformStartupChecks()
        {
            try
            {
                _log.Information("Starting startup checks.");
                
                // 1. 确保停止所有现有的 Ollama 进程
                ReportAndLog("停止现有的 Ollama 进程...");
                OllamaGuardian.StopServer();

                // 2. 检查并创建必要的目录结构
                ReportAndLog("检查应用目录结构...");
                if (!await CheckDirectoryStructure()) return false;

                // 3. 检查 Ollama 可执行文件
                ReportAndLog("检查 Ollama 安装状态...");
                if (!await CheckOllamaInstallation()) return false;
                
                // 4. 等待一段时间确保所有文件句柄都被释放
                await Task.Delay(1000);

                // 5. 启动 Ollama 后端服务
                ReportAndLog("启动 Ollama 服务...");
                if (!await StartOllamaServer()) return false;

                // 6. 检查默认模型
                ReportAndLog("检查默认模型状态...");
                if (!await CheckAndPullDefaultModel()) return false;

                // 7. 验证模型可用性
                ReportAndLog("验证模型可用性...");
                if (!await ValidateModelAvailability()) return false;

                ReportAndLog("初始化完成！");
                _log.Information("Startup checks completed successfully.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "A critical error occurred during startup checks.");
                ReportAndLog($"启动失败: {ex.Message}");
                return false;
            }
        }
        
        private void ReportAndLog(string message)
        {
            _progress?.Report(message);
            _log.Information(message);
        }

        private async Task<bool> CheckDirectoryStructure()
        {
            try
            {
                ApplicationSetup.EnsureDirectoryStructure();
                _log.Information("Directory structure check passed.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "Failed to check or create directory structure.");
                ReportAndLog($"目录结构检查失败: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> CheckOllamaInstallation()
        {
            try
            {
                if (ApplicationSetup.IsFirstRun || !ApplicationSetup.IsCorrectVersionInstalled())
                {
                    ReportAndLog("首次运行或版本不匹配，需要解压Ollama...");
                    await ApplicationSetup.ExtractOllamaAsync(_progress);
                    _log.Information("Ollama extraction completed.");
                }
                else
                {
                    _log.Information("Ollama installation is up to date.");
                }

                var exePath = ApplicationSetup.GetOllamaExecutablePath();
                if (!System.IO.File.Exists(exePath))
                {
                    ReportAndLog("Ollama可执行文件丢失，重新解压...");
                    _log.Warning("Ollama executable not found at {Path}, re-extracting.", exePath);
                    await ApplicationSetup.ExtractOllamaAsync(_progress);
                }

                _log.Information("Ollama installation check passed.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "Ollama installation check failed.");
                ReportAndLog($"Ollama 安装检查失败: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> StartOllamaServer()
        {
            try
            {
                if (!OllamaGuardian.StartServer(_progress))
                {
                    ReportAndLog("Ollama 服务启动失败。查看日志获取详情。");
                    _log.Error("OllamaGuardian.StartServer() returned false.");
                    return false;
                }
                _log.Information("Ollama server process started.");

                // 等待服务完全启动
                int retries = 0;
                while (retries < 30) // 最多等待30秒
                {
                    if (OllamaGuardian.IsServerHealthy())
                    {
                        _log.Information("Ollama server is healthy.");
                        return true;
                    }

                    await Task.Delay(1000);
                    retries++;
                    ReportAndLog($"等待 Ollama 服务启动... ({retries}/30)");
                }

                ReportAndLog("Ollama 服务启动超时。");
                _log.Error("Ollama server failed to start within the timeout period.");
                return false;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "An exception occurred while starting Ollama server.");
                ReportAndLog($"Ollama 服务启动时发生异常: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> CheckAndPullDefaultModel()
        {
            try
            {
                using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) }; // 增加超时

                // 检查模型是否已存在
                 _log.Information("Checking for model tags at http://localhost:11434/api/tags");
                var response = await client.GetAsync("http://localhost:11434/api/tags");
                if (!response.IsSuccessStatusCode)
                {
                    var errorContent = await response.Content.ReadAsStringAsync();
                    ReportAndLog("无法连接Ollama服务获取模型列表。");
                    _log.Error("Failed to get model list. Status: {StatusCode}, Content: {Content}", response.StatusCode, errorContent);
                    return false;
                }

                var modelListJson = await response.Content.ReadAsStringAsync();
                _log.Debug("Received model list: {ModelList}", modelListJson);
                
                // 更可靠的JSON解析
                if (!modelListJson.Contains($"\"name\": \"{DEFAULT_MODEL}\""))
                {
                    ReportAndLog($"开始下载/更新默认模型 {DEFAULT_MODEL}...");
                    
                    var pullRequestContent = new StringContent($"{{\"name\": \"{DEFAULT_MODEL}\", \"stream\": false}}", System.Text.Encoding.UTF8, "application/json");
                    
                    var pullResponse = await client.PostAsync("http://localhost:11434/api/pull", pullRequestContent);

                    var responseBody = await pullResponse.Content.ReadAsStringAsync();
                    if (!pullResponse.IsSuccessStatusCode)
                    {
                        ReportAndLog("模型下载失败。请检查网络或查看日志。");
                        _log.Error("Model pull request failed. Status: {StatusCode}, Body: {Body}", pullResponse.StatusCode, responseBody);
                        return false;
                    }
                    _log.Information("Model pull completed. Response: {Body}", responseBody);
                }
                else
                {
                    _log.Information("Default model '{ModelName}' already exists.", DEFAULT_MODEL);
                }

                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "An exception occurred while checking/pulling the default model.");
                ReportAndLog($"模型检查失败: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> ValidateModelAvailability()
        {
            try
            {
                using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
                
                _log.Information("Validating model '{ModelName}' availability.", DEFAULT_MODEL);
                
                var content = new StringContent(
                    $"{{\"model\": \"{DEFAULT_MODEL}\", \"prompt\": \"Hello\", \"stream\": false}}",
                    System.Text.Encoding.UTF8,
                    "application/json"
                );

                var response = await client.PostAsync("http://localhost:11434/api/generate", content);
                var responseBody = await response.Content.ReadAsStringAsync();
                
                if (!response.IsSuccessStatusCode)
                {
                    ReportAndLog("Model validation failed.");
                    _log.Error("Model validation POST failed. Status: {StatusCode}, Body: {Body}", response.StatusCode, responseBody);
                    return false;
                }

                _log.Information("Model validation successful. Response: {Body}", responseBody);
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "An exception occurred during model validation.");
                ReportAndLog($"Model validation failed: {ex.Message}");
                return false;
            }
        }
    }
} 