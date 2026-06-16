using System.ComponentModel;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LiveCaptionsTranslator.utils;

namespace LiveCaptionsTranslator
{
    public partial class CaptionPage : Page
    {
        public const int CARD_HEIGHT = 110;

        private static CaptionPage? instance;
        public static CaptionPage? Instance => instance;

        public CaptionPage()
        {
            InitializeComponent();
            DataContext = Translator.Caption;
            instance = this;

            Loaded += (s, e) =>
            {
                AutoHeight();
                // Set initial Log Cards state
                if (Translator.Setting != null)
                {
                    CollapseTranslatedCaption(Translator.Setting.MainWindow.CaptionLogEnabled);
                }
                
                if(Translator.Caption != null)
                    Translator.Caption.PropertyChanged += TranslatedChanged;
            };
            Unloaded += (s, e) =>
            {
                if(Translator.Caption != null)
                    Translator.Caption.PropertyChanged -= TranslatedChanged;
            };

            if (Translator.Setting != null)
                CollapseTranslatedCaption(Translator.Setting.MainWindow.CaptionLogEnabled);
        }

        private async void TextBlock_MouseLeftButtonDown(object sender, RoutedEventArgs e)
        {
            if (sender is TextBlock textBlock)
            {
                try
                {
                    Clipboard.SetText(textBlock.Text);
                    textBlock.ToolTip = "Copied!";
                }
                catch
                {
                    textBlock.ToolTip = "Error to Copy";
                }
                await System.Threading.Tasks.Task.Delay(500);
                textBlock.ToolTip = "Click to Copy";
            }
        }

        private void TranslatedChanged(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(Translator.Caption.DisplayTranslatedCaption))
            {
                if (Translator.Caption != null && Encoding.UTF8.GetByteCount(Translator.Caption.DisplayTranslatedCaption) >= TextUtil.LONG_THRESHOLD)
                {
                    Dispatcher.BeginInvoke(new System.Action(() =>
                    {
                        this.TranslatedCaption.FontSize = 15;
                    }), DispatcherPriority.Background);
                }
                else
                {
                    Dispatcher.BeginInvoke(new System.Action(() =>
                    {
                        this.TranslatedCaption.FontSize = 18;
                    }), DispatcherPriority.Background);
                }
            }
        }

        public void CollapseTranslatedCaption(bool isCollapsed)
        {
            var converter = new System.Windows.GridLengthConverter();

            if (isCollapsed)
            {
                TranslatedCaption_Row.Height = (GridLength)converter.ConvertFromString("Auto");
                CaptionLogCard.Visibility = Visibility.Visible;
            }
            else
            {
                TranslatedCaption_Row.Height = (GridLength)converter.ConvertFromString("*");
                CaptionLogCard.Visibility = Visibility.Collapsed;
            }
        }

        public void AutoHeight()
        {
            var mainWindow = App.Current.MainWindow as MainWindow;
            if (mainWindow == null) return;

            if (Translator.Setting.MainWindow.CaptionLogEnabled)
                mainWindow.AutoHeightAdjust(
                    minHeight: CARD_HEIGHT * (Translator.Setting.MainWindow.CaptionLogMax + 1),
                    maxHeight: CARD_HEIGHT * (Translator.Setting.MainWindow.CaptionLogMax + 1));
            else
                mainWindow.AutoHeightAdjust(
                    minHeight: (int)mainWindow.MinHeight,
                    maxHeight: (int)mainWindow.MinHeight);
        }

        private void CaptionLogButton_Click(object sender, RoutedEventArgs e)
        {
            if (Translator.Setting?.MainWindow != null)
            {
                Translator.Setting.MainWindow.CaptionLogEnabled = !Translator.Setting.MainWindow.CaptionLogEnabled;
                CollapseTranslatedCaption(Translator.Setting.MainWindow.CaptionLogEnabled);
                
                var button = sender as Wpf.Ui.Controls.Button;
                var symbolIcon = button?.Icon as Wpf.Ui.Controls.SymbolIcon;
                if (symbolIcon != null)
                {
                    symbolIcon.Filled = Translator.Setting.MainWindow.CaptionLogEnabled;
                }
                
                // Update button text
                if (button != null)
                {
                    button.Content = Translator.Setting.MainWindow.CaptionLogEnabled ? "Hide History" : "Show History";
                }
            }
        }

        private void StartStopTranslationButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var mainWindow = App.Current.MainWindow as MainWindow;
                if (mainWindow != null)
                {
                    // Directly call the main window's translation control method
                    mainWindow.LogOnlyButton_Click(sender, e);
                    
                    // Synchronously update button state on this page
                    var button = sender as Wpf.Ui.Controls.Button;
                    if (button != null)
                    {
                        var symbolIcon = button.Icon as Wpf.Ui.Controls.SymbolIcon;
                        if (mainWindow.IsTranslationRunning)
                        {
                            button.Content = "Stop Translation";
                            if (symbolIcon != null)
                            {
                                symbolIcon.Symbol = Wpf.Ui.Controls.SymbolRegular.Stop24;
                            }
                        }
                        else
                        {
                            button.Content = "Start Translation";
                            if (symbolIcon != null)
                            {
                                symbolIcon.Symbol = Wpf.Ui.Controls.SymbolRegular.Play24;
                            }
                        }
                    }
                }
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Error switching translation state: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void CompactOverlayButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                // Open overlay window - enhance entry visibility
                var mainWindow = App.Current.MainWindow as MainWindow;
                if (mainWindow != null)
                {
                    mainWindow.ShowOverlayWindow();
                    
                    // Update button state to provide visual feedback
                    var button = sender as Wpf.Ui.Controls.Button;
                    if (button != null)
                    {
                        var symbolIcon = button.Icon as Wpf.Ui.Controls.SymbolIcon;
                        if (symbolIcon != null)
                        {
                            symbolIcon.Symbol = Wpf.Ui.Controls.SymbolRegular.Desktop20;
                        }
                        button.Content = "Overlay Window Opened";
                        
                        // Restore button text after 2 seconds
                        var timer = new System.Windows.Threading.DispatcherTimer
                        {
                            Interval = TimeSpan.FromSeconds(2)
                        };
                        timer.Tick += (s, args) =>
                        {
                            timer.Stop();
                            button.Content = "Open Overlay Window";
                            if (symbolIcon != null)
                            {
                                symbolIcon.Symbol = Wpf.Ui.Controls.SymbolRegular.Resize20;
                            }
                        };
                        timer.Start();
                    }
                }
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Error opening overlay window: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async void CopyOriginalButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (Translator.Caption?.DisplayOriginalCaption != null)
                {
                    Clipboard.SetText(Translator.Caption.DisplayOriginalCaption);
                    
                    var button = sender as Wpf.Ui.Controls.Button;
                    if (button != null)
                    {
                        var originalContent = button.Content;
                        button.Content = "Copied!";
                        await System.Threading.Tasks.Task.Delay(1000);
                        button.Content = originalContent;
                    }
                }
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Error copying original text: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async void CopyTranslationButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (Translator.Caption?.DisplayTranslatedCaption != null)
                {
                    Clipboard.SetText(Translator.Caption.DisplayTranslatedCaption);
                    
                    var button = sender as Wpf.Ui.Controls.Button;
                    if (button != null)
                    {
                        var originalContent = button.Content;
                        button.Content = "Copied!";
                        await System.Threading.Tasks.Task.Delay(1000);
                        button.Content = originalContent;
                    }
                }
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Error copying translation: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }
}