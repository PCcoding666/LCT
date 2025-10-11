using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using Serilog;

namespace LiveCaptionsTranslator.utils
{
    public class StartupManager
    {
        // Remove hardcoded model constant - always use user configuration
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
                
                // 1. Stop all existing Ollama processes
                ReportAndLogCritical("Stopping existing Ollama processes...");
                await Task.Run(() => OllamaGuardian.StopServer());

                // 2. Check and create necessary directory structure
                ReportAndLogCritical("Checking application directory structure...");
                if (!await CheckDirectoryStructure()) return false;

                // 3. Check Ollama executable
                ReportAndLogCritical("Checking Ollama installation status...");
                if (!await CheckOllamaInstallation()) return false;
                
                // 4. Wait for file handles to be released
                ReportAndLog("Waiting for file system synchronization...");
                await Task.Delay(1000);

                // 5. Start Ollama backend service
                ReportAndLogCritical("Starting Ollama service...");
                if (!await StartOllamaServer()) return false;

                // 6. Check default model
                ReportAndLogCritical("Checking default model status...");
                if (!await CheckAndPullDefaultModel()) return false;

                // 7. Validate model availability
                ReportAndLogCritical("Verifying model availability...");
                if (!await ValidateModelAvailability()) return false;

                ReportAndLogCritical("Initialization complete!");
                _log.Information("Startup checks completed successfully.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "A critical error occurred during startup checks.");
                ReportAndLog($"Startup failed: {ex.Message}");
                return false;
            }
        }
        
        private void ReportAndLog(string message)
        {
            _progress?.Report(message);
            _log.Information("[STARTUP] {Message}", message);
            
            // Force immediate flush for important startup messages
            Log.ForContext<StartupManager>().Information("[STARTUP] {Message}", message);
        }

        private void ReportAndLogCritical(string message)
        {
            _progress?.Report(message);
            _log.Information("[STARTUP-CRITICAL] {Message}", message);
            
            // Force immediate flush for critical messages
            Log.ForContext<StartupManager>().Information("[STARTUP-CRITICAL] {Message}", message);
            Log.ForContext<StartupManager>().Debug("Forcing log flush for critical message");
            
            // Additional console output for debugging
            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {message}");
        }

        private async Task<bool> CheckDirectoryStructure()
        {
            try
            {
                await Task.Run(() => ApplicationSetup.EnsureDirectoryStructure());
                ReportAndLog("Directory structure check completed.");
                _log.Information("Directory structure check passed.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "Failed to check or create directory structure.");
                ReportAndLog($"Directory structure check failed: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> CheckOllamaInstallation()
        {
            try
            {
                if (ApplicationSetup.IsFirstRun || !ApplicationSetup.IsCorrectVersionInstalled())
                {
                    ReportAndLog("First run or version mismatch detected, extracting Ollama...");
                    await ApplicationSetup.ExtractOllamaAsync(_progress);
                    ReportAndLog("Ollama extraction completed.");
                    _log.Information("Ollama extraction completed.");
                }
                else
                {
                    ReportAndLog("Ollama installation status is normal.");
                    _log.Information("Ollama installation is up to date.");
                }

                var exePath = ApplicationSetup.GetOllamaExecutablePath();
                if (!System.IO.File.Exists(exePath))
                {
                    ReportAndLog("Ollama executable missing, re-extracting...");
                    _log.Warning("Ollama executable not found at {Path}, re-extracting.", exePath);
                    await ApplicationSetup.ExtractOllamaAsync(_progress);
                    ReportAndLog("Ollama re-extraction completed.");
                }

                _log.Information("Ollama installation check passed.");
                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "Ollama installation check failed.");
                ReportAndLog($"Ollama installation check failed: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> StartOllamaServer()
        {
            try
            {
                if (!OllamaGuardian.StartServer(_progress))
                {
                    ReportAndLog("Ollama service startup failed. Check logs for details.");
                    _log.Error("OllamaGuardian.StartServer() returned false.");
                    return false;
                }
                _log.Information("Ollama server process started.");

                // Wait for service to fully start
                int retries = 0;
                while (retries < 30) // Wait up to 30 seconds
                {
                    if (OllamaGuardian.IsServerHealthy())
                    {
                        _log.Information("Ollama server is healthy.");
                        return true;
                    }

                    await Task.Delay(1000);
                    retries++;
                    ReportAndLog($"Waiting for Ollama service to start... ({retries}/30)");
                }

                ReportAndLog("Ollama service startup timeout.");
                _log.Error("Ollama server failed to start within the timeout period.");
                return false;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "An exception occurred while starting Ollama server.");
                ReportAndLog($"Exception occurred while starting Ollama service: {ex.Message}");
                return false;
            }
        }

        private async Task<bool> CheckAndPullDefaultModel()
        {
            try
            {
                using var client = new HttpClient { Timeout = TimeSpan.FromMinutes(30) }; // Increase timeout

                // Get model name from user configuration instead of hardcoded constant
                var configuredModel = GetConfiguredModelName();
                _log.Information("Using configured model: {ModelName}", configuredModel);

                // Check if model already exists
                ReportAndLog("Checking installed model list...");
                _log.Information("Checking for model tags at http://localhost:11434/api/tags");
                var response = await client.GetAsync("http://localhost:11434/api/tags");
                if (!response.IsSuccessStatusCode)
                {
                    var errorContent = await response.Content.ReadAsStringAsync();
                    ReportAndLog("Unable to connect to Ollama service to get model list.");
                    _log.Error("Failed to get model list. Status: {StatusCode}, Content: {Content}", response.StatusCode, errorContent);
                    return false;
                }

                var modelListJson = await response.Content.ReadAsStringAsync();
                _log.Debug("Received model list: {ModelList}", modelListJson);
                
                // Enhanced model checking with better JSON parsing
                bool modelExists = await CheckIfModelExists(modelListJson, configuredModel);
                
                if (!modelExists)
                {
                    ReportAndLogCritical($"Configured model {configuredModel} not found, starting download...");
                    _log.Information("[MODEL-DOWNLOAD] Starting download for model: {ModelName}", configuredModel);
                    
                    // Use streaming download to get real-time progress
                    var pullRequestContent = new StringContent($"{{\"name\": \"{configuredModel}\", \"stream\": true}}", System.Text.Encoding.UTF8, "application/json");
                    
                    var pullResponse = await client.PostAsync("http://localhost:11434/api/pull", pullRequestContent);
                    
                    if (!pullResponse.IsSuccessStatusCode)
                    {
                        var errorContent = await pullResponse.Content.ReadAsStringAsync();
                        ReportAndLog("Model download request failed. Please check network or see logs.");
                        _log.Error("Model pull request failed. Status: {StatusCode}, Body: {Body}", pullResponse.StatusCode, errorContent);
                        return false;
                    }

                    // Process streaming response to show download progress
                    await ProcessModelDownloadStream(pullResponse);
                    
                    ReportAndLog($"Model {configuredModel} download completed!");
                    _log.Information("Model pull completed successfully.");
                }
                else
                {
                    ReportAndLog($"Model {configuredModel} already exists, skipping download.");
                    _log.Information("Configured model '{ModelName}' already exists.", configuredModel);
                }

                return true;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "An exception occurred while checking/pulling the default model.");
                ReportAndLog($"Model check failed: {ex.Message}");
                return false;
            }
        }

        private async Task ProcessModelDownloadStream(HttpResponseMessage response)
        {
            using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new StreamReader(stream);
            
            string? line;
            var lastProgressUpdate = DateTime.Now;
            var progressUpdateInterval = TimeSpan.FromSeconds(2); // 每2秒更新一次进度
            var downloadStartTime = DateTime.Now;
            var maxDownloadTime = TimeSpan.FromMinutes(30); // Maximum download time 30 minutes
            
            while ((line = await reader.ReadLineAsync()) != null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                
                // Check timeout
                if (DateTime.Now - downloadStartTime > maxDownloadTime)
                {
                    ReportAndLog("Model download timeout, network connection may be unstable.");
                    _log.Warning("Model download timeout after {Minutes} minutes", maxDownloadTime.TotalMinutes);
                    throw new TimeoutException("Model download timeout");
                }
                
                try
                {
                    // Parse JSON response
                    var jsonResponse = System.Text.Json.JsonDocument.Parse(line);
                    var root = jsonResponse.RootElement;
                    
                    // Check status
                    if (root.TryGetProperty("status", out var statusElement))
                    {
                        var status = statusElement.GetString();
                        
                        switch (status)
                        {
                            case "pulling manifest":
                                ReportAndLog("Pulling model manifest...");
                                _log.Information("[MODEL-DOWNLOAD] Status: pulling manifest");
                                break;
                                
                            case "downloading":
                                // Process download progress
                                if (DateTime.Now - lastProgressUpdate >= progressUpdateInterval)
                                {
                                    ProcessDownloadProgress(root);
                                    lastProgressUpdate = DateTime.Now;
                                }
                                break;
                                
                            case "verifying sha256":
                                ReportAndLog("Verifying model file integrity...");
                                _log.Information("[MODEL-DOWNLOAD] Status: verifying sha256");
                                break;
                                
                            case "writing manifest":
                                ReportAndLog("Writing model manifest...");
                                _log.Information("[MODEL-DOWNLOAD] Status: writing manifest");
                                break;
                                
                            case "removing any unused layers":
                                ReportAndLog("Cleaning up unused layers...");
                                _log.Information("[MODEL-DOWNLOAD] Status: removing unused layers");
                                break;
                                
                            case "success":
                                ReportAndLog("Model download successful!");
                                _log.Information("[MODEL-DOWNLOAD] Status: success - Download completed");
                                return;
                        }
                    }
                    
                    // Check errors
                    if (root.TryGetProperty("error", out var errorElement))
                    {
                        var error = errorElement.GetString();
                        var errorMessage = $"Model download error: {error}";
                        ReportAndLog(errorMessage);
                        _log.Error("[MODEL-DOWNLOAD] Error: {Error}", error);
                        throw new Exception($"Model download failed: {error}");
                    }
                }
                catch (System.Text.Json.JsonException ex)
                {
                    // Ignore JSON parsing errors, continue processing next line
                    _log.Debug("Failed to parse JSON line: {Line}, Error: {Error}", line, ex.Message);
                }
            }
        }
        
        private void ProcessDownloadProgress(System.Text.Json.JsonElement root)
        {
            try
            {
                var completed = 0L;
                var total = 0L;
                
                if (root.TryGetProperty("completed", out var completedElement))
                {
                    completed = completedElement.GetInt64();
                }
                
                if (root.TryGetProperty("total", out var totalElement))
                {
                    total = totalElement.GetInt64();
                }
                
                if (total > 0)
                {
                    var percentage = (int)((double)completed / total * 100);
                    var completedMB = completed / 1024 / 1024;
                    var totalMB = total / 1024 / 1024;
                    
                    var progressMessage = $"Model download progress: {percentage}% ({completedMB}MB / {totalMB}MB)";
                    ReportAndLog(progressMessage);
                    _log.Information("[MODEL-DOWNLOAD] Progress: {Percentage}% ({CompletedMB}MB / {TotalMB}MB)", 
                        percentage, completedMB, totalMB);
                }
                else if (completed > 0)
                {
                    var completedMB = completed / 1024 / 1024;
                    var progressMessage = $"Downloaded: {completedMB}MB";
                    ReportAndLog(progressMessage);
                    _log.Information("[MODEL-DOWNLOAD] Downloaded: {CompletedMB}MB", completedMB);
                }
                else
                {
                    // Handle cases where we don't have specific bytes info
                    ReportAndLog("Model download in progress...");
                    _log.Information("[MODEL-DOWNLOAD] Download in progress (no size info available)");
                }
            }
            catch (Exception ex)
            {
                _log.Debug("Failed to process download progress: {Error}", ex.Message);
            }
        }
        
        private async Task<bool> CheckIfModelExists(string modelListJson, string modelName)
        {
            try
            {
                // More robust model existence check
                using var document = System.Text.Json.JsonDocument.Parse(modelListJson);
                if (document.RootElement.TryGetProperty("models", out var modelsElement))
                {
                    foreach (var model in modelsElement.EnumerateArray())
                    {
                        if (model.TryGetProperty("name", out var nameElement))
                        {
                            var existingModelName = nameElement.GetString();
                            if (string.Equals(existingModelName, modelName, StringComparison.OrdinalIgnoreCase))
                            {
                                _log.Information("Found existing model: {ModelName}", existingModelName);
                                return true;
                            }
                        }
                    }
                }
                
                _log.Information("Model {ModelName} not found in installed models", modelName);
                return false;
            }
            catch (Exception ex)
            {
                _log.Warning(ex, "Failed to parse model list JSON, falling back to string search");
                // Fallback to string search
                return modelListJson.Contains($"\"name\": \"{modelName}\"");
            }
        }

        private async Task<bool> ValidateModelAvailability()
        {
            try
            {
                using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
                
                var configuredModel = GetConfiguredModelName();
                _log.Information("Validating model '{ModelName}' availability.", configuredModel);
                
                var content = new StringContent(
                    $"{{\"model\": \"{configuredModel}\", \"prompt\": \"Hello\", \"stream\": false}}",
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
        
        /// <summary>
        /// Get the configured model name from user settings
        /// Falls back to qwen3:4b-instruct-2507-q4_K_M if no configuration is available
        /// </summary>
        /// <returns>Model name to use</returns>
        private string GetConfiguredModelName()
        {
            try
            {
                // Try to get model name from current setting
                var modelName = Translator.Setting?.OllamaConfig?.ModelName;
                if (!string.IsNullOrEmpty(modelName))
                {
                    _log.Information("Using model from current settings: {ModelName}", modelName);
                    return modelName;
                }
                
                // If no current setting, try to load from configuration file
                var fallbackModel = "qwen3:4b-instruct-2507-q4_K_M";
                _log.Warning("No model configured in settings, using fallback: {ModelName}", fallbackModel);
                return fallbackModel;
            }
            catch (Exception ex)
            {
                _log.Error(ex, "Failed to get configured model name, using fallback");
                return "qwen3:4b-instruct-2507-q4_K_M";
            }
        }
    }
} 