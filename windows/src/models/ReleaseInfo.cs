using System.Text.Json.Serialization;

namespace LiveCaptionsTranslator.Models
{
    /// <summary>
    /// Release information from update server
    /// </summary>
    public class ReleaseInfo
    {
        /// <summary>
        /// Release version
        /// </summary>
        [JsonPropertyName("version")]
        public string Version { get; set; } = string.Empty;

        /// <summary>
        /// Release name/title
        /// </summary>
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        /// <summary>
        /// Release description/changelog
        /// </summary>
        [JsonPropertyName("description")]
        public string Description { get; set; } = string.Empty;

        /// <summary>
        /// Release date
        /// </summary>
        [JsonPropertyName("releaseDate")]
        public DateTime ReleaseDate { get; set; }

        /// <summary>
        /// Whether this is a pre-release
        /// </summary>
        [JsonPropertyName("preRelease")]
        public bool PreRelease { get; set; }

        /// <summary>
        /// Download assets
        /// </summary>
        [JsonPropertyName("assets")]
        public List<ReleaseAsset> Assets { get; set; } = new();

        /// <summary>
        /// Minimum system requirements
        /// </summary>
        [JsonPropertyName("requirements")]
        public SystemRequirements? Requirements { get; set; }

        /// <summary>
        /// Critical update (force update)
        /// </summary>
        [JsonPropertyName("critical")]
        public bool Critical { get; set; }

        /// <summary>
        /// Changelog URL
        /// </summary>
        [JsonPropertyName("changelogUrl")]
        public string? ChangelogUrl { get; set; }

        /// <summary>
        /// Get parsed version info
        /// </summary>
        /// <returns>Version information</returns>
        public VersionInfo GetVersionInfo()
        {
            return VersionInfo.Parse(Version);
        }

        /// <summary>
        /// Get installer asset for the current platform
        /// </summary>
        /// <returns>Installer asset or null if not found</returns>
        public ReleaseAsset? GetInstallerAsset()
        {
            // Look for Windows installer (x64)
            return Assets.FirstOrDefault(a => 
                a.Name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) &&
                (a.Name.Contains("setup", StringComparison.OrdinalIgnoreCase) ||
                 a.Name.Contains("installer", StringComparison.OrdinalIgnoreCase)) &&
                a.Name.Contains("x64", StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>
        /// Get incremental update package if available
        /// </summary>
        /// <param name="fromVersion">Current version</param>
        /// <returns>Incremental update asset or null</returns>
        public ReleaseAsset? GetIncrementalUpdateAsset(string fromVersion)
        {
            return Assets.FirstOrDefault(a =>
                a.Name.Contains("incremental", StringComparison.OrdinalIgnoreCase) &&
                a.Name.Contains(fromVersion, StringComparison.OrdinalIgnoreCase) &&
                a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
        }
    }

    /// <summary>
    /// Release asset information
    /// </summary>
    public class ReleaseAsset
    {
        /// <summary>
        /// Asset name
        /// </summary>
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        /// <summary>
        /// Download URL
        /// </summary>
        [JsonPropertyName("downloadUrl")]
        public string DownloadUrl { get; set; } = string.Empty;

        /// <summary>
        /// File size in bytes
        /// </summary>
        [JsonPropertyName("size")]
        public long Size { get; set; }

        /// <summary>
        /// Content type
        /// </summary>
        [JsonPropertyName("contentType")]
        public string ContentType { get; set; } = string.Empty;

        /// <summary>
        /// SHA256 checksum
        /// </summary>
        [JsonPropertyName("checksum")]
        public string? Checksum { get; set; }

        /// <summary>
        /// Mirror download URLs
        /// </summary>
        [JsonPropertyName("mirrors")]
        public List<string> Mirrors { get; set; } = new();

        /// <summary>
        /// Get all available download URLs (primary + mirrors)
        /// </summary>
        /// <returns>List of download URLs</returns>
        public List<string> GetAllDownloadUrls()
        {
            var urls = new List<string> { DownloadUrl };
            urls.AddRange(Mirrors);
            return urls.Where(u => !string.IsNullOrEmpty(u)).ToList();
        }
    }

    /// <summary>
    /// System requirements
    /// </summary>
    public class SystemRequirements
    {
        /// <summary>
        /// Minimum Windows version
        /// </summary>
        [JsonPropertyName("minWindowsVersion")]
        public string? MinWindowsVersion { get; set; }

        /// <summary>
        /// Required .NET version
        /// </summary>
        [JsonPropertyName("dotNetVersion")]
        public string? DotNetVersion { get; set; }

        /// <summary>
        /// Minimum RAM in MB
        /// </summary>
        [JsonPropertyName("minRamMB")]
        public int? MinRamMB { get; set; }

        /// <summary>
        /// Minimum disk space in MB
        /// </summary>
        [JsonPropertyName("minDiskSpaceMB")]
        public int? MinDiskSpaceMB { get; set; }

        /// <summary>
        /// Required CPU architecture
        /// </summary>
        [JsonPropertyName("architecture")]
        public string? Architecture { get; set; }

        /// <summary>
        /// Check if current system meets requirements
        /// </summary>
        /// <returns>True if requirements are met</returns>
        public bool CheckSystemCompatibility()
        {
            // Basic implementation - can be enhanced with actual system checks
            try
            {
                // Check architecture
                if (!string.IsNullOrEmpty(Architecture))
                {
                    var currentArch = Environment.Is64BitOperatingSystem ? "x64" : "x86";
                    if (!Architecture.Contains(currentArch, StringComparison.OrdinalIgnoreCase))
                        return false;
                }

                // Check Windows version (basic)
                if (!string.IsNullOrEmpty(MinWindowsVersion))
                {
                    var osVersion = Environment.OSVersion.Version;
                    // Windows 10 = 10.0, Windows 11 = 10.0.22000+
                    if (osVersion.Major < 10)
                        return false;
                }

                return true;
            }
            catch
            {
                return true; // Assume compatible if checks fail
            }
        }
    }
}