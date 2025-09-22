using Wpf.Ui.Controls;
using System.Windows;
using Wpf.Ui.Appearance;
using System.Diagnostics;
using System.Windows.Navigation;
using System.Threading.Tasks;
using System.Windows.Threading;
using Serilog;

namespace LiveCaptionsTranslator
{
    public partial class WelcomeWindow : FluentWindow
    {
        public WelcomeWindow()
        {
            try
            {
                InitializeComponent();
                ApplicationThemeManager.ApplySystemTheme();

                Loaded += WelcomeWindow_Loaded;
                Log.Information("WelcomeWindow initialized successfully");
            }
            catch (Exception ex)
            {
                Log.Error(ex, "WelcomeWindow constructor failed");
                throw;
            }
        }

        private void WelcomeWindow_Loaded(object sender, RoutedEventArgs e)
        {
            try
            {
                // 直接在 UI 线程中设置主题监视器，避免跨线程问题
                SystemThemeWatcher.Watch(this, WindowBackdropType.Mica, true);
                Log.Debug("WelcomeWindow loaded and theme watcher set");
            }
            catch (Exception ex)
            {
                Log.Warning(ex, "Failed to set SystemThemeWatcher for WelcomeWindow, but window can still function");
                // 不抛出异常，让窗口继续正常工作
            }
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Log.Information("WelcomeWindow closing by user action");
                Close();
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Error closing WelcomeWindow");
            }
        }

        private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
        {
            try
            {
                Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
                e.Handled = true;
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to open hyperlink: {Uri}", e.Uri.AbsoluteUri);
                e.Handled = true;
            }
        }
    }
}

