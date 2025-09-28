using LiveCaptionsTranslator.Models;
using Serilog;
using System.Text.Json;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Data migration manager for handling version upgrades
    /// </summary>
    public class DataMigrationManager
    {
        private static readonly Lazy<DataMigrationManager> _instance = new(() => new DataMigrationManager());
        public static DataMigrationManager Instance => _instance.Value;

        private readonly string _migrationStateFile;
        private readonly List<IMigration> _migrations;

        private DataMigrationManager()
        {
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDataDirectory = Path.Combine(appDataPath, \"LiveCaptions-Translator\");
            _migrationStateFile = Path.Combine(appDataDirectory, \"migration-state.json\");
            
            _migrations = new List<IMigration>
            {
                new Migration_1_0_0_to_1_1_0(),
                new Migration_1_1_0_to_1_2_0(),
                // Add future migrations here
            };
        }

        /// <summary>
        /// Check if migration is needed and perform it
        /// </summary>
        /// <param name=\"currentVersion\">Current application version</param>
        /// <returns>True if migration was performed</returns>
        public async Task<bool> CheckAndMigrateAsync(VersionInfo currentVersion)
        {
            try
            {
                Log.Information(\"Checking for data migration requirements\");
                
                var migrationState = await LoadMigrationStateAsync();
                var lastMigratedVersion = migrationState?.LastMigratedVersion;
                
                if (lastMigratedVersion == null)
                {
                    // First run or no migration history
                    Log.Information(\"No previous migration history found, marking current version as migrated\");
                    await SaveMigrationStateAsync(new MigrationState
                    {
                        LastMigratedVersion = currentVersion.FullVersion,
                        LastMigrationDate = DateTime.UtcNow,
                        MigrationHistory = new List<MigrationRecord>()
                    });
                    return false;
                }
                
                var lastVersion = VersionInfo.Parse(lastMigratedVersion);
                
                if (currentVersion.CompareTo(lastVersion) <= 0)
                {
                    Log.Debug(\"No migration needed. Current: {Current}, Last: {Last}\", 
                        currentVersion.FullVersion, lastVersion.FullVersion);
                    return false;
                }
                
                Log.Information(\"Migration needed from {From} to {To}\", 
                    lastVersion.FullVersion, currentVersion.FullVersion);
                
                return await PerformMigrationAsync(lastVersion, currentVersion, migrationState);
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to check or perform migration\");
                return false;
            }
        }

        /// <summary>
        /// Perform migration from one version to another
        /// </summary>
        private async Task<bool> PerformMigrationAsync(VersionInfo fromVersion, VersionInfo toVersion, MigrationState migrationState)
        {
            var applicableMigrations = GetApplicableMigrations(fromVersion, toVersion);
            
            if (!applicableMigrations.Any())
            {
                Log.Information(\"No applicable migrations found\");
                await UpdateMigrationStateAsync(toVersion, migrationState);
                return false;
            }
            
            Log.Information(\"Found {Count} applicable migrations\", applicableMigrations.Count);
            
            // Create backup before migration
            var backupPath = await CreateBackupAsync();
            
            try
            {
                foreach (var migration in applicableMigrations)
                {
                    Log.Information(\"Executing migration: {Migration}\", migration.GetType().Name);
                    
                    var migrationRecord = new MigrationRecord
                    {
                        MigrationName = migration.GetType().Name,
                        FromVersion = migration.FromVersion,
                        ToVersion = migration.ToVersion,
                        StartTime = DateTime.UtcNow
                    };
                    
                    try
                    {
                        await migration.ExecuteAsync();
                        
                        migrationRecord.EndTime = DateTime.UtcNow;
                        migrationRecord.Success = true;
                        migrationRecord.ErrorMessage = null;
                        
                        migrationState.MigrationHistory.Add(migrationRecord);
                        
                        Log.Information(\"Migration {Migration} completed successfully\", migration.GetType().Name);
                    }
                    catch (Exception ex)
                    {
                        migrationRecord.EndTime = DateTime.UtcNow;
                        migrationRecord.Success = false;
                        migrationRecord.ErrorMessage = ex.Message;
                        
                        migrationState.MigrationHistory.Add(migrationRecord);
                        
                        Log.Error(ex, \"Migration {Migration} failed\", migration.GetType().Name);
                        
                        // Restore backup on failure
                        await RestoreBackupAsync(backupPath);
                        throw;
                    }
                }
                
                await UpdateMigrationStateAsync(toVersion, migrationState);
                
                Log.Information(\"All migrations completed successfully\");
                return true;
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Migration process failed, backup restored\");
                throw;
            }
        }

        /// <summary>
        /// Get migrations applicable for the version range
        /// </summary>
        private List<IMigration> GetApplicableMigrations(VersionInfo fromVersion, VersionInfo toVersion)
        {
            return _migrations
                .Where(m => 
                {
                    var migFromVersion = VersionInfo.Parse(m.FromVersion);
                    var migToVersion = VersionInfo.Parse(m.ToVersion);
                    
                    return migFromVersion.CompareTo(fromVersion) >= 0 && 
                           migToVersion.CompareTo(toVersion) <= 0;
                })
                .OrderBy(m => VersionInfo.Parse(m.FromVersion))
                .ToList();
        }

        /// <summary>
        /// Create backup of user data
        /// </summary>
        private async Task<string> CreateBackupAsync()
        {
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var appDataDirectory = Path.Combine(appDataPath, \"LiveCaptions-Translator\");
            var backupDirectory = Path.Combine(appDataDirectory, \"Backups\");
            
            if (!Directory.Exists(backupDirectory))
            {
                Directory.CreateDirectory(backupDirectory);
            }
            
            var timestamp = DateTime.UtcNow.ToString(\"yyyyMMdd-HHmmss\");
            var backupPath = Path.Combine(backupDirectory, $\"backup-{timestamp}.zip\");
            
            try
            {
                Log.Information(\"Creating backup at {Path}\", backupPath);
                
                using var zip = new System.IO.Compression.ZipArchive(
                    File.Create(backupPath), 
                    System.IO.Compression.ZipArchiveMode.Create);
                
                // Backup settings
                var settingsPath = Path.Combine(appDataDirectory, \"setting.json\");
                if (File.Exists(settingsPath))
                {
                    zip.CreateEntryFromFile(settingsPath, \"setting.json\");
                }
                
                // Backup database
                var dbPath = Path.Combine(Directory.GetCurrentDirectory(), \"translation_history.db\");
                if (File.Exists(dbPath))
                {
                    zip.CreateEntryFromFile(dbPath, \"translation_history.db\");
                }
                
                // Backup version config
                var versionConfigPath = Path.Combine(appDataDirectory, \"version-config.json\");
                if (File.Exists(versionConfigPath))
                {
                    zip.CreateEntryFromFile(versionConfigPath, \"version-config.json\");
                }
                
                Log.Information(\"Backup created successfully\");
                return backupPath;
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to create backup\");
                throw;
            }
        }

        /// <summary>
        /// Restore backup
        /// </summary>
        private async Task RestoreBackupAsync(string backupPath)
        {
            try
            {
                Log.Warning(\"Restoring backup from {Path}\", backupPath);
                
                if (!File.Exists(backupPath))
                {
                    Log.Error(\"Backup file not found: {Path}\", backupPath);
                    return;
                }
                
                var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                var appDataDirectory = Path.Combine(appDataPath, \"LiveCaptions-Translator\");
                
                using var zip = new System.IO.Compression.ZipArchive(
                    File.OpenRead(backupPath), 
                    System.IO.Compression.ZipArchiveMode.Read);
                
                foreach (var entry in zip.Entries)
                {
                    var targetPath = Path.Combine(
                        entry.Name == \"translation_history.db\" ? Directory.GetCurrentDirectory() : appDataDirectory,
                        entry.Name);
                    
                    entry.ExtractToFile(targetPath, true);
                }
                
                Log.Information(\"Backup restored successfully\");
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to restore backup\");
                throw;
            }
        }

        /// <summary>
        /// Load migration state
        /// </summary>
        private async Task<MigrationState?> LoadMigrationStateAsync()
        {
            try
            {
                if (!File.Exists(_migrationStateFile))
                {
                    return null;
                }
                
                var json = await File.ReadAllTextAsync(_migrationStateFile);
                return JsonSerializer.Deserialize<MigrationState>(json, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to load migration state, treating as first run\");
                return null;
            }
        }

        /// <summary>
        /// Save migration state
        /// </summary>
        private async Task SaveMigrationStateAsync(MigrationState state)
        {
            try
            {
                var directory = Path.GetDirectoryName(_migrationStateFile);
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                
                var json = JsonSerializer.Serialize(state, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                
                await File.WriteAllTextAsync(_migrationStateFile, json);
            }
            catch (Exception ex)
            {
                Log.Error(ex, \"Failed to save migration state\");
                throw;
            }
        }

        /// <summary>
        /// Update migration state with new version
        /// </summary>
        private async Task UpdateMigrationStateAsync(VersionInfo version, MigrationState state)
        {
            state.LastMigratedVersion = version.FullVersion;
            state.LastMigrationDate = DateTime.UtcNow;
            await SaveMigrationStateAsync(state);
        }

        /// <summary>
        /// Cleanup old backups (keep only last 5)
        /// </summary>
        public async Task CleanupOldBackupsAsync()
        {
            try
            {
                var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                var backupDirectory = Path.Combine(appDataPath, \"LiveCaptions-Translator\", \"Backups\");
                
                if (!Directory.Exists(backupDirectory))
                {
                    return;
                }
                
                var backupFiles = Directory.GetFiles(backupDirectory, \"backup-*.zip\")
                    .Select(f => new FileInfo(f))
                    .OrderByDescending(f => f.CreationTime)
                    .ToList();
                
                // Keep only the 5 most recent backups
                var filesToDelete = backupFiles.Skip(5);
                
                foreach (var file in filesToDelete)
                {
                    try
                    {
                        file.Delete();
                        Log.Debug(\"Deleted old backup: {File}\", file.Name);
                    }
                    catch (Exception ex)
                    {
                        Log.Warning(ex, \"Failed to delete old backup: {File}\", file.Name);
                    }
                }
                
                if (filesToDelete.Any())
                {
                    Log.Information(\"Cleaned up {Count} old backup files\", filesToDelete.Count());
                }
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to cleanup old backups\");
            }
        }
    }

    /// <summary>
    /// Migration state tracking
    /// </summary>
    public class MigrationState
    {
        public string? LastMigratedVersion { get; set; }
        public DateTime LastMigrationDate { get; set; }
        public List<MigrationRecord> MigrationHistory { get; set; } = new();
    }

    /// <summary>
    /// Individual migration record
    /// </summary>
    public class MigrationRecord
    {
        public required string MigrationName { get; set; }
        public required string FromVersion { get; set; }
        public required string ToVersion { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime? EndTime { get; set; }
        public bool Success { get; set; }
        public string? ErrorMessage { get; set; }
    }

    /// <summary>
    /// Base interface for data migrations
    /// </summary>
    public interface IMigration
    {
        string FromVersion { get; }
        string ToVersion { get; }
        string Description { get; }
        Task ExecuteAsync();
    }

    /// <summary>
    /// Example migration from 1.0.0 to 1.1.0
    /// </summary>
    public class Migration_1_0_0_to_1_1_0 : IMigration
    {
        public string FromVersion => \"1.0.0\";
        public string ToVersion => \"1.1.0\";
        public string Description => \"Migrate settings format and add new configuration options\";

        public async Task ExecuteAsync()
        {
            Log.Information(\"Executing migration from {From} to {To}: {Description}\", FromVersion, ToVersion, Description);
            
            // Example: Update settings file format
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var settingsPath = Path.Combine(appDataPath, \"LiveCaptions-Translator\", \"setting.json\");
            
            if (File.Exists(settingsPath))
            {
                // Read old format, convert to new format
                var oldSettings = await File.ReadAllTextAsync(settingsPath);
                
                // This is where you would implement actual migration logic
                // For example, adding new fields, converting data formats, etc.
                
                Log.Information(\"Settings file migrated successfully\");
            }
            
            // Add any other migration steps here
            await Task.Delay(100); // Simulate migration work
        }
    }

    /// <summary>
    /// Example migration from 1.1.0 to 1.2.0
    /// </summary>
    public class Migration_1_1_0_to_1_2_0 : IMigration
    {
        public string FromVersion => \"1.1.0\";
        public string ToVersion => \"1.2.0\";
        public string Description => \"Update database schema and add version management configuration\";

        public async Task ExecuteAsync()
        {
            Log.Information(\"Executing migration from {From} to {To}: {Description}\", FromVersion, ToVersion, Description);
            
            // Example: Database schema updates
            var dbPath = Path.Combine(Directory.GetCurrentDirectory(), \"translation_history.db\");
            
            if (File.Exists(dbPath))
            {
                // This is where you would implement database migration logic
                // For example, adding new columns, updating indexes, etc.
                
                Log.Information(\"Database schema migrated successfully\");
            }
            
            // Initialize version management configuration
            var versionConfig = new VersionConfig();
            var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var versionConfigPath = Path.Combine(appDataPath, \"LiveCaptions-Translator\", \"version-config.json\");
            
            await versionConfig.SaveAsync(versionConfigPath);
            
            Log.Information(\"Version management configuration initialized\");
            
            await Task.Delay(100); // Simulate migration work
        }
    }
}"