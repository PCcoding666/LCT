using LiveCaptionsTranslator.Models;
using System.Reflection;
using System.Diagnostics;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Application version information service
    /// </summary>
    public static class AppVersionInfo
    {
        private static readonly Lazy<VersionInfo> _versionInfo = new(LoadVersionInfo);
        
        /// <summary>
        /// Get current application version information
        /// </summary>
        public static VersionInfo Current => _versionInfo.Value;
        
        /// <summary>
        /// Get version string for display purposes
        /// </summary>
        public static string DisplayVersion => Current.FullVersion;
        
        /// <summary>
        /// Get short version string (Major.Minor.Patch)
        /// </summary>
        public static string ShortVersion => $\"{Current.Major}.{Current.Minor}.{Current.Patch}\";
        
        /// <summary>
        /// Get build information string
        /// </summary>
        public static string BuildInfo
        {
            get
            {
                var info = new List<string>();
                
                if (!string.IsNullOrEmpty(Current.CommitHash))
                {
                    var shortHash = Current.CommitHash.Length > 7 ? Current.CommitHash[..7] : Current.CommitHash;
                    info.Add($\"Commit: {shortHash}\");
                }
                
                if (!string.IsNullOrEmpty(Current.BranchName))
                {
                    info.Add($\"Branch: {Current.BranchName}\");
                }
                
                info.Add($\"Built: {Current.BuildTimestamp:yyyy-MM-dd HH:mm}\");
                
                if (Current.IsDevelopmentBuild)
                {
                    info.Add(\"DEBUG\");
                }
                
                return string.Join(\" | \", info);
            }
        }
        
        /// <summary>
        /// Get copyright information
        /// </summary>
        public static string Copyright
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var copyrightAttr = assembly.GetCustomAttribute<AssemblyCopyrightAttribute>();
                return copyrightAttr?.Copyright ?? \"Copyright © 2024 SakiRinn and other contributors\";
            }
        }
        
        /// <summary>
        /// Get company information
        /// </summary>
        public static string Company
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var companyAttr = assembly.GetCustomAttribute<AssemblyCompanyAttribute>();
                return companyAttr?.Company ?? \"SakiRinn and Contributors\";
            }
        }
        
        /// <summary>
        /// Get product name
        /// </summary>
        public static string ProductName
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var productAttr = assembly.GetCustomAttribute<AssemblyProductAttribute>();
                return productAttr?.Product ?? \"LiveCaptions Translator\";
            }
        }
        
        /// <summary>
        /// Get application title
        /// </summary>
        public static string Title
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var titleAttr = assembly.GetCustomAttribute<AssemblyTitleAttribute>();
                return titleAttr?.Title ?? \"LiveCaptions Translator\";
            }
        }
        
        /// <summary>
        /// Get application description
        /// </summary>
        public static string Description
        {
            get
            {
                var assembly = Assembly.GetExecutingAssembly();
                var descAttr = assembly.GetCustomAttribute<AssemblyDescriptionAttribute>();
                return descAttr?.Description ?? \"A real-time speech translation tool based on Windows LiveCaptions\";
            }
        }
        
        /// <summary>
        /// Check if this is a development/debug build
        /// </summary>
        public static bool IsDevelopmentBuild => Current.IsDevelopmentBuild;
        
        /// <summary>
        /// Check if this is a pre-release version
        /// </summary>
        public static bool IsPreRelease => !string.IsNullOrEmpty(Current.PreRelease);
        
        /// <summary>
        /// Load version information from assembly
        /// </summary>
        /// <returns>Version information</returns>
        private static VersionInfo LoadVersionInfo()
        {
            var assembly = Assembly.GetExecutingAssembly();
            var fileVersionInfo = FileVersionInfo.GetVersionInfo(assembly.Location);
            
            // Get version from assembly attributes
            var assemblyVersion = assembly.GetName().Version ?? new Version(1, 0, 0, 0);
            var informationalVersion = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? \"1.0.0\";
            
            // Parse informational version to get pre-release and build info
            var versionInfo = VersionInfo.Parse(informationalVersion);
            
            // Override with assembly version numbers if they differ
            versionInfo.Major = assemblyVersion.Major;
            versionInfo.Minor = assemblyVersion.Minor;
            versionInfo.Patch = assemblyVersion.Build >= 0 ? assemblyVersion.Build : 0;
            
            // Get build metadata from assembly metadata attributes
            var commitHash = GetAssemblyMetadata(assembly, \"GitCommitHash\");
            var branchName = GetAssemblyMetadata(assembly, \"GitBranch\");
            var buildTimestampStr = GetAssemblyMetadata(assembly, \"BuildTimestamp\");
            var buildConfig = GetAssemblyMetadata(assembly, \"BuildConfiguration\");
            
            versionInfo.CommitHash = commitHash != \"unknown\" ? commitHash : null;
            versionInfo.BranchName = branchName != \"unknown\" ? branchName : null;
            versionInfo.IsDevelopmentBuild = buildConfig?.ToLowerInvariant() == \"debug\" || IsDebugBuild();
            
            // Parse build timestamp
            if (DateTime.TryParse(buildTimestampStr, out var buildTime))
            {
                versionInfo.BuildTimestamp = buildTime;
            }
            else
            {
                // Fallback to assembly file time
                try
                {
                    var filePath = assembly.Location;
                    if (File.Exists(filePath))
                    {
                        versionInfo.BuildTimestamp = File.GetCreationTimeUtc(filePath);
                    }
                    else
                    {
                        versionInfo.BuildTimestamp = DateTime.UtcNow;
                    }
                }
                catch
                {
                    versionInfo.BuildTimestamp = DateTime.UtcNow;
                }
            }
            
            versionInfo.ReleaseDate = versionInfo.BuildTimestamp;
            
            return versionInfo;
        }
        
        /// <summary>
        /// Get assembly metadata value
        /// </summary>
        /// <param name=\"assembly\">Assembly to check</param>
        /// <param name=\"key\">Metadata key</param>
        /// <returns>Metadata value or null</returns>
        private static string? GetAssemblyMetadata(Assembly assembly, string key)
        {
            var metadata = assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(attr => attr.Key == key);
            return metadata?.Value;
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
        
        /// <summary>
        /// Get full version information as formatted string
        /// </summary>
        /// <returns>Formatted version string</returns>
        public static string GetFullVersionString()
        {
            var lines = new List<string>
            {
                $\"{ProductName} {DisplayVersion}\",
                Description,
                \"\",
                BuildInfo,
                \"\",
                Copyright
            };
            
            return string.Join(Environment.NewLine, lines);
        }
        
        /// <summary>
        /// Log version information
        /// </summary>
        public static void LogVersionInfo()
        {
            Console.WriteLine($\"Application Version: {DisplayVersion}\");
            Console.WriteLine($\"Build Information: {BuildInfo}\");
            Console.WriteLine($\"Development Build: {IsDevelopmentBuild}\");
            Console.WriteLine($\"Pre-release: {IsPreRelease}\");
        }
    }
}"