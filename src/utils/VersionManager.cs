using LiveCaptionsTranslator.Models;
using Serilog;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Version management and update checking service
    /// </summary>
    public class VersionManager
    {
        private static readonly Lazy<VersionManager> _instance = new(() => new VersionManager());
        public static VersionManager Instance => _instance.Value;

        private readonly HttpClient _httpClient;
        private readonly string _configPath;
        private VersionConfig _config;
        private VersionInfo _currentVersion;

        public event EventHandler<UpdateCheckCompletedEventArgs>? UpdateCheckCompleted;
        public event EventHandler<DownloadProgressEventArgs>? DownloadProgress;

        private VersionManager()
        {
            _httpClient = new HttpClient();
            _httpClient.DefaultRequestHeaders.Add("User-Agent", "LiveCaptions-Translator");
            
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDataDirectory = Path.Combine(appDataPath, "LiveCaptions-Translator");
            _configPath = Path.Combine(appDataDirectory, "version-config.json");
            
            _config = new VersionConfig();
            _currentVersion = VersionInfo.FromCurrentAssembly();
        }

        /// <summary>
        /// Initialize version manager
        /// </summary>
        public async Task InitializeAsync()
        {
            try
            {
                _config = await VersionConfig.LoadAsync(_configPath);
                Log.Information("Version manager initialized. Current version: {Version}", _currentVersion.FullVersion);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to initialize version manager");
            }
        }

        /// <summary>
        /// Get current application version
        /// </summary>
        /// <returns>Current version info</returns>
        public VersionInfo GetCurrentVersion()
        {
            return _currentVersion;
        }

        /// <summary>
        /// Get version configuration
        /// </summary>
        /// <returns>Version configuration</returns>
        public VersionConfig GetConfig()
        {
            return _config;
        }

        /// <summary>
        /// Update version configuration
        /// </summary>
        /// <param name="config">New configuration</param>
        public async Task UpdateConfigAsync(VersionConfig config)
        {
            _config = config;
            await _config.SaveAsync(_configPath);
            Log.Information("Version configuration updated");
        }

        /// <summary>
        /// Check for updates asynchronously
        /// </summary>
        public async Task CheckForUpdatesAsync()
        {
            if (!_config.ShouldCheckForUpdates())
            {
                Log.Debug("Skipping update check - not yet time or disabled");
                return;
            }

            Log.Information("Checking for updates...");

            try
            {
                var latestRelease = await GetLatestReleaseAsync();
                _config.MarkUpdateCheckCompleted();
                await _config.SaveAsync(_configPath);

                var updateAvailable = false;
                var isNewer = false;

                if (latestRelease != null)
                {
                    var latestVersion = latestRelease.GetVersionInfo();
                    isNewer = latestVersion.IsNewerThan(_currentVersion);
                    
                    // Check if we should consider this update
                    updateAvailable = isNewer && 
                                     (latestRelease.Version != _config.SkippedVersion) &&
                                     (!latestRelease.PreRelease || _config.AllowPreReleaseUpdates);
                }

                UpdateCheckCompleted?.Invoke(this, new UpdateCheckCompletedEventArgs
                {
                    UpdateAvailable = updateAvailable,
                    LatestRelease = latestRelease,
                    IsNewer = isNewer
                });

                Log.Information("Update check completed. Update available: {Available}", updateAvailable);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to check for updates");
                UpdateCheckCompleted?.Invoke(this, new UpdateCheckCompletedEventArgs
                {
                    UpdateAvailable = false,
                    Error = ex.Message
                });
            }
        }

        /// <summary>
        /// Get latest release information
        /// </summary>
        /// <returns>Latest release info or null if not found</returns>
        public async Task<ReleaseInfo?> GetLatestReleaseAsync()
        {
            var urls = _config.GetEffectiveUpdateUrls();
            
            foreach (var url in urls)
            {
                try
                {
                    Log.Debug("Checking for updates from: {Url}", url);
                    
                    using var response = await _httpClient.GetAsync(url);
                    if (response.IsSuccessStatusCode)
                    {
                        var json = await response.Content.ReadAsStringAsync();
                        
                        // Handle GitHub API response format
                        if (url.Contains("github.com"))
                        {
                            var githubReleases = JsonSerializer.Deserialize<List<GitHubRelease>>(json);
                            var latestRelease = githubReleases?.FirstOrDefault(r => !r.Draft);
                            if (latestRelease != null)
                            {
                                return ConvertFromGitHubRelease(latestRelease);
                            }
                        }
                        else
                        {
                            // Custom API format
                            var release = JsonSerializer.Deserialize<ReleaseInfo>(json);
                            if (release != null)
                            {
                                return release;
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Log.Warning(ex, "Failed to check updates from {Url}", url);
                    continue;
                }
            }

            return null;
        }

        /// <summary>
        /// Download and install update
        /// </summary>
        /// <param name="release">Release to install</param>
        /// <param name="useIncremental">Whether to use incremental update if available</param>
        public async Task<bool> DownloadAndInstallUpdateAsync(ReleaseInfo release, bool useIncremental = true)
        {
            try
            {
                Log.Information("Starting download for version {Version}", release.Version);

                ReleaseAsset? asset = null;
                
                // Try incremental update first
                if (useIncremental && _config.IncrementalUpdatesEnabled)
                {
                    asset = release.GetIncrementalUpdateAsset(_currentVersion.FullVersion);
                    if (asset != null)
                    {
                        Log.Information("Using incremental update package");
                    }
                }

                // Fall back to full installer
                if (asset == null)
                {
                    asset = release.GetInstallerAsset();
                    if (asset == null)
                    {
                        Log.Error("No suitable installer found for this platform");
                        return false;
                    }
                    Log.Information("Using full installer package");
                }

                var downloadPath = await DownloadAssetAsync(asset);
                if (string.IsNullOrEmpty(downloadPath))
                {
                    return false;
                }

                // Verify checksum if available
                if (!string.IsNullOrEmpty(asset.Checksum))
                {
                    if (!await VerifyChecksumAsync(downloadPath, asset.Checksum))
                    {
                        Log.Error("Checksum verification failed");
                        File.Delete(downloadPath);
                        return false;
                    }
                }

                // Install update
                return await InstallUpdateAsync(downloadPath, asset.Name.Contains("incremental"));
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to download and install update");
                return false;
            }
        }

        /// <summary>
        /// Skip a specific version
        /// </summary>
        /// <param name="version">Version to skip</param>
        public async Task SkipVersionAsync(string version)
        {
            _config.SkippedVersion = version;
            await _config.SaveAsync(_configPath);
            Log.Information("Version {Version} skipped", version);
        }

        /// <summary>
        /// Download asset with progress reporting
        /// </summary>
        /// <param name="asset">Asset to download</param>
        /// <returns>Downloaded file path or null on failure</returns>
        private async Task<string?> DownloadAssetAsync(ReleaseAsset asset)
        {
            var tempDir = Path.GetTempPath();
            var downloadPath = Path.Combine(tempDir, asset.Name);
            
            var urls = asset.GetAllDownloadUrls();
            
            foreach (var url in urls)
            {
                try
                {
                    Log.Information("Downloading from: {Url}", url);
                    
                    using var response = await _httpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
                    response.EnsureSuccessStatusCode();
                    
                    var totalBytes = response.Content.Headers.ContentLength ?? 0;
                    var downloadedBytes = 0L;
                    
                    using var stream = await response.Content.ReadAsStreamAsync();
                    using var fileStream = File.Create(downloadPath);
                    
                    var buffer = new byte[8192];
                    int bytesRead;
                    
                    while ((bytesRead = await stream.ReadAsync(buffer, 0, buffer.Length)) > 0)
                    {
                        await fileStream.WriteAsync(buffer, 0, bytesRead);
                        downloadedBytes += bytesRead;
                        
                        DownloadProgress?.Invoke(this, new DownloadProgressEventArgs
                        {
                            DownloadedBytes = downloadedBytes,
                            TotalBytes = totalBytes,
                            ProgressPercentage = totalBytes > 0 ? (double)downloadedBytes / totalBytes * 100 : 0
                        });
                    }
                    
                    Log.Information("Download completed: {Path}", downloadPath);
                    return downloadPath;
                }
                catch (Exception ex)
                {
                    Log.Warning(ex, "Failed to download from {Url}", url);
                    if (File.Exists(downloadPath))
                    {
                        File.Delete(downloadPath);
                    }
                    continue;
                }
            }
            
            return null;
        }

        /// <summary>
        /// Verify file checksum
        /// </summary>
        /// <param name="filePath">File to verify</param>
        /// <param name="expectedChecksum">Expected SHA256 checksum</param>
        /// <returns>True if checksum matches</returns>
        private async Task<bool> VerifyChecksumAsync(string filePath, string expectedChecksum)
        {
            try
            {
                using var sha256 = SHA256.Create();
                using var stream = File.OpenRead(filePath);
                var hash = await sha256.ComputeHashAsync(stream);
                var actualChecksum = Convert.ToHexString(hash);
                
                return string.Equals(actualChecksum, expectedChecksum, StringComparison.OrdinalIgnoreCase);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to verify checksum for {FilePath}", filePath);
                return false;
            }
        }

        /// <summary>
        /// Install update
        /// </summary>
        /// <param name="installerPath">Path to installer</param>
        /// <param name="isIncremental">Whether this is an incremental update</param>
        /// <returns>True if installation started successfully</returns>
        private async Task<bool> InstallUpdateAsync(string installerPath, bool isIncremental)
        {
            try
            {
                if (isIncremental)
                {
                    // Handle incremental update (extract and apply patches)
                    return await ApplyIncrementalUpdateAsync(installerPath);
                }
                else
                {
                    // Run full installer
                    var startInfo = new ProcessStartInfo
                    {
                        FileName = installerPath,
                        Arguments = "/S", // Silent install
                        UseShellExecute = true,
                        Verb = "runas" // Run as administrator
                    };
                    
                    Process.Start(startInfo);
                    Log.Information("Update installer launched: {Path}", installerPath);
                    
                    // Exit current application to allow installer to replace files
                    await Task.Delay(2000); // Give installer time to start
                    Environment.Exit(0);
                    
                    return true;
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to install update");
                return false;
            }
        }

        /// <summary>
        /// Apply incremental update
        /// </summary>
        /// <param name="updatePackagePath">Path to incremental update package</param>
        /// <returns>True if update applied successfully</returns>
        private async Task<bool> ApplyIncrementalUpdateAsync(string updatePackagePath)
        {
            // Implementation would involve:
            // 1. Extract update package
            // 2. Apply file patches/replacements
            // 3. Update version information
            // 4. Restart application
            
            // For now, just log that this feature needs implementation
            Log.Information("Incremental update feature needs implementation");
            return false;
        }

        /// <summary>
        /// Convert GitHub release to our format
        /// </summary>
        /// <param name="githubRelease">GitHub release</param>
        /// <returns>Release info</returns>
        private ReleaseInfo ConvertFromGitHubRelease(GitHubRelease githubRelease)
        {
            return new ReleaseInfo
            {
                Version = githubRelease.TagName.TrimStart('v'),
                Name = githubRelease.Name,
                Description = githubRelease.Body,
                ReleaseDate = githubRelease.PublishedAt,
                PreRelease = githubRelease.PreRelease,
                Assets = githubRelease.Assets.Select(a => new ReleaseAsset
                {
                    Name = a.Name,
                    DownloadUrl = a.BrowserDownloadUrl,
                    Size = a.Size,
                    ContentType = a.ContentType
                }).ToList()
            };
        }

        public void Dispose()
        {
            _httpClient?.Dispose();
        }
    }

    /// <summary>
    /// Update check completed event arguments
    /// </summary>
    public class UpdateCheckCompletedEventArgs : EventArgs
    {
        public bool UpdateAvailable { get; set; }
        public ReleaseInfo? LatestRelease { get; set; }
        public bool IsNewer { get; set; }
        public string? Error { get; set; }
    }

    /// <summary>
    /// Download progress event arguments
    /// </summary>
    public class DownloadProgressEventArgs : EventArgs
    {
        public long DownloadedBytes { get; set; }
        public long TotalBytes { get; set; }
        public double ProgressPercentage { get; set; }
    }

    // GitHub API response models
    internal class GitHubRelease
    {
        [JsonPropertyName("tag_name")]
        public string TagName { get; set; } = string.Empty;

        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("body")]
        public string Body { get; set; } = string.Empty;

        [JsonPropertyName("published_at")]
        public DateTime PublishedAt { get; set; }

        [JsonPropertyName("prerelease")]
        public bool PreRelease { get; set; }

        [JsonPropertyName("draft")]
        public bool Draft { get; set; }

        [JsonPropertyName("assets")]
        public List<GitHubAsset> Assets { get; set; } = new();
    }

    internal class GitHubAsset
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("browser_download_url")]
        public string BrowserDownloadUrl { get; set; } = string.Empty;

        [JsonPropertyName("size")]
        public long Size { get; set; }

        [JsonPropertyName("content_type")]
        public string ContentType { get; set; } = string.Empty;
    }
}