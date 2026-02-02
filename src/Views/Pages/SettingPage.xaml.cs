
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LiveCaptionsTranslator.models;
using LiveCaptionsTranslator.utils;

namespace LiveCaptionsTranslator
{
    public partial class SettingPage : Page
    {
        private static SettingWindow? SettingWindow;
        
        private const string DefaultPrompt = "You are a professional simultaneous interpreter specializing in international business communication. " +
                     "Your task is to translate speech content enclosed in 🔤 markers to {0}. " +
                     "CRITICAL RULES: " +
                     "1. Always output ONLY the translated text, never the original text " +
                     "2. Handle incomplete sentences naturally and professionally " +
                     "3. Preserve technical terms, company names, and proper nouns accurately " +
                     "4. Maintain appropriate business tone and formality " +
                     "5. For unclear speech, provide the most likely professional interpretation " +
                     "OUTPUT FORMAT: Single line translation only, remove all 🔤 markers, no explanations or original text.";

        public SettingPage()
        {
            InitializeComponent();
            DataContext = Translator.Setting;

            Loaded += SettingPage_Loaded;
            Unloaded += SettingPage_Unloaded;
        }

        private void SettingPage_Loaded(object sender, RoutedEventArgs e)
        {
            // Attach event handlers
            LiveCaptionsButton.Click += LiveCaptionsButton_click;
            APISettingButton.Click += APISettingButton_click;
            TargetLangBox.LostFocus += TargetLangBox_LostFocus;
            CaptionLogMax.SelectionChanged += CaptionLogMax_SelectionChanged;
            OverlayHistoryMax.SelectionChanged += OverlayHistoryMax_SelectionChanged;

            // Initialize page content
            InitializeLiveCaptionsButton();
            LoadAPISetting(); // This will load target languages for Ollama
        }

        private void SettingPage_Unloaded(object sender, RoutedEventArgs e)
        {
            // Detach event handlers to prevent memory leaks
            LiveCaptionsButton.Click -= LiveCaptionsButton_click;
            APISettingButton.Click -= APISettingButton_click;
            TargetLangBox.LostFocus -= TargetLangBox_LostFocus;
            CaptionLogMax.SelectionChanged -= CaptionLogMax_SelectionChanged;
            OverlayHistoryMax.SelectionChanged -= OverlayHistoryMax_SelectionChanged;
        }

        #region Initialization
        private void InitializeLiveCaptionsButton()
        {
            if (Translator.Window?.Current == null) 
            {
                ButtonText.Text = "Show";
                return;
            }
            bool isHidden = Translator.Window.Current.BoundingRectangle == Rect.Empty;
            ButtonText.Text = isHidden ? "Show" : "Hide";
        }
        #endregion

        #region Event Handlers
        private void LiveCaptionsButton_click(object sender, RoutedEventArgs e)
        {
            if (Translator.Window == null) return;

            bool isHidden = Translator.Window.Current.BoundingRectangle == Rect.Empty;

            if (isHidden)
            {
                LiveCaptionsHandler.RestoreLiveCaptions(Translator.Window);
                ButtonText.Text = "Hide";
            }
            else
            {
                LiveCaptionsHandler.HideLiveCaptions(Translator.Window);
                ButtonText.Text = "Show";
            }
        }

        private void TargetLangBox_LostFocus(object sender, RoutedEventArgs e)
        {
            if (Translator.Setting != null) Translator.Setting.TargetLanguage = TargetLangBox.Text;
        }

        private void TargetLangBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (Translator.Setting != null && TargetLangBox.SelectedItem != null)
            {
                Translator.Setting.TargetLanguage = TargetLangBox.SelectedItem.ToString();
            }
        }

        private void APISettingButton_click(object sender, RoutedEventArgs e)
        {
            if (SettingWindow != null && SettingWindow.IsLoaded) {
                SettingWindow.Activate();
            } else {
                SettingWindow = new SettingWindow();
                SettingWindow.Closed += (s, args) => SettingWindow = null;
                SettingWindow.Show();
            }
        }

        private void CaptionLogMax_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (Translator.Setting?.OverlayWindow != null && Translator.Setting?.MainWindow != null)
            {
                if (Translator.Setting.OverlayWindow.HistoryMax > Translator.Setting.MainWindow.CaptionLogMax)
                    Translator.Setting.OverlayWindow.HistoryMax = Translator.Setting.MainWindow.CaptionLogMax;

                if (Translator.Caption?.Contexts != null)
                {
                    while (Translator.Caption.Contexts.Count > Translator.Setting.MainWindow.CaptionLogMax)
                        Translator.Caption.Contexts.Dequeue();
                    Translator.Caption.OnPropertyChanged("DisplayContexts");
                }
            }
        }

        private void OverlayHistoryMax_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (Translator.Setting?.OverlayWindow != null && Translator.Setting?.MainWindow != null)
            {
                if (Translator.Setting.OverlayWindow.HistoryMax > Translator.Setting.MainWindow.CaptionLogMax)
                    Translator.Setting.MainWindow.CaptionLogMax = Translator.Setting.OverlayWindow.HistoryMax;
            }
        }
        
        #region Prompt Configuration
        private void ResetPromptButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var result = MessageBox.Show(
                    "Are you sure you want to reset the prompt to default? This action cannot be undone.",
                    "Reset Prompt",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Question);

                if (result == MessageBoxResult.Yes)
                {
                    if (Translator.Setting != null)
                    {
                        Translator.Setting.Prompt = DefaultPrompt;
                        ValidatePrompt();
                        
                        MessageBox.Show("Prompt has been reset to default successfully.", "Success", MessageBoxButton.OK, MessageBoxImage.Information);
                    }
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to reset prompt: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void TestPromptButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (Translator.Setting == null)
                {
                    MessageBox.Show("Settings not available.", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }

                // Validate Prompt
                if (!ValidatePrompt())
                {
                    MessageBox.Show("Please fix the prompt validation issues before testing.", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }

                // Test Prompt formatting
                string testLanguage = "Chinese";
                string formattedPrompt = string.Format(Translator.Setting.Prompt, testLanguage);
                
                var testWindow = new Window
                {
                    Title = "Prompt Test Preview",
                    Width = 600,
                    Height = 400,
                    WindowStartupLocation = WindowStartupLocation.CenterOwner,
                    Owner = Window.GetWindow(this)
                };

                var scrollViewer = new ScrollViewer
                {
                    Margin = new Thickness(20),
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto
                };

                var textBlock = new TextBlock
                {
                    Text = formattedPrompt,
                    TextWrapping = TextWrapping.Wrap,
                    FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                    FontSize = 12
                };

                scrollViewer.Content = textBlock;
                testWindow.Content = scrollViewer;
                testWindow.ShowDialog();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to test prompt: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private bool ValidatePrompt()
        {
            if (Translator.Setting == null || string.IsNullOrEmpty(Translator.Setting.Prompt))
            {
                MessageBox.Show("Prompt cannot be empty.", "Warning", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            if (!Translator.Setting.Prompt.Contains("{0}"))
            {
                MessageBox.Show("Prompt must contain {0} placeholder for target language.", "Warning", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            return true;
        }
        #endregion
        #endregion

        #region API and Language Loading
        public void LoadAPISetting()
        {
            // Since API is fixed to Ollama, we load its settings directly.
            if (Translator.Setting?.OllamaConfig == null)
            {
                return;
            }

            var config = Translator.Setting.OllamaConfig;
            var supportedLanguages = OllamaConfig.SupportedLanguages;

            if (!TargetLangBox.Dispatcher.CheckAccess())
            {
                TargetLangBox.Dispatcher.Invoke(() => UpdateTargetLanguageBox(supportedLanguages));
            }
            else
            {
                UpdateTargetLanguageBox(supportedLanguages);
            }
        }

        private void UpdateTargetLanguageBox(Dictionary<string, string> supportedLanguages)
        {
            if (TargetLangBox == null || Translator.Setting == null) return;

            string currentLang = TargetLangBox.Text; // Preserve user-entered text
            TargetLangBox.ItemsSource = supportedLanguages.Keys;

            if (supportedLanguages.ContainsKey(Translator.Setting.TargetLanguage))
            {
                TargetLangBox.SelectedItem = Translator.Setting.TargetLanguage;
            }
            else if (!string.IsNullOrEmpty(currentLang) && !supportedLanguages.ContainsKey(currentLang))
            {
                TargetLangBox.Text = currentLang;
            }
            else
            {
                TargetLangBox.SelectedItem = supportedLanguages.Keys.FirstOrDefault();
            }
        }
        #endregion
        
        #region Flyout Handlers
        private void LiveCaptionsInfo_MouseEnter(object sender, MouseEventArgs e) => LiveCaptionsInfoFlyout?.Show();
        private void LiveCaptionsInfo_MouseLeave(object sender, MouseEventArgs e) => LiveCaptionsInfoFlyout?.Hide();
        private void FrequencyInfo_MouseEnter(object sender, MouseEventArgs e) => FrequencyInfoFlyout?.Show();
        private void FrequencyInfo_MouseLeave(object sender, MouseEventArgs e) => FrequencyInfoFlyout?.Hide();
        private void TargetLangInfo_MouseEnter(object sender, MouseEventArgs e) => TargetLangInfoFlyout?.Show();
        private void TargetLangInfo_MouseLeave(object sender, MouseEventArgs e) => TargetLangInfoFlyout?.Hide();
        private void CaptionLogMaxInfo_MouseEnter(object sender, MouseEventArgs e) => CaptionLogMaxInfoFlyout?.Show();
        private void CaptionLogMaxInfo_MouseLeave(object sender, MouseEventArgs e) => CaptionLogMaxInfoFlyout?.Hide();
        private void ContextAwareInfo_MouseEnter(object sender, MouseEventArgs e) => ContextAwareInfoFlyout?.Show();
        private void ContextAwareInfo_MouseLeave(object sender, MouseEventArgs e) => ContextAwareInfoFlyout?.Hide();
        #endregion
    }
}
