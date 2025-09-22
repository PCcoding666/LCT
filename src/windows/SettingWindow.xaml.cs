using System.Windows;
using Wpf.Ui.Appearance;
using LiveCaptionsTranslator.models;

namespace LiveCaptionsTranslator
{
    public partial class SettingWindow : Wpf.Ui.Controls.FluentWindow
    {
        public SettingWindow()
        {
            InitializeComponent();
            ApplicationThemeManager.ApplySystemTheme();
            DataContext = Translator.Setting;

            Loaded += (sender, args) =>
            {
                SystemThemeWatcher.Watch(this);
                UpdateConfigIndicator();
                InitializeModelSelector();
            };
        }

        private void UpdateConfigIndicator()
        {
            // 由于当前只支持单一配置，显示 1/1
            // 未来可以扩展为支持多配置
            ConfigIndicator.Text = "1/1";
            
            // 禁用导航按钮，因为只有一个配置
            PrevConfigButton.IsEnabled = false;
            NextConfigButton.IsEnabled = false;
            
            // 禁用删除按钮，因为至少需要保留一个配置
            DeleteConfigButton.IsEnabled = false;
        }

        private void InitializeModelSelector()
        {
            try
            {
                ModelNameComboBox.ItemsSource = OllamaConfig.RecommendedModels;
                
                // 如果当前模型不在推荐列表中，保持用户输入的值
                if (!OllamaConfig.RecommendedModels.ContainsKey(Translator.Setting?.OllamaConfig?.ModelName ?? ""))
                {
                    ModelNameComboBox.Text = Translator.Setting?.OllamaConfig?.ModelName ?? "qwen2.5:3b";
                }
            }
            catch (System.Exception ex)
            {
                // 如果初始化失败，使用默认值
                ModelNameComboBox.Text = "qwen2.5:3b";
            }
        }

        private void PrevConfigButton_Click(object sender, RoutedEventArgs e)
        {
            // 预留给未来的多配置支持
            // 目前只有一个配置，所以不执行任何操作
        }

        private void NextConfigButton_Click(object sender, RoutedEventArgs e)
        {
            // 预留给未来的多配置支持
            // 目前只有一个配置，所以不执行任何操作
        }

        private void NewConfigButton_Click(object sender, RoutedEventArgs e)
        {
            // 预留给未来的多配置支持
            var messageBox = new Wpf.Ui.Controls.MessageBox
            {
                Title = "提示",
                Content = "多配置支持功能将在未来版本中提供。",
                CloseButtonText = "确定"
            };
            messageBox.ShowDialogAsync();
        }

        private void DeleteConfigButton_Click(object sender, RoutedEventArgs e)
        {
            // 预留给未来的多配置支持
            var messageBox = new Wpf.Ui.Controls.MessageBox
            {
                Title = "提示",
                Content = "无法删除唯一的配置。多配置支持功能将在未来版本中提供。",
                CloseButtonText = "确定"
            };
            messageBox.ShowDialogAsync();
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            this.Close();
        }

        private void SaveButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Translator.Setting?.Save();
                var messageBox = new Wpf.Ui.Controls.MessageBox
                {
                    Title = "成功",
                    Content = "设置已保存成功！",
                    CloseButtonText = "确定"
                };
                messageBox.ShowDialogAsync();
                this.Close();
            }
            catch (System.Exception ex)
            {
                var errorBox = new Wpf.Ui.Controls.MessageBox
                {
                    Title = "保存失败",
                    Content = $"保存设置时出现错误：{ex.Message}",
                    CloseButtonText = "确定"
                };
                errorBox.ShowDialogAsync();
            }
        }
    }
}