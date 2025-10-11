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

                // Handle model download progress specifically
                if (status.Contains("Model download progress:"))
                {
                    HandleModelDownloadProgress(status);
                    return; // Don't update step status for progress updates
                }
                
                // Show/hide model download progress bar
                if (status.Contains("starting download") || status.Contains("Starting download"))
                {
                    _isModelDownloading = true;
                    ModelDownloadProgressBar.Visibility = Visibility.Visible;
                    ModelDownloadProgressBar.Value = 0;
                }
                else if (status.Contains("download completed") || status.Contains("download successful"))
                {
                    _isModelDownloading = false;
                    ModelDownloadProgressBar.Visibility = Visibility.Collapsed;
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
                // Extract percentage from status message
                // Expected format: "Model download progress: 45% (123MB / 456MB)"
                var percentageStart = status.IndexOf(": ") + 2;
                var percentageEnd = status.IndexOf('%');
                
                if (percentageStart > 1 && percentageEnd > percentageStart)
                {
                    var percentageStr = status.Substring(percentageStart, percentageEnd - percentageStart);
                    if (int.TryParse(percentageStr, out int percentage))
                    {
                        ModelDownloadProgressBar.Value = Math.Min(100, Math.Max(0, percentage));
                        
                        // Update progress text to show download progress
                        var mbInfo = "";
                        var mbStart = status.IndexOf('(');
                        var mbEnd = status.IndexOf(')', mbStart);
                        if (mbStart > -1 && mbEnd > mbStart)
                        {
                            mbInfo = " - " + status.Substring(mbStart + 1, mbEnd - mbStart - 1);
                        }
                        
                        ProgressText.Text = $"{percentage}%{mbInfo}";
                    }
                }
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Error parsing download progress: {ex.Message}");
            }
        }
    }
}
