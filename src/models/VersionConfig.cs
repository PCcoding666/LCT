using System.Text.Json;
using System.IO;
using System.Text.Json;

namespace LiveCaptionsTranslator.Models
{
    /// <summary>
    /// Version management configuration
    /// </summary>
    public class VersionConfig
    {
        /// <summary>
        /// Enable automatic update checking
        /// </summary>
        public bool AutoUpdateEnabled { get; set; } = true;

        /// <summary>
        /// Update check interval in hours
        /// </summary>
        public int UpdateCheckInterval { get; set; } = 24;

        /// <summary>
        /// Primary update server URLs
        /// </summary>
        public List<string> UpdateServerUrls { get; set; } = new()
        {
            "https://api.github.com/repos/PCcoding666/LiveCaptions-Translator/releases",
            "https://update.livecaptions-translator.com/api/releases"
        };

        /// <summary>
        /// Backup update server URLs
        /// </summary>
        public List<string> BackupServerUrls { get; set; } = new()
        {
            "https://mirror1.livecaptions-translator.com/api/releases",
            "https://mirror2.livecaptions-translator.com/api/releases",
            "https://cdn.jsdelivr.net/gh/PCcoding666/LiveCaptions-Translator@latest/releases.json",
            "https://gitee.com/PCcoding666/LiveCaptions-Translator/raw/master/releases.json"
        };

        /// <summary>
        /// Allow pre-release versions
        /// </summary>
        public bool AllowPreReleaseUpdates { get; set; } = false;

        /// <summary>
        /// Offline mode (disable update checks)
        /// </summary>
        public bool OfflineMode { get; set; } = false;

        /// <summary>
        /// Custom download sources for enterprise deployments
        /// Key: Source name, Value: URL pattern with {version} placeholder
        /// </summary>
        public Dictionary<string, string> CustomDownloadSources { get; set; } = new()
        {
            // Example entries for common scenarios
            // "Corporate Mirror": "https://internal-mirror.company.com/releases/{version}/",
            // "CDN Backup": "https://backup-cdn.example.com/livecaptions/{version}/"
        };

        /// <summary>
        /// Download timeout in seconds
        /// </summary>
        public int DownloadTimeoutSeconds { get; set; } = 60;

        /// <summary>
        /// Maximum retry attempts for downloads
        /// </summary>
        public int MaxRetryAttempts { get; set; } = 3;

        /// <summary>
        /// Retry delay in seconds (exponential backoff will be applied)
        /// </summary>
        public int RetryDelaySeconds { get; set; } = 2;

        /// <summary>
        /// Enable incremental updates
        /// </summary>
        public bool IncrementalUpdatesEnabled { get; set; } = true;

        /// <summary>
        /// Enable telemetry and usage statistics
        /// </summary>
        public bool TelemetryEnabled { get; set; } = true;

        /// <summary>
        /// Enable automatic error reporting
        /// </summary>
        public bool ErrorReportingEnabled { get; set; } = true;

        /// <summary>
        /// Last update check timestamp
        /// </summary>
        public DateTime? LastUpdateCheck { get; set; }

        /// <summary>
        /// Skip specific version
        /// </summary>
        public string? SkippedVersion { get; set; }

        /// <summary>
        /// Load version configuration from file
        /// </summary>
        /// <param name="configPath">Configuration file path</param>
        /// <returns>Version configuration</returns>
        public static async Task<VersionConfig> LoadAsync(string configPath)
        {
            try
            {
                if (File.Exists(configPath))
                {
                    var json = await File.ReadAllTextAsync(configPath);
                    var config = JsonSerializer.Deserialize<VersionConfig>(json, new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true,
                        WriteIndented = true
                    });
                    return config ?? new VersionConfig();
                }
            }
            catch (Exception ex)
            {
                // Log error but continue with default config
                Console.WriteLine($"Failed to load version config: {ex.Message}");
            }

            return new VersionConfig();
        }

        /// <summary>
        /// Save version configuration to file
        /// </summary>
        /// <param name="configPath">Configuration file path</param>
        public async Task SaveAsync(string configPath)
        {
            try
            {
                var directory = Path.GetDirectoryName(configPath);
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                var json = JsonSerializer.Serialize(this, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                    WriteIndented = true
                });

                await File.WriteAllTextAsync(configPath, json);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to save version config: {ex.Message}");
                throw;
            }
        }

        /// <summary>
        /// Get effective update server URLs (including custom sources)
        /// URLs are ordered by priority: custom sources, primary servers, backup servers
        /// </summary>
        /// <returns>Ordered list of update URLs</returns>
        public List<string> GetEffectiveUpdateUrls()
        {
            var urls = new List<string>();

            // Add custom sources first (highest priority)
            urls.AddRange(CustomDownloadSources.Values.Where(url => !string.IsNullOrWhiteSpace(url)));

            // Add primary servers
            urls.AddRange(UpdateServerUrls.Where(url => !string.IsNullOrWhiteSpace(url)));

            // Add backup servers
            urls.AddRange(BackupServerUrls.Where(url => !string.IsNullOrWhiteSpace(url)));

            // Remove duplicates while preserving order
            return urls.Distinct().ToList();
        }

        /// <summary>
        /// Get prioritized download URLs for a specific version
        /// </summary>
        /// <param name="version">Target version</param>
        /// <returns>Ordered list of download URLs</returns>
        public List<string> GetDownloadUrls(string version)
        {
            var urls = new List<string>();
            
            // Process custom download sources with version substitution
            foreach (var source in CustomDownloadSources.Values)
            {
                if (!string.IsNullOrWhiteSpace(source))
                {
                    urls.Add(source.Replace("{version}", version));
                }
            }
            
            // Add other URLs as fallbacks
            urls.AddRange(GetEffectiveUpdateUrls());
            
            return urls.Distinct().ToList();
        }

        /// <summary>
        /// Check if it's time for an update check
        /// </summary>
        /// <returns>True if update check should be performed</returns>
        public bool ShouldCheckForUpdates()
        {
            if (OfflineMode || !AutoUpdateEnabled)
                return false;

            if (LastUpdateCheck == null)
                return true;

            return DateTime.Now.Subtract(LastUpdateCheck.Value).TotalHours >= UpdateCheckInterval;
        }

        /// <summary>
        /// Mark update check as completed
        /// </summary>
        public void MarkUpdateCheckCompleted()
        {
            LastUpdateCheck = DateTime.Now;
        }
    }
}