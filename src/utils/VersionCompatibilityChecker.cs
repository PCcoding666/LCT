using LiveCaptionsTranslator.Models;
using Serilog;
using System.Text.Json;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Version compatibility checker and manager
    /// </summary>
    public class VersionCompatibilityChecker
    {
        private static readonly Lazy<VersionCompatibilityChecker> _instance = new(() => new VersionCompatibilityChecker());
        public static VersionCompatibilityChecker Instance => _instance.Value;

        private readonly List<CompatibilityRule> _compatibilityRules;
        private readonly string _compatibilityConfigPath;

        private VersionCompatibilityChecker()
        {
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDataDirectory = Path.Combine(appDataPath, \"LiveCaptions-Translator\");
            _compatibilityConfigPath = Path.Combine(appDataDirectory, \"compatibility-rules.json\");
            
            _compatibilityRules = new List<CompatibilityRule>
            {
                // Define built-in compatibility rules
                new CompatibilityRule
                {
                    FromVersion = \"1.0.0\",
                    ToVersion = \"1.1.0\",
                    CompatibilityLevel = CompatibilityLevel.FullyCompatible,
                    RequiredActions = new List<string>()
                },
                new CompatibilityRule
                {
                    FromVersion = \"1.1.0\",
                    ToVersion = \"1.2.0\",
                    CompatibilityLevel = CompatibilityLevel.FullyCompatible,
                    RequiredActions = new List<string> { \"Settings migration required\" }
                },
                new CompatibilityRule
                {
                    FromVersion = \"1.0.0\",
                    ToVersion = \"2.0.0\",
                    CompatibilityLevel = CompatibilityLevel.MajorBreaking,
                    RequiredActions = new List<string> 
                    { 
                        \"Full data migration required\",
                        \"Settings will be reset to defaults\",
                        \"Translation history format updated\"
                    }
                }
            };
        }

        /// <summary>
        /// Check compatibility between two versions
        /// </summary>
        /// <param name=\"fromVersion\">Source version</param>
        /// <param name=\"toVersion\">Target version</param>
        /// <returns>Compatibility result</returns>
        public CompatibilityResult CheckCompatibility(VersionInfo fromVersion, VersionInfo toVersion)
        {
            try
            {
                Log.Information(\"Checking compatibility from {From} to {To}\", fromVersion.FullVersion, toVersion.FullVersion);
                
                // Same version - fully compatible
                if (fromVersion.CompareTo(toVersion) == 0)
                {
                    return new CompatibilityResult
                    {
                        CompatibilityLevel = CompatibilityLevel.FullyCompatible,
                        RequiredActions = new List<string>(),
                        CanAutoMigrate = true,
                        Warnings = new List<string>(),
                        BlockingIssues = new List<string>()
                    };
                }
                
                // Downgrade - potentially incompatible
                if (fromVersion.CompareTo(toVersion) > 0)
                {
                    return new CompatibilityResult
                    {
                        CompatibilityLevel = CompatibilityLevel.Incompatible,
                        RequiredActions = new List<string> { \"Downgrade not supported\" },
                        CanAutoMigrate = false,
                        Warnings = new List<string> { \"Data loss may occur when downgrading\" },
                        BlockingIssues = new List<string> { \"Application version is newer than target version\" }
                    };
                }
                
                // Find applicable compatibility rule
                var rule = FindCompatibilityRule(fromVersion, toVersion);
                
                if (rule != null)
                {
                    return CreateCompatibilityResult(rule, fromVersion, toVersion);
                }
                
                // No specific rule found, determine based on version semantics
                return DetermineCompatibilityFromVersions(fromVersion, toVersion);
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to check compatibility\");
                
                return new CompatibilityResult
                {
                    CompatibilityLevel = CompatibilityLevel.Unknown,
                    RequiredActions = new List<string> { \"Compatibility check failed\" },
                    CanAutoMigrate = false,
                    Warnings = new List<string> { $\"Error during compatibility check: {ex.Message}\" },
                    BlockingIssues = new List<string> { \"Unable to determine compatibility\" }
                };
            }
        }

        /// <summary>
        /// Check if a specific version is supported
        /// </summary>
        /// <param name=\"version\">Version to check</param>
        /// <returns>True if supported</returns>
        public bool IsVersionSupported(VersionInfo version)
        {
            // Define minimum supported version
            var minimumSupportedVersion = VersionInfo.Parse(\"1.0.0\");
            
            return version.CompareTo(minimumSupportedVersion) >= 0;
        }

        /// <summary>
        /// Get supported version range
        /// </summary>
        /// <returns>Version range information</returns>
        public VersionRange GetSupportedVersionRange()
        {
            return new VersionRange
            {
                MinimumVersion = \"1.0.0\",
                MaximumVersion = null, // No maximum limit
                RecommendedVersion = AppVersionInfo.Current.FullVersion
            };
        }

        /// <summary>
        /// Validate system requirements for a specific version
        /// </summary>
        /// <param name=\"version\">Version to validate</param>
        /// <returns>System requirements validation result</returns>
        public SystemRequirementsResult ValidateSystemRequirements(VersionInfo version)
        {
            var result = new SystemRequirementsResult
            {
                IsSupported = true,
                Issues = new List<string>(),
                Warnings = new List<string>()
            };
            
            try
            {
                // Check Windows version
                var osVersion = Environment.OSVersion.Version;
                if (osVersion.Major < 10)
                {
                    result.IsSupported = false;
                    result.Issues.Add(\"Windows 10 or later is required\");
                }
                
                // Check .NET runtime
                var dotnetVersion = Environment.Version;
                if (dotnetVersion.Major < 8)
                {
                    result.IsSupported = false;
                    result.Issues.Add(\".NET 8.0 runtime or later is required\");
                }
                
                // Check architecture
                if (!Environment.Is64BitOperatingSystem)
                {
                    result.Warnings.Add(\"64-bit operating system is recommended for optimal performance\");
                }
                
                // Check available disk space (approximate)
                var drives = DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType == DriveType.Fixed);
                var systemDrive = drives.FirstOrDefault(d => d.Name.StartsWith(\"C:\"));
                
                if (systemDrive != null)
                {
                    var availableSpaceGB = systemDrive.AvailableFreeSpace / (1024.0 * 1024.0 * 1024.0);
                    if (availableSpaceGB < 0.5) // 500 MB minimum
                    {
                        result.IsSupported = false;
                        result.Issues.Add(\"Insufficient disk space (minimum 500 MB required)\");
                    }
                    else if (availableSpaceGB < 1.0) // 1 GB recommended
                    {
                        result.Warnings.Add(\"Low disk space detected (1 GB recommended)\");
                    }
                }
                
                Log.Information(\"System requirements validation completed. Supported: {Supported}, Issues: {Issues}\", 
                    result.IsSupported, result.Issues.Count);
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to validate system requirements\");
                result.Warnings.Add(\"Unable to fully validate system requirements\");
            }
            
            return result;
        }

        /// <summary>
        /// Load compatibility rules from configuration
        /// </summary>
        public async Task LoadCompatibilityRulesAsync()
        {
            try
            {
                if (File.Exists(_compatibilityConfigPath))
                {
                    var json = await File.ReadAllTextAsync(_compatibilityConfigPath);
                    var rules = JsonSerializer.Deserialize<List<CompatibilityRule>>(json, new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                    
                    if (rules != null)
                    {
                        _compatibilityRules.Clear();
                        _compatibilityRules.AddRange(rules);
                        Log.Information(\"Loaded {Count} compatibility rules from configuration\", rules.Count);
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to load compatibility rules from configuration\");
            }
        }

        /// <summary>
        /// Save compatibility rules to configuration
        /// </summary>
        public async Task SaveCompatibilityRulesAsync()
        {
            try
            {
                var directory = Path.GetDirectoryName(_compatibilityConfigPath);
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                
                var json = JsonSerializer.Serialize(_compatibilityRules, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                
                await File.WriteAllTextAsync(_compatibilityConfigPath, json);
                Log.Information(\"Saved {Count} compatibility rules to configuration\", _compatibilityRules.Count);
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to save compatibility rules\");
            }
        }

        /// <summary>
        /// Find applicable compatibility rule
        /// </summary>
        private CompatibilityRule? FindCompatibilityRule(VersionInfo fromVersion, VersionInfo toVersion)
        {
            return _compatibilityRules.FirstOrDefault(rule =>
            {
                var ruleFromVersion = VersionInfo.Parse(rule.FromVersion);
                var ruleToVersion = VersionInfo.Parse(rule.ToVersion);
                
                return fromVersion.CompareTo(ruleFromVersion) >= 0 && 
                       toVersion.CompareTo(ruleToVersion) <= 0;
            });
        }

        /// <summary>
        /// Create compatibility result from rule
        /// </summary>
        private CompatibilityResult CreateCompatibilityResult(CompatibilityRule rule, VersionInfo fromVersion, VersionInfo toVersion)
        {
            var result = new CompatibilityResult
            {
                CompatibilityLevel = rule.CompatibilityLevel,
                RequiredActions = new List<string>(rule.RequiredActions),
                CanAutoMigrate = rule.CompatibilityLevel != CompatibilityLevel.Incompatible && rule.CompatibilityLevel != CompatibilityLevel.MajorBreaking,
                Warnings = new List<string>(),
                BlockingIssues = new List<string>()
            };
            
            // Add warnings based on compatibility level
            switch (rule.CompatibilityLevel)
            {
                case CompatibilityLevel.MinorBreaking:
                    result.Warnings.Add(\"Some settings may need to be reconfigured\");
                    break;
                case CompatibilityLevel.MajorBreaking:
                    result.Warnings.Add(\"Significant changes detected - review settings after update\");
                    result.BlockingIssues.Add(\"Manual intervention may be required\");
                    break;
                case CompatibilityLevel.Incompatible:
                    result.BlockingIssues.Add(\"Versions are incompatible\");
                    break;
            }
            
            return result;
        }

        /// <summary>
        /// Determine compatibility based on semantic versioning
        /// </summary>
        private CompatibilityResult DetermineCompatibilityFromVersions(VersionInfo fromVersion, VersionInfo toVersion)
        {
            var result = new CompatibilityResult
            {
                RequiredActions = new List<string>(),
                Warnings = new List<string>(),
                BlockingIssues = new List<string>()
            };
            
            // Major version change
            if (toVersion.Major > fromVersion.Major)
            {
                result.CompatibilityLevel = CompatibilityLevel.MajorBreaking;
                result.RequiredActions.Add(\"Major version upgrade detected\");
                result.Warnings.Add(\"Breaking changes expected\");
                result.CanAutoMigrate = false;
            }
            // Minor version change
            else if (toVersion.Minor > fromVersion.Minor)
            {
                result.CompatibilityLevel = CompatibilityLevel.FullyCompatible;
                result.RequiredActions.Add(\"Minor version upgrade - new features available\");
                result.CanAutoMigrate = true;
            }
            // Patch version change
            else if (toVersion.Patch > fromVersion.Patch)
            {
                result.CompatibilityLevel = CompatibilityLevel.FullyCompatible;
                result.RequiredActions.Add(\"Patch version upgrade - bug fixes included\");
                result.CanAutoMigrate = true;
            }
            else
            {
                result.CompatibilityLevel = CompatibilityLevel.FullyCompatible;
                result.CanAutoMigrate = true;
            }
            
            return result;
        }
    }

    /// <summary>
    /// Compatibility levels
    /// </summary>
    public enum CompatibilityLevel
    {
        Unknown,
        FullyCompatible,
        MinorBreaking,
        MajorBreaking,
        Incompatible
    }

    /// <summary>
    /// Compatibility rule definition
    /// </summary>
    public class CompatibilityRule
    {
        public required string FromVersion { get; set; }
        public required string ToVersion { get; set; }
        public CompatibilityLevel CompatibilityLevel { get; set; }
        public List<string> RequiredActions { get; set; } = new();
    }

    /// <summary>
    /// Compatibility check result
    /// </summary>
    public class CompatibilityResult
    {
        public CompatibilityLevel CompatibilityLevel { get; set; }
        public List<string> RequiredActions { get; set; } = new();
        public bool CanAutoMigrate { get; set; }
        public List<string> Warnings { get; set; } = new();
        public List<string> BlockingIssues { get; set; } = new();
    }

    /// <summary>
    /// Version range information
    /// </summary>
    public class VersionRange
    {
        public required string MinimumVersion { get; set; }
        public string? MaximumVersion { get; set; }
        public required string RecommendedVersion { get; set; }
    }

    /// <summary>
    /// System requirements validation result
    /// </summary>
    public class SystemRequirementsResult
    {
        public bool IsSupported { get; set; }
        public List<string> Issues { get; set; } = new();
        public List<string> Warnings { get; set; } = new();
    }
}"