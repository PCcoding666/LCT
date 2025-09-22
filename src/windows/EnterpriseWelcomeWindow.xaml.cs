using Wpf.Ui.Controls;
using System.Windows;
using Wpf.Ui.Appearance;
using System.Diagnostics;
using System.Windows.Navigation;

namespace LiveCaptionsTranslator.windows
{
    public partial class EnterpriseWelcomeWindow : FluentWindow
    {
        public EnterpriseWelcomeWindow()
        {
            InitializeComponent();
            ApplicationThemeManager.ApplySystemTheme();

            Loaded += (s, e) =>
            {
                SystemThemeWatcher.Watch(
                    this,
                    WindowBackdropType.Mica,
                    true
                );
            };
        }

        private void ContinueButton_Click(object sender, RoutedEventArgs e)
        {
            // 保存企业设置
            SaveEnterpriseSettings();
            
            // 关闭欢迎窗口
            Close();
        }
        
        private void AdvancedButton_Click(object sender, RoutedEventArgs e)
        {
            // 打开设置窗口
            var settingWindow = new SettingWindow();
            settingWindow.ShowDialog();
        }
        
        private void SaveEnterpriseSettings()
        {
            // 保存企业版特定设置
            bool autoStart = AutoStartToggle.IsChecked ?? true;
            bool anonymousStats = AnonymousStatsToggle.IsChecked ?? false;
            
            // 设置开机自启动
            if (autoStart)
            {
                SetStartupRegistry();
            }
            
            // 设置匿名统计
            // TODO: 实现匿名统计设置
        }
        
        private void SetStartupRegistry()
        {
            try
            {
                var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true);
                
                if (key != null)
                {
                    key.SetValue("DellLiveCaptionsTranslator", 
                        System.Reflection.Assembly.GetExecutingAssembly().Location);
                    key.Close();
                }
            }
            catch (System.Exception ex)
            {
                Debug.WriteLine($"设置自启动失败: {ex.Message}");
            }
        }
    }
} 