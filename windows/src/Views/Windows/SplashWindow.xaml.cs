using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using LiveCaptionsTranslator.models;

namespace LiveCaptionsTranslator.windows
{
    public partial class SplashWindow : Window
    {
        public ObservableCollection<InitializationStep> Steps { get; set; }
        private int _currentStepIndex = -1;
        private bool _autoScroll = true;
        private const int MAX_LOG_LINES = 100; // Limit log lines to prevent memory issues
        private bool _isModelDownloading = false;

        public SplashWindow()
        {
            InitializeComponent();
            
            Steps = new ObservableCollection<InitializationStep>
            {
                new InitializationStep { Description = "Check directory structure", Status = StepStatus.Pending },
                new InitializationStep { Description = "Check Ollama installation", Status = StepStatus.Pending },
                new InitializationStep { Description = "Start Ollama service", Status = StepStatus.Pending },
                new InitializationStep { Description = "Check/Download AI model", Status = StepStatus.Pending },
                new InitializationStep { Description = "Verify model availability", Status = StepStatus.Pending }
            };

            StepsItemsControl.ItemsSource = Steps;
        }

        public void UpdateStatus(string status)
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.BeginInvoke(() => UpdateStatus(status));
                return;
            }

            try
            {
                // Add log entry with timestamp
                AddLogEntry($"[{DateTime.Now:HH:mm:ss}] {status}");

                // Update main status text
                StatusText.Text = status;

                // Handle both Ollama and model download progress
                if (status.Contains("[Model] Download:") || status.Contains("Model download progress:"))
                {
                    HandleModelDownloadProgress(status);
                    return; // Don't update step status for progress updates
                }
                else if (status.Contains("[Ollama] Download:"))
                {
                    HandleOllamaDownloadProgress(status);
                    return; // Don't update step status for progress updates
                }
                
                // Show/hide model download progress bar
                if (status.Contains("starting download") || status.Contains("Starting download") || status.Contains("[Model] Pulling"))
                {
                    _isModelDownloading = true;
                    ModelDownloadProgressBar.Visibility = Visibility.Visible;
                    ModelDownloadProgressBar.Value = 0;
                }
                else if (status.Contains("download completed") || status.Contains("download successful") || status.Contains("Download completed successfully"))
                {
                    _isModelDownloading = false;
                    ModelDownloadProgressBar.Visibility = Visibility.Collapsed;
                    ModelDownloadProgressBar.Value = 100;
                }

                // Determine step index based on status message
                int stepIndex = DetermineStepIndex(status);

                if (stepIndex != -1)
                {
                    UpdateStepStatus(stepIndex, status);
                }

                UpdateProgress();
            }
            catch (Exception ex)
            {
                // Fallback logging to prevent UI thread crashes
                System.Diagnostics.Debug.WriteLine($"Error updating splash status: {ex.Message}");
            }
        }

        private int DetermineStepIndex(string status)
        {
            var lowerStatus = status.ToLowerInvariant();
            
            // English-only pattern matching for step detection
            if (lowerStatus.Contains("directory"))
                return 0;
            else if (lowerStatus.Contains("ollama") && (lowerStatus.Contains("installation") || lowerStatus.Contains("extract")))
                return 1;
            else if (lowerStatus.Contains("ollama") && (lowerStatus.Contains("service") || lowerStatus.Contains("start")))
                return 2;
            else if (lowerStatus.Contains("model") || lowerStatus.Contains("download") ||
                     lowerStatus.Contains("pull") || lowerStatus.Contains("default") ||
                     lowerStatus.Contains("pulling") || lowerStatus.Contains("manifest") ||
                     lowerStatus.Contains("verifying") || lowerStatus.Contains("writing"))
                return 3;
            else if (lowerStatus.Contains("validat") || lowerStatus.Contains("verif") || lowerStatus.Contains("availability"))
                return 4;
            else if (lowerStatus.Contains("complete") || lowerStatus.Contains("initialization complete"))
                return 4; // Mark as final step
            
            return -1;
        }

        private void UpdateStepStatus(int stepIndex, string status)
        {
            try
            {
                var lowerStatus = status.ToLowerInvariant();
                bool isError = lowerStatus.Contains("failed") || lowerStatus.Contains("error");
                bool isComplete = lowerStatus.Contains("complete") || lowerStatus.Contains("successful");

                // Mark previous steps as completed if we're progressing
                if (stepIndex > _currentStepIndex)
                {
                    for (int i = 0; i <= Math.Min(_currentStepIndex, Steps.Count - 1); i++)
                    {
                        if (Steps[i].Status == StepStatus.InProgress)
                        {
                            Steps[i].Status = StepStatus.Completed;
                        }
                    }
                    _currentStepIndex = stepIndex;
                }

                // Update current step status
                if (stepIndex < Steps.Count)
                {
                    if (isError)
                    {
                        Steps[stepIndex].Status = StepStatus.Failed;
                    }
                    else if (isComplete && stepIndex == 4) // Final step completion
                    {
                        Steps[stepIndex].Status = StepStatus.Completed;
                        // Mark all remaining steps as completed
                        for (int i = 0; i < Steps.Count; i++)
                        {
                            if (Steps[i].Status != StepStatus.Completed)
                            {
                                Steps[i].Status = StepStatus.Completed;
                            }
                        }
                    }
                    else if (!isError)
                    {
                        Steps[stepIndex].Status = StepStatus.InProgress;
                    }

                    // Update step text
                    StepText.Text = $"Step {stepIndex + 1}/{Steps.Count}: {Steps[stepIndex].Description}";
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error updating step status: {ex.Message}");
            }
        }
        
        private void UpdateProgress()
        {
            int completedSteps = Steps.Count(s => s.Status == StepStatus.Completed);
            int progressPercentage = (completedSteps * 100) / Steps.Count;
            
            ProgressBar.Value = progressPercentage;
            ProgressText.Text = $"{progressPercentage}%";
        }

        private void AddLogEntry(string message)
        {
            try
            {
                // Manage log size to prevent memory issues
                var lines = LogTextBox.Text.Split('\n');
                if (lines.Length >= MAX_LOG_LINES)
                {
                    // Keep only the last 50% of lines when limit is reached
                    var keepLines = lines.Skip(lines.Length / 2).ToArray();
                    LogTextBox.Text = string.Join("\n", keepLines);
                }

                LogTextBox.AppendText(message + "\n");
                
                // Auto-scroll only if user hasn't manually scrolled up
                if (_autoScroll)
                {
                    LogTextBox.ScrollToEnd();
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error adding log entry: {ex.Message}");
            }
        }

        private void LogScrollViewer_ScrollChanged(object sender, ScrollChangedEventArgs e)
        {
            try
            {
                var scrollViewer = sender as ScrollViewer;
                if (scrollViewer != null)
                {
                    // Check if user scrolled manually (not at bottom)
                    _autoScroll = Math.Abs(scrollViewer.VerticalOffset - scrollViewer.ScrollableHeight) < 1.0;
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error in scroll changed event: {ex.Message}");
            }
        }
        
        private void HandleModelDownloadProgress(string status)
        {
            try
            {
                // Handle both old and new progress formats
                // New format: "[Model] Download: 45% (123.5MB / 456.7MB) - Speed: 2.34MB/s - ETA: 2m 15s"
                // Old format: "Model download progress: 45% (123MB / 456MB)"
                
                int percentage = 0;
                string progressDetails = "";
                
                // Try new format first
                if (status.Contains("[Model] Download:"))
                {
                    var percentageStart = status.IndexOf(": ") + 2;
                    var percentageEnd = status.IndexOf('%', percentageStart);
                    
                    if (percentageStart > 1 && percentageEnd > percentageStart)
                    {
                        var percentageStr = status.Substring(percentageStart, percentageEnd - percentageStart);
                        if (int.TryParse(percentageStr, out percentage))
                        {
                            // Extract detailed info (MB/MB, speed, ETA)
                            var detailsStart = status.IndexOf('(');
                            var detailsEnd = status.LastIndexOf(')');
                            if (detailsStart > -1 && detailsEnd > detailsStart)
                            {
                                // Get everything between first ( and last )
                                var fullDetails = status.Substring(detailsStart + 1, detailsEnd - detailsStart - 1);
                                
                                // Extract MB info and speed/ETA
                                var parts = status.Split(new[] { " - " }, StringSplitOptions.None);
                                if (parts.Length >= 2)
                                {
                                    // Get MB info from first part
                                    var mbStart = parts[0].IndexOf('(');
                                    var mbEnd = parts[0].IndexOf(')', mbStart);
                                    if (mbStart > -1 && mbEnd > mbStart)
                                    {
                                        var mbInfo = parts[0].Substring(mbStart + 1, mbEnd - mbStart - 1);
                                        progressDetails = mbInfo;
                                    }
                                    
                                    // Add speed if available
                                    if (parts.Length >= 2 && parts[1].Contains("Speed:"))
                                    {
                                        var speedInfo = parts[1].Replace("Speed:", "").Trim();
                                        progressDetails += $" @ {speedInfo}";
                                    }
                                    
                                    // Add ETA if available
                                    if (parts.Length >= 3 && parts[2].Contains("ETA:"))
                                    {
                                        var etaInfo = parts[2].Replace("ETA:", "").Trim();
                                        progressDetails += $" ETA: {etaInfo}";
                                    }
                                }
                            }
                        }
                    }
                }
                else // Try old format
                {
                    var percentageStart = status.IndexOf(": ") + 2;
                    var percentageEnd = status.IndexOf('%');
                    
                    if (percentageStart > 1 && percentageEnd > percentageStart)
                    {
                        var percentageStr = status.Substring(percentageStart, percentageEnd - percentageStart);
                        if (int.TryParse(percentageStr, out percentage))
                        {
                            var mbStart = status.IndexOf('(');
                            var mbEnd = status.IndexOf(')', mbStart);
                            if (mbStart > -1 && mbEnd > mbStart)
                            {
                                progressDetails = status.Substring(mbStart + 1, mbEnd - mbStart - 1);
                            }
                        }
                    }
                }
                
                // Update UI
                if (percentage > 0)
                {
                    ModelDownloadProgressBar.Value = Math.Min(100, Math.Max(0, percentage));
                    ProgressText.Text = $"{percentage}%";
                    
                    if (!string.IsNullOrEmpty(progressDetails))
                    {
                        // Show details in status text
                        StatusText.Text = $"Downloading model: {progressDetails}";
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error parsing download progress: {ex.Message}");
            }
        }
        
        private void HandleOllamaDownloadProgress(string status)
        {
            try
            {
                // Format: "[Ollama] Download: 45% (123.5MB / 456.7MB) - Speed: 2.34MB/s"
                int percentage = 0;
                string progressDetails = "";
                
                var percentageStart = status.IndexOf(": ") + 2;
                var percentageEnd = status.IndexOf('%', percentageStart);
                
                if (percentageStart > 1 && percentageEnd > percentageStart)
                {
                    var percentageStr = status.Substring(percentageStart, percentageEnd - percentageStart);
                    if (int.TryParse(percentageStr, out percentage))
                    {
                        // Extract detailed info
                        var parts = status.Split(new[] { " - " }, StringSplitOptions.None);
                        if (parts.Length >= 1)
                        {
                            // Get MB info from first part
                            var mbStart = parts[0].IndexOf('(');
                            var mbEnd = parts[0].IndexOf(')', mbStart);
                            if (mbStart > -1 && mbEnd > mbStart)
                            {
                                var mbInfo = parts[0].Substring(mbStart + 1, mbEnd - mbStart - 1);
                                progressDetails = mbInfo;
                            }
                            
                            // Add speed if available
                            if (parts.Length >= 2 && parts[1].Contains("Speed:"))
                            {
                                var speedInfo = parts[1].Replace("Speed:", "").Trim();
                                progressDetails += $" @ {speedInfo}";
                            }
                        }
                    }
                }
                
                // Update UI
                if (percentage > 0)
                {
                    // Update overall progress bar for Ollama installation step
                    var stepProgress = 20 + (percentage * 30 / 100); // Ollama is roughly 30% of total process
                    ProgressBar.Value = Math.Min(100, Math.Max(0, stepProgress));
                    ProgressText.Text = $"{percentage}%";
                    
                    if (!string.IsNullOrEmpty(progressDetails))
                    {
                        StatusText.Text = $"Downloading Ollama engine: {progressDetails}";
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error parsing Ollama download progress: {ex.Message}");
            }
        }
    }
}
