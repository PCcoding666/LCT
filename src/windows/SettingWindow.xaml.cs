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
            
            // 在窗口激活时也刷新模型选择器
            Activated += (sender, args) =>
            {
                RefreshModelSelector();
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
                // 设置数据源
                ModelNameComboBox.ItemsSource = OllamaConfig.RecommendedModels;
                
                // 获取当前配置的模型名
                var currentModelName = Translator.Setting?.OllamaConfig?.ModelName ?? "qwen3:4b-instruct-2507-q4_K_M";
                
                // 确保ComboBox显示正确的值
                if (OllamaConfig.RecommendedModels.ContainsKey(currentModelName))
                {
                    // 如果在推荐列表中，设置SelectedValue
                    ModelNameComboBox.SelectedValue = currentModelName;
                }
                else
                {
                    // 如果不在推荐列表中，设置为自定义文本（保持用户输入的值）
                    ModelNameComboBox.Text = currentModelName;
                }
                
                Console.WriteLine($"InitializeModelSelector: Current model = {currentModelName}, Selected = {ModelNameComboBox.SelectedValue}, Text = {ModelNameComboBox.Text}");
            }
            catch (System.Exception ex)
            {
                Console.WriteLine($"InitializeModelSelector failed: {ex.Message}");
                // 如果初始化失败，使用默认值
                ModelNameComboBox.Text = "qwen3:4b-instruct-2507-q4_K_M";
            }
        }
        
        private void RefreshModelSelector()
        {
            try
            {
                var currentModelName = Translator.Setting?.OllamaConfig?.ModelName ?? "qwen3:4b-instruct-2507-q4_K_M";
                
                // 刷新显示
                if (OllamaConfig.RecommendedModels.ContainsKey(currentModelName))
                {
                    ModelNameComboBox.SelectedValue = currentModelName;
                }
                else
                {
                    ModelNameComboBox.Text = currentModelName;
                }
                
                Console.WriteLine($"RefreshModelSelector: Current model = {currentModelName}, SelectedValue = {ModelNameComboBox.SelectedValue}, Text = {ModelNameComboBox.Text}");
            }
            catch (System.Exception ex)
            {
                Console.WriteLine($"RefreshModelSelector failed: {ex.Message}");
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