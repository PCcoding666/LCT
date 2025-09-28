using LiveCaptionsTranslator.Models;
using LiveCaptionsTranslator.Utils;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using Wpf.Ui.Controls;

namespace LiveCaptionsTranslator.Windows
{
    /// <summary>
    /// Update notification window
    /// </summary>
    public partial class UpdateWindow : FluentWindow, INotifyPropertyChanged
    {
        private ReleaseInfo? _updateInfo;
        private bool _isDownloading;
        private double _downloadProgress;
        private string _downloadStatus = \"Preparing download...\";
        private bool _canInstall;
        private string? _downloadedFilePath;

        public event PropertyChangedEventHandler? PropertyChanged;

        /// <summary>
        /// Update information
        /// </summary>
        public ReleaseInfo? UpdateInfo
        {
            get => _updateInfo;
            set
            {
                _updateInfo = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasUpdate));
                OnPropertyChanged(nameof(UpdateTitle));
                OnPropertyChanged(nameof(UpdateDescription));
                OnPropertyChanged(nameof(UpdateSize));
            }
        }

        /// <summary>
        /// Whether there is an update available
        /// </summary>
        public bool HasUpdate => UpdateInfo != null;

        /// <summary>
        /// Update title for display
        /// </summary>
        public string UpdateTitle => UpdateInfo != null ? 
            $\"Update to {UpdateInfo.Name} (v{UpdateInfo.Version})\" : 
            \"No update available\";

        /// <summary>
        /// Update description
        /// </summary>
        public string UpdateDescription => UpdateInfo?.Description ?? \"No description available\";

        /// <summary>
        /// Update download size
        /// </summary>
        public string UpdateSize
        {
            get
            {
                if (UpdateInfo == null) return \"\";
                
                var asset = UpdateInfo.GetInstallerAsset();
                if (asset != null && asset.Size > 0)
                {
                    var sizeMB = asset.Size / (1024.0 * 1024.0);
                    return $\"Download size: {sizeMB:F1} MB\";
                }
                
                return \"Download size: Unknown\";
            }
        }

        /// <summary>
        /// Whether download is in progress
        /// </summary>
        public bool IsDownloading
        {
            get => _isDownloading;
            set
            {
                _isDownloading = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanDownload));
                OnPropertyChanged(nameof(CanCancel));
            }
        }

        /// <summary>
        /// Download progress percentage
        /// </summary>
        public double DownloadProgress
        {
            get => _downloadProgress;
            set
            {
                _downloadProgress = value;
                OnPropertyChanged();
            }
        }

        /// <summary>
        /// Download status text
        /// </summary>
        public string DownloadStatus
        {
            get => _downloadStatus;
            set
            {
                _downloadStatus = value;
                OnPropertyChanged();
            }
        }

        /// <summary>
        /// Whether download can be started
        /// </summary>
        public bool CanDownload => HasUpdate && !IsDownloading && !CanInstall;

        /// <summary>
        /// Whether download can be cancelled
        /// </summary>
        public bool CanCancel => IsDownloading;

        /// <summary>
        /// Whether update can be installed
        /// </summary>
        public bool CanInstall
        {
            get => _canInstall;
            set
            {
                _canInstall = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanDownload));
            }
        }

        public UpdateWindow()
        {
            InitializeComponent();
            DataContext = this;
            
            // Set window properties
            Title = \"Software Update\";
            Width = 600;
            Height = 500;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.NoResize;
            
            // Subscribe to version manager events
            VersionManager.Instance.DownloadProgress += OnDownloadProgress;
        }

        /// <summary>
        /// Show update window with specific update info
        /// </summary>
        /// <param name=\"updateInfo\">Update information</param>
        /// <param name=\"owner\">Owner window</param>
        /// <returns>Dialog result</returns>
        public static bool? ShowUpdate(ReleaseInfo updateInfo, Window? owner = null)
        {
            var window = new UpdateWindow
            {
                UpdateInfo = updateInfo,
                Owner = owner
            };
            
            return window.ShowDialog();
        }

        /// <summary>
        /// Handle download progress
        /// </summary>
        private void OnDownloadProgress(object? sender, DownloadProgressEventArgs e)
        {
            Dispatcher.Invoke(() =>
            {
                DownloadProgress = e.ProgressPercentage;
                
                if (e.TotalBytes > 0)
                {
                    var downloadedMB = e.DownloadedBytes / (1024.0 * 1024.0);
                    var totalMB = e.TotalBytes / (1024.0 * 1024.0);
                    DownloadStatus = $\"Downloading... {downloadedMB:F1} MB / {totalMB:F1} MB ({e.ProgressPercentage:F1}%)\";
                }
                else
                {
                    DownloadStatus = $\"Downloading... {e.ProgressPercentage:F1}%\";
                }
            });
        }

        /// <summary>
        /// Download button click handler
        /// </summary>
        private async void OnDownloadClick(object sender, RoutedEventArgs e)
        {
            if (UpdateInfo == null) return;

            IsDownloading = true;
            DownloadStatus = \"Starting download...\";
            DownloadProgress = 0;

            try
            {
                var success = await VersionManager.Instance.DownloadAndInstallUpdateAsync(UpdateInfo, false);
                
                if (success)
                {
                    CanInstall = true;
                    DownloadStatus = \"Download completed! Ready to install.\";
                    DownloadProgress = 100;
                }
                else
                {
                    DownloadStatus = \"Download failed. Please try again later.\";
                    DownloadProgress = 0;
                }
            }
            catch (Exception ex)
            {
                DownloadStatus = $\"Download error: {ex.Message}\";
                DownloadProgress = 0;
            }
            finally
            {
                IsDownloading = false;
            }
        }

        /// <summary>
        /// Install button click handler
        /// </summary>
        private void OnInstallClick(object sender, RoutedEventArgs e)
        {
            try
            {
                // The installation process will close the application
                DialogResult = true;
                Close();
            }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show(
                    $\"Failed to start installation: {ex.Message}\",
                    \"Installation Error\",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
        }

        /// <summary>
        /// Skip this version button click handler
        /// </summary>
        private async void OnSkipVersionClick(object sender, RoutedEventArgs e)
        {
            if (UpdateInfo == null) return;

            try
            {
                await VersionManager.Instance.SkipVersionAsync(UpdateInfo.Version);
                DialogResult = false;
                Close();
            }
            catch (Exception ex)
            {
                System.Windows.MessageBox.Show(
                    $\"Failed to skip version: {ex.Message}\",
                    \"Error\",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        /// <summary>
        /// Remind me later button click handler
        /// </summary>
        private void OnRemindLaterClick(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }

        /// <summary>
        /// Cancel button click handler
        /// </summary>
        private void OnCancelClick(object sender, RoutedEventArgs e)
        {
            if (IsDownloading)
            {
                // TODO: Implement download cancellation
                IsDownloading = false;
                DownloadStatus = \"Download cancelled\";
                DownloadProgress = 0;
            }
            else
            {
                DialogResult = false;
                Close();
            }
        }

        /// <summary>
        /// View changelog button click handler
        /// </summary>
        private void OnViewChangelogClick(object sender, RoutedEventArgs e)
        {
            if (UpdateInfo?.ChangelogUrl != null)
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = UpdateInfo.ChangelogUrl,
                        UseShellExecute = true
                    });
                }
                catch (Exception ex)
                {
                    System.Windows.MessageBox.Show(
                        $\"Failed to open changelog: {ex.Message}\",
                        \"Error\",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                }
            }
        }

        protected virtual void OnPropertyChanged([System.Runtime.CompilerServices.CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        protected override void OnClosed(EventArgs e)
        {
            // Unsubscribe from events
            VersionManager.Instance.DownloadProgress -= OnDownloadProgress;
            base.OnClosed(e);
        }
    }
}"