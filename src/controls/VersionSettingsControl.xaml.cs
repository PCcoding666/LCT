using LiveCaptionsTranslator.Utils;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace LiveCaptionsTranslator.Controls
{
    /// <summary>
    /// Version management settings control
    /// </summary>
    public partial class VersionSettingsControl : UserControl, INotifyPropertyChanged
    {
        private bool _autoUpdateEnabled;
        private bool _allowPreRelease;
        private int _updateInterval;
        private string _currentVersion = \"Unknown\";
        private string _lastCheckTime = \"Never\";
        private bool _isCheckingForUpdates;

        public event PropertyChangedEventHandler? PropertyChanged;

        /// <summary>
        /// Auto-update enabled
        /// </summary>
        public bool AutoUpdateEnabled
        {
            get => _autoUpdateEnabled;
            set
            {
                _autoUpdateEnabled = value;
                OnPropertyChanged();
                _ = Task.Run(async () => await AutoUpdateService.Instance.SetAutoUpdateEnabledAsync(value));
            }
        }

        /// <summary>
        /// Allow pre-release updates
        /// </summary>
        public bool AllowPreRelease
        {
            get => _allowPreRelease;
            set
            {
                _allowPreRelease = value;
                OnPropertyChanged();
                _ = Task.Run(async () => await AutoUpdateService.Instance.SetAllowPreReleaseAsync(value));
            }
        }

        /// <summary>
        /// Update check interval in hours
        /// </summary>
        public int UpdateInterval
        {
            get => _updateInterval;
            set
            {
                _updateInterval = value;
                OnPropertyChanged();
                _ = Task.Run(async () => await AutoUpdateService.Instance.SetUpdateCheckIntervalAsync(value));
            }
        }

        /// <summary>
        /// Current application version
        /// </summary>
        public string CurrentVersion
        {
            get => _currentVersion;
            set
            {
                _currentVersion = value;
                OnPropertyChanged();
            }
        }

        /// <summary>
        /// Last update check time
        /// </summary>
        public string LastCheckTime
        {
            get => _lastCheckTime;
            set
            {
                _lastCheckTime = value;
                OnPropertyChanged();
            }
        }

        /// <summary>
        /// Whether update check is in progress
        /// </summary>
        public bool IsCheckingForUpdates
        {
            get => _isCheckingForUpdates;
            set
            {
                _isCheckingForUpdates = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanCheckForUpdates));
            }
        }

        /// <summary>
        /// Whether manual update check is allowed
        /// </summary>
        public bool CanCheckForUpdates => !IsCheckingForUpdates;

        public VersionSettingsControl()
        {
            InitializeComponent();
            DataContext = this;
            
            Loaded += OnLoaded;
            Unloaded += OnUnloaded;
        }

        private async void OnLoaded(object sender, RoutedEventArgs e)
        {
            await LoadSettingsAsync();
            
            // Subscribe to update events
            AutoUpdateService.Instance.UpdateCheckCompleted += OnUpdateCheckCompleted;
        }

        private void OnUnloaded(object sender, RoutedEventArgs e)
        {
            // Unsubscribe from events
            AutoUpdateService.Instance.UpdateCheckCompleted -= OnUpdateCheckCompleted;
        }

        /// <summary>
        /// Load current settings
        /// </summary>
        private async Task LoadSettingsAsync()
        {
            try
            {
                var config = AutoUpdateService.Instance.GetConfiguration();
                var currentVersionInfo = AutoUpdateService.Instance.GetCurrentVersion();
                
                // Update properties without triggering events
                _autoUpdateEnabled = config.AutoUpdateEnabled;
                _allowPreRelease = config.AllowPreReleaseUpdates;
                _updateInterval = config.UpdateCheckInterval;
                _currentVersion = $\"{currentVersionInfo.FullVersion} ({(currentVersionInfo.IsDevelopmentBuild ? \"Debug\" : \"Release\")})\";
                
                if (config.LastUpdateCheck.HasValue)
                {
                    var timeSpan = DateTime.Now - config.LastUpdateCheck.Value;
                    _lastCheckTime = timeSpan.TotalDays >= 1 ? 
                        $\"{timeSpan.Days} days ago\" : 
                        timeSpan.TotalHours >= 1 ? 
                            $\"{(int)timeSpan.TotalHours} hours ago\" : 
                            \"Recently\";
                }
                else
                {
                    _lastCheckTime = \"Never\";
                }
                
                // Notify all property changes
                OnPropertyChanged(nameof(AutoUpdateEnabled));
                OnPropertyChanged(nameof(AllowPreRelease));
                OnPropertyChanged(nameof(UpdateInterval));
                OnPropertyChanged(nameof(CurrentVersion));
                OnPropertyChanged(nameof(LastCheckTime));
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($\"Failed to load version settings: {ex.Message}\");
            }
        }

        /// <summary>
        /// Manual check for updates button click
        /// </summary>
        private async void OnCheckForUpdatesClick(object sender, RoutedEventArgs e)
        {
            IsCheckingForUpdates = true;
            
            try
            {
                await AutoUpdateService.Instance.CheckForUpdatesAsync(silent: false);
            }
            finally
            {
                IsCheckingForUpdates = false;
            }
        }

        /// <summary>
        /// View version information button click
        /// </summary>
        private void OnViewVersionInfoClick(object sender, RoutedEventArgs e)
        {
            try
            {
                var versionInfo = AppVersionInfo.GetFullVersionString();
                
                MessageBox.Show(
                    versionInfo,
                    \"Version Information\",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $\"Failed to load version information: {ex.Message}\",
                    \"Error\",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        /// <summary>
        /// Open update folder button click
        /// </summary>
        private void OnOpenUpdateFolderClick(object sender, RoutedEventArgs e)
        {
            try
            {
                var appDataPath = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                var appDataDirectory = System.IO.Path.Combine(appDataPath, \"LiveCaptions-Translator\");
                
                if (!System.IO.Directory.Exists(appDataDirectory))
                {
                    System.IO.Directory.CreateDirectory(appDataDirectory);
                }
                
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = appDataDirectory,
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $\"Failed to open update folder: {ex.Message}\",
                    \"Error\",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        /// <summary>
        /// Handle update check completion
        /// </summary>
        private void OnUpdateCheckCompleted(object? sender, UpdateCheckCompletedEventArgs e)
        {
            Dispatcher.BeginInvoke(() =>
            {
                IsCheckingForUpdates = false;
                
                if (e.UpdateAvailable && e.LatestRelease != null)
                {
                    MessageBox.Show(
                        $\"Update available: {e.LatestRelease.Name} (v{e.LatestRelease.Version})\n\n\" +
                        $\"Current version: {AutoUpdateService.Instance.GetCurrentVersion().FullVersion}\n\n\" +
                        \"The update dialog will open automatically.\",
                        \"Update Available\",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
                else if (!e.UpdateAvailable && string.IsNullOrEmpty(e.Error))
                {
                    MessageBox.Show(
                        \"You are running the latest version.\",
                        \"No Updates Available\",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
                else if (!string.IsNullOrEmpty(e.Error))
                {
                    MessageBox.Show(
                        $\"Failed to check for updates: {e.Error}\",
                        \"Update Check Failed\",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                }
                
                // Refresh last check time
                _ = LoadSettingsAsync();
            });
        }

        protected virtual void OnPropertyChanged([System.Runtime.CompilerServices.CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}"