using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;
using LiveCaptionsTranslator.models;

namespace LiveCaptionsTranslator.windows
{
    public partial class SplashWindow : Window
    {
        public ObservableCollection<InitializationStep> Steps { get; set; }
        private int _currentStepIndex = -1;

        public SplashWindow()
        {
            InitializeComponent();
            
            Steps = new ObservableCollection<InitializationStep>
            {
                new InitializationStep { Description = "Check directory structure", Status = StepStatus.Pending },
                new InitializationStep { Description = "Check Ollama installation", Status = StepStatus.Pending },
                new InitializationStep { Description = "Start Ollama service", Status = StepStatus.Pending },
                new InitializationStep { Description = "Check default model", Status = StepStatus.Pending },
                new InitializationStep { Description = "Verify model availability", Status = StepStatus.Pending }
            };

            StepsItemsControl.ItemsSource = Steps;
        }

        public void UpdateStatus(string status)
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.Invoke(() => UpdateStatus(status));
                return;
            }

            LogTextBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {status}\n");
            LogTextBox.ScrollToEnd();

            StatusText.Text = status;

            int stepIndex = -1;
            if (status.Contains("directory structure")) stepIndex = 0;
            else if (status.Contains("Ollama installation")) stepIndex = 1;
            else if (status.Contains("Ollama service")) stepIndex = 2;
            else if (status.Contains("default model")) stepIndex = 3;
            else if (status.Contains("model availability") || status.Contains("Initialization complete")) stepIndex = 4;

            if (stepIndex != -1 && stepIndex > _currentStepIndex)
            {
                // Mark previous steps as complete
                for (int i = 0; i < stepIndex; i++)
                {
                    if (Steps[i].Status != StepStatus.Completed)
                    {
                        Steps[i].Status = StepStatus.Completed;
                    }
                }

                // Mark current step as in-progress
                if (stepIndex < Steps.Count)
                {
                    Steps[stepIndex].Status = StepStatus.InProgress;
                    StepText.Text = $"Step {stepIndex + 1}/{Steps.Count}: {Steps[stepIndex].Description}";
                }
                
                _currentStepIndex = stepIndex;
            }
            
            // If initialization is fully complete, mark the last step.
            if (status.Contains("Initialization complete"))
            {
                var lastStep = Steps.LastOrDefault();
                if (lastStep != null && lastStep.Status != StepStatus.Completed)
                {
                    lastStep.Status = StepStatus.Completed;
                }
            }

            UpdateProgress();
        }
        
        private void UpdateProgress()
        {
            int completedSteps = Steps.Count(s => s.Status == StepStatus.Completed);
            int progressPercentage = (completedSteps * 100) / Steps.Count;
            
            ProgressBar.Value = progressPercentage;
            ProgressText.Text = $"{progressPercentage}%";
        }
    }
}
