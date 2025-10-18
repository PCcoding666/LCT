using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Threading.Tasks;
using Serilog;

namespace LiveCaptionsTranslator.utils
{
    public static class ApplicationSetup
    {
        // Application data directory
        public static readonly string AppDataPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DellLiveCaptionsTranslator"
        );

        // Ollama related paths
        public static readonly string OllamaPath = Path.Combine(AppDataPath, "ollama");
        public static readonly string ModelPath = Path.Combine(AppDataPath, "models");
        public static readonly string DownloadsPath = Path.Combine(AppDataPath, "downloads");

        // Expected Ollama version identifier (from filename)
        private const string EXPECTED_OLLAMA_VERSION = "ollama-ipex-llm-2.3.0b20250725-win";

        // Version record filename
        private static readonly string VersionRecordFile = Path.Combine(OllamaPath, ".version");

        /// <summary>
        /// Check if this is the first run
        /// </summary>
        public static bool IsFirstRun => !Directory.Exists(OllamaPath);

        /// <summary>
        /// Check if the currently installed Ollama is the specified version
        /// </summary>
        public static bool IsCorrectVersionInstalled()
        {
            try
            {
                if (!File.Exists(VersionRecordFile))
                    return false;

                var versionString = File.ReadAllText(VersionRecordFile).Trim();
                return string.Equals(versionString, EXPECTED_OLLAMA_VERSION, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        /// <summary>
        /// Ensure application directory structure exists
        /// </summary>
        public static void EnsureDirectoryStructure()
        {
            Directory.CreateDirectory(AppDataPath);
            Directory.CreateDirectory(OllamaPath);
            Directory.CreateDirectory(ModelPath);
            Directory.CreateDirectory(DownloadsPath);
        }

        /// <summary>
        /// Download and extract Ollama
        /// </summary>
        public static async Task ExtractOllamaAsync(IProgress<string>? progress = null)
        {
            var zipPath = Path.Combine(DownloadsPath, "ollama-windows.zip");
            
            try
            {
                // Download Ollama
                ReportProgress(progress, "Preparing to download Ollama engine...");
                var downloader = new OllamaDownloader(progress);
                await downloader.DownloadOllamaAsync(zipPath);

                // Validate download
                ReportProgress(progress, "Download completed, validating file...");
                if (!await downloader.ValidateDownloadAsync(zipPath))
                {
                    throw new Exception("Download file validation failed");
                }
                ReportProgress(progress, "File validation successful.");

                // Extract files
                ReportProgress(progress, "Extracting Ollama...");
                using (var archive = ZipFile.OpenRead(zipPath))
                {
                    archive.ExtractToDirectory(OllamaPath, true);
                }
                ReportProgress(progress, "Extraction completed.");

                // Ensure ollama.exe has execution permissions
                var ollamaExePath = GetOllamaExecutablePath();
                if (!File.Exists(ollamaExePath))
                {
                    throw new FileNotFoundException("Ollama executable not found after extraction.");
                }

                // Write version file for subsequent startup verification
                File.WriteAllText(VersionRecordFile, EXPECTED_OLLAMA_VERSION);

                ReportProgress(progress, "Ollama engine installation completed!");
            }
            catch (HttpRequestException httpEx) when (httpEx.Message.Contains("404"))
            {
                var userFriendlyMessage = "下载链接已失效或不存在。\n\n" +
                    "请尝试以下解决方案：\n" +
                    "1. 检查网络连接是否正常\n" +
                    "2. 稍后重试启动应用\n" +
                    "3. 联系开发者获取最新版本\n\n" +
                    $"技术详情：{httpEx.Message}";
                ReportProgress(progress, userFriendlyMessage);
                throw new ApplicationException(userFriendlyMessage, httpEx);
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"Installation failed: {ex.Message}");
                throw;
            }
            finally
            {
                // Clean up downloaded files
                if (File.Exists(zipPath))
                {
                    try
                    {
                        File.Delete(zipPath);
                    }
                    catch
                    {
                        // Ignore cleanup errors
                    }
                }
            }
        }
        
        /// <summary>
        /// Helper method to report progress and log to file simultaneously
        /// </summary>
        private static void ReportProgress(IProgress<string>? progress, string message)
        {
            progress?.Report(message);
            Log.Information("[SETUP] {Message}", message);
        }

        /// <summary>
        /// Set necessary environment variables
        /// </summary>
        public static void SetupEnvironmentVariables()
        {
            var vars = new Dictionary<string, string>
            {
                { "OLLAMA_NUM_GPU", "1" },
                { "ZES_ENABLE_SYSMAN", "1" },
                { "SYCL_CACHE_PERSISTENT", "1" },
                { "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS", "1" },
                { "OLLAMA_MODELS", ModelPath },
                { "OLLAMA_HOST", "127.0.0.1:11434" }
            };

            foreach (var (key, value) in vars)
            {
                Environment.SetEnvironmentVariable(key, value, EnvironmentVariableTarget.Process);
            }
        }

        /// <summary>
        /// Perform complete first-time setup
        /// </summary>
        public static async Task PerformFirstTimeSetup(IProgress<string>? progress = null)
        {
            try
            {
                ReportProgress(progress, "Creating directory structure...");
                EnsureDirectoryStructure();

                ReportProgress(progress, "Starting download and installation of Ollama...");
                await ExtractOllamaAsync(progress);

                ReportProgress(progress, "Ollama environment setup completed.");
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"First-time setup failed: {ex.Message}");
                throw new ApplicationException("First-time setup failed.", ex);
            }
        }

        /// <summary>
        /// Get the full path to the Ollama executable
        /// </summary>
        public static string GetOllamaExecutablePath()
        {
            return Path.Combine(OllamaPath, "ollama.exe");
        }
    }
} 