using LiveCaptionsTranslator.Models;
using LiveCaptionsTranslator.Windows;
using Serilog;
using System.Windows;
using System.Windows.Threading;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Automatic update service that runs in the background
    /// </summary>
    public class AutoUpdateService
    {
        private static readonly Lazy<AutoUpdateService> _instance = new(() => new AutoUpdateService());
        public static AutoUpdateService Instance => _instance.Value;

        private readonly DispatcherTimer _updateTimer;
        private readonly VersionManager _versionManager;
        private bool _isInitialized;
        private bool _isCheckingForUpdates;
        private DateTime? _lastUpdateCheck;
        private ReleaseInfo? _pendingUpdate;

        public event EventHandler<UpdateAvailableEventArgs>? UpdateAvailable;
        public event EventHandler<UpdateCheckCompletedEventArgs>? UpdateCheckCompleted;

        private AutoUpdateService()
        {
            _versionManager = VersionManager.Instance;
            _updateTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromHours(1) // Check every hour
            };
            _updateTimer.Tick += OnUpdateTimerTick;
            
            // Subscribe to version manager events
            _versionManager.UpdateCheckCompleted += OnVersionManagerUpdateCheckCompleted;
        }

        /// <summary>
        /// Initialize the auto-update service
        /// </summary>
        public async Task InitializeAsync()
        {
            if (_isInitialized) return;

            try
            {
                Log.Information("Initializing auto-update service");
                
                await _versionManager.InitializeAsync();
                
                var config = _versionManager.GetConfig();
                if (config.AutoUpdateEnabled && !config.OfflineMode)
                {
                    _updateTimer.Start();
                    Log.Information("Auto-update service started. Check interval: {Interval} hours", config.UpdateCheckInterval);
                    
                    // Perform initial update check if needed
                    if (config.ShouldCheckForUpdates())
                    {
                        _ = Task.Run(async () =>
                        {
                            await Task.Delay(TimeSpan.FromSeconds(30)); // Delay initial check
                            await CheckForUpdatesAsync(silent: true);
                        });
                    }
                }
                else
                {
                    Log.Information("Auto-update service disabled (AutoUpdateEnabled: {Enabled}, OfflineMode: {Offline})", 
                        config.AutoUpdateEnabled, config.OfflineMode);
                }
                
                _isInitialized = true;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to initialize auto-update service");
            }
        }

        /// <summary>
        /// Manually check for updates
        /// </summary>
        /// <param name="silent">Whether to show UI notifications</param>
        public async Task CheckForUpdatesAsync(bool silent = false)
        {
            if (_isCheckingForUpdates)
            {
                Log.Debug("Update check already in progress, skipping");
                return;
            }

            _isCheckingForUpdates = true;
            
            try
            {
                Log.Information("Checking for updates (silent: {Silent})", silent);
                _lastUpdateCheck = DateTime.Now;
                
                await _versionManager.CheckForUpdatesAsync();
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to check for updates");
                
                if (!silent)
                {
                    Application.Current.Dispatcher.Invoke(() =>
                    {
                        MessageBox.Show(
                            $"Failed to check for updates: {ex.Message}",
                            "Update Check Failed",
                            MessageBoxButton.OK,
                            MessageBoxImage.Warning);
                    });
                }
            }
            finally
            {
                _isCheckingForUpdates = false;
            }
        }

        /// <summary>
        /// Show update dialog for a specific release
        /// </summary>
        /// <param name="releaseInfo">Release information</param>
        /// <param name="owner">Owner window</param>
        public void ShowUpdateDialog(ReleaseInfo releaseInfo, Window? owner = null)
        {
            try
            {
                Application.Current.Dispatcher.Invoke(() =>
                {
                    var result = UpdateWindow.ShowUpdate(releaseInfo, owner);
                    
                    if (result == true)
                    {
                        Log.Information("User accepted update to version {Version}", releaseInfo.Version);
                        // Installation process will handle application restart
                    }
                    else
                    {
                        Log.Information("User declined or skipped update to version {Version}", releaseInfo.Version);
                    }
                });
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to show update dialog");
            }
        }

        /// <summary>
        /// Enable or disable automatic updates
        /// </summary>
        /// <param name="enabled">Whether to enable automatic updates</param>
        public async Task SetAutoUpdateEnabledAsync(bool enabled)
        {
            try
            {
                var config = _versionManager.GetConfig();
                config.AutoUpdateEnabled = enabled;
                await _versionManager.UpdateConfigAsync(config);
                
                if (enabled && !config.OfflineMode)
                {
                    _updateTimer.Start();
                    Log.Information("Auto-update service enabled");
                }
                else
                {
                    _updateTimer.Stop();
                    Log.Information("Auto-update service disabled");
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to update auto-update configuration");
            }
        }

        /// <summary>
        /// Set update check interval
        /// </summary>
        /// <param name="intervalHours">Interval in hours</param>
        public async Task SetUpdateCheckIntervalAsync(int intervalHours)
        {
            try
            {
                var config = _versionManager.GetConfig();
                config.UpdateCheckInterval = Math.Max(1, intervalHours); // Minimum 1 hour
                await _versionManager.UpdateConfigAsync(config);
                
                // Update timer interval
                _updateTimer.Interval = TimeSpan.FromHours(config.UpdateCheckInterval);
                
                Log.Information("Update check interval changed to {Hours} hours", config.UpdateCheckInterval);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to update check interval");
            }
        }

        /// <summary>
        /// Enable or disable pre-release updates
        /// </summary>
        /// <param name="allowPreRelease">Whether to allow pre-release updates</param>
        public async Task SetAllowPreReleaseAsync(bool allowPreRelease)
        {
            try
            {
                var config = _versionManager.GetConfig();
                config.AllowPreReleaseUpdates = allowPreRelease;
                await _versionManager.UpdateConfigAsync(config);
                
                Log.Information("Pre-release updates {Status}", allowPreRelease ? "enabled" : "disabled");
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to update pre-release setting");
            }
        }

        /// <summary>
        /// Get current update configuration
        /// </summary>
        /// <returns>Version configuration</returns>
        public VersionConfig GetConfiguration()
        {
            return _versionManager.GetConfig();
        }

        /// <summary>
        /// Get current application version
        /// </summary>
        /// <returns>Current version info</returns>
        public VersionInfo GetCurrentVersion()
        {
            return _versionManager.GetCurrentVersion();
        }

        /// <summary>
        /// Check if there's a pending update
        /// </summary>
        /// <returns>True if there's a pending update</returns>
        public bool HasPendingUpdate => _pendingUpdate != null;

        /// <summary>
        /// Get pending update information
        /// </summary>
        /// <returns>Pending update info or null</returns>
        public ReleaseInfo? GetPendingUpdate() => _pendingUpdate;

        /// <summary>
        /// Clear pending update
        /// </summary>
        public void ClearPendingUpdate()
        {
            _pendingUpdate = null;
        }

        /// <summary>
        /// Timer tick handler for periodic update checks
        /// </summary>
        private async void OnUpdateTimerTick(object? sender, EventArgs e)
        {
            var config = _versionManager.GetConfig();
            if (config.ShouldCheckForUpdates())
            {
                await CheckForUpdatesAsync(silent: true);
            }
        }

        /// <summary>
        /// Handle update check completion from version manager
        /// </summary>
        private void OnVersionManagerUpdateCheckCompleted(object? sender, UpdateCheckCompletedEventArgs e)
        {
            try
            {
                UpdateCheckCompleted?.Invoke(this, e);
                
                if (e.UpdateAvailable && e.LatestRelease != null)
                {
                    Log.Information("Update available: {Version} (current: {Current})", 
                        e.LatestRelease.Version, _versionManager.GetCurrentVersion().FullVersion);
                    
                    _pendingUpdate = e.LatestRelease;
                    
                    // Fire update available event
                    var updateArgs = new UpdateAvailableEventArgs
                    {
                        ReleaseInfo = e.LatestRelease,
                        CurrentVersion = _versionManager.GetCurrentVersion(),
                        IsCritical = e.LatestRelease.Critical
                    };
                    
                    UpdateAvailable?.Invoke(this, updateArgs);
                    
                    // For critical updates or if in interactive mode, show dialog immediately
                    if (e.LatestRelease.Critical || ShouldShowUpdateDialog())
                    {
                        Application.Current.Dispatcher.BeginInvoke(() =>
                        {
                            ShowUpdateDialog(e.LatestRelease, Application.Current.MainWindow);
                        });
                    }
                }
                else if (!e.UpdateAvailable)
                {
                    Log.Debug("No updates available");
                    _pendingUpdate = null;
                }
                else if (!string.IsNullOrEmpty(e.Error))
                {
                    Log.Warning("Update check failed: {Error}", e.Error);
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Error handling update check completion");
            }
        }

        /// <summary>
        /// Determine whether to show update dialog automatically
        /// </summary>
        private bool ShouldShowUpdateDialog()
        {
            // Show dialog if:
            // 1. It's been more than 24 hours since last check
            // 2. User hasn't been prompted recently
            // 3. Application is in interactive mode (not minimized to tray)
            
            var config = _versionManager.GetConfig();
            var mainWindow = Application.Current.MainWindow;
            
            return config.AutoUpdateEnabled && 
                   mainWindow != null && 
                   mainWindow.WindowState != WindowState.Minimized && 
                   mainWindow.IsVisible;
        }

        /// <summary>
        /// Shutdown the auto-update service
        /// </summary>
        public void Shutdown()
        {
            try
            {
                _updateTimer?.Stop();
                _versionManager?.Dispose();
                Log.Information("Auto-update service shutdown completed");
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Error during auto-update service shutdown");
            }
        }
    }

    /// <summary>
    /// Update available event arguments
    /// </summary>
    public class UpdateAvailableEventArgs : EventArgs
    {
        public required ReleaseInfo ReleaseInfo { get; init; }
        public required VersionInfo CurrentVersion { get; init; }
        public bool IsCritical { get; init; }
    }
}
