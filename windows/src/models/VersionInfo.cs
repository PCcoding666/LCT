using System.Diagnostics;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json.Serialization;

namespace LiveCaptionsTranslator.Models
{
    /// <summary>
    /// Version information container for the application
    /// </summary>
    public class VersionInfo
    {
        /// <summary>
        /// Major version number (breaking changes)
        /// </summary>
        public int Major { get; set; }

        /// <summary>
        /// Minor version number (new features)
        /// </summary>
        public int Minor { get; set; }

        /// <summary>
        /// Patch version number (bug fixes)
        /// </summary>
        public int Patch { get; set; }

        /// <summary>
        /// Pre-release identifier (alpha, beta, rc)
        /// </summary>
        public string? PreRelease { get; set; }

        /// <summary>
        /// Build metadata
        /// </summary>
        public string? Build { get; set; }

        /// <summary>
        /// Full version string following semantic versioning
        /// </summary>
        [JsonIgnore]
        public string FullVersion
        {
            get
            {
                var version = $"{Major}.{Minor}.{Patch}";
                if (!string.IsNullOrEmpty(PreRelease))
                {
                    version += $"-{PreRelease}";
                }
                if (!string.IsNullOrEmpty(Build))
                {
                    version += $"+{Build}";
                }
                return version;
            }
        }

        /// <summary>
        /// Release date
        /// </summary>
        public DateTime ReleaseDate { get; set; }

        /// <summary>
        /// Git commit hash
        /// </summary>
        public string? CommitHash { get; set; }

        /// <summary>
        /// Git branch name
        /// </summary>
        public string? BranchName { get; set; }

        /// <summary>
        /// Build timestamp
        /// </summary>
        public DateTime BuildTimestamp { get; set; }

        /// <summary>
        /// Whether this is a development build
        /// </summary>
        public bool IsDevelopmentBuild { get; set; }

        /// <summary>
        /// Create version info from current assembly
        /// </summary>
        /// <returns>Version information</returns>
        public static VersionInfo FromCurrentAssembly()
        {
            var assembly = Assembly.GetExecutingAssembly();
            var fileVersionInfo = FileVersionInfo.GetVersionInfo(assembly.Location);
            var assemblyVersion = assembly.GetName().Version ?? new Version(1, 0, 0);
            
            return new VersionInfo
            {
                Major = assemblyVersion.Major,
                Minor = assemblyVersion.Minor,
                Patch = assemblyVersion.Build >= 0 ? assemblyVersion.Build : 0,
                ReleaseDate = DateTime.Now,
                BuildTimestamp = GetLinkerTime(assembly),
                IsDevelopmentBuild = IsDebugBuild()
            };
        }

        /// <summary>
        /// Parse version string to VersionInfo
        /// </summary>
        /// <param name="versionString">Version string (e.g., "1.2.3-beta.1+20241201.1")</param>
        /// <returns>Parsed version info</returns>
        public static VersionInfo Parse(string versionString)
        {
            var version = new VersionInfo();
            
            // Split build metadata
            var buildSplit = versionString.Split('+');
            var mainVersion = buildSplit[0];
            version.Build = buildSplit.Length > 1 ? buildSplit[1] : null;
            
            // Split pre-release
            var preReleaseSplit = mainVersion.Split('-');
            var coreVersion = preReleaseSplit[0];
            version.PreRelease = preReleaseSplit.Length > 1 ? preReleaseSplit[1] : null;
            
            // Parse core version
            var versionParts = coreVersion.Split('.');
            if (versionParts.Length >= 1) version.Major = int.Parse(versionParts[0]);
            if (versionParts.Length >= 2) version.Minor = int.Parse(versionParts[1]);
            if (versionParts.Length >= 3) version.Patch = int.Parse(versionParts[2]);
            
            return version;
        }

        /// <summary>
        /// Compare two versions
        /// </summary>
        /// <param name="other">Other version to compare</param>
        /// <returns>Comparison result</returns>
        public int CompareTo(VersionInfo? other)
        {
            if (other == null) return 1;
            
            var majorCompare = Major.CompareTo(other.Major);
            if (majorCompare != 0) return majorCompare;
            
            var minorCompare = Minor.CompareTo(other.Minor);
            if (minorCompare != 0) return minorCompare;
            
            var patchCompare = Patch.CompareTo(other.Patch);
            if (patchCompare != 0) return patchCompare;
            
            // Handle pre-release comparison
            if (string.IsNullOrEmpty(PreRelease) && !string.IsNullOrEmpty(other.PreRelease))
                return 1; // Release > Pre-release
            if (!string.IsNullOrEmpty(PreRelease) && string.IsNullOrEmpty(other.PreRelease))
                return -1; // Pre-release < Release
            
            return string.Compare(PreRelease, other.PreRelease, StringComparison.Ordinal);
        }

        /// <summary>
        /// Check if this version is newer than another
        /// </summary>
        /// <param name="other">Other version</param>
        /// <returns>True if this version is newer</returns>
        public bool IsNewerThan(VersionInfo? other)
        {
            return CompareTo(other) > 0;
        }

        /// <summary>
        /// Get the build timestamp from assembly linker time
        /// </summary>
        /// <param name="assembly">Assembly to check</param>
        /// <returns>Build timestamp</returns>
        private static DateTime GetLinkerTime(Assembly assembly)
        {
            const string BuildVersionMetadataPrefix = "+build";
            var attribute = assembly.GetCustomAttribute<AssemblyMetadataAttribute>();
            if (attribute != null && attribute.Key.StartsWith(BuildVersionMetadataPrefix))
            {
                if (DateTime.TryParse(attribute.Value, out var buildTime))
                    return buildTime;
            }
            
            // Fallback to file creation time
            var filePath = assembly.Location;
            if (File.Exists(filePath))
            {
                return File.GetCreationTime(filePath);
            }
            
            return DateTime.Now;
        }

        /// <summary>
        /// Check if this is a debug build
        /// </summary>
        /// <returns>True if debug build</returns>
        private static bool IsDebugBuild()
        {
#if DEBUG
            return true;
#else
            return false;
#endif
        }

        public override string ToString()
        {
            return FullVersion;
        }
    }
}