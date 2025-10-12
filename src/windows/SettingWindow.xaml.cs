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
                // 为了保持简单，只显示当前选择的模型，不允许更改
                var currentModelName = Translator.Setting?.OllamaConfig?.ModelName ?? "qwen3:4b-instruct-2507-q4_K_M";
                
                // 设置为只有一个选项（当前模型）
                var singleModelList = new Dictionary<string, string>
                {
                    { currentModelName, currentModelName }
                };
                
                ModelNameComboBox.ItemsSource = singleModelList;
                ModelNameComboBox.SelectedValue = currentModelName;
                
                Console.WriteLine($"InitializeModelSelector: Current model = {currentModelName}");
            }
            catch (System.Exception ex)
            {
                Console.WriteLine($"InitializeModelSelector failed: {ex.Message}");
                // 如果初始化失败，使用默认值
                var defaultModel = "qwen3:4b-instruct-2507-q4_K_M";
                var defaultModelList = new Dictionary<string, string>
                {
                    { defaultModel, defaultModel }
                };
                ModelNameComboBox.ItemsSource = defaultModelList;
                ModelNameComboBox.SelectedValue = defaultModel;
            }
        }
        
        private void RefreshModelSelector()
        {
            try
            {
                var currentModelName = Translator.Setting?.OllamaConfig?.ModelName ?? "qwen3:4b-instruct-2507-q4_K_M";
                
                // 更新显示列表为只包含当前模型
                var singleModelList = new Dictionary<string, string>
                {
                    { currentModelName, currentModelName }
                };
                
                ModelNameComboBox.ItemsSource = singleModelList;
                ModelNameComboBox.SelectedValue = currentModelName;
                
                Console.WriteLine($"RefreshModelSelector: Current model = {currentModelName}");
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
                Title = "Notice",
                Content = "Multiple configuration support will be available in future versions.",
                CloseButtonText = "OK"
            };
            messageBox.ShowDialogAsync();
        }

        private void DeleteConfigButton_Click(object sender, RoutedEventArgs e)
        {
            // 预留给未来的多配置支持
            var messageBox = new Wpf.Ui.Controls.MessageBox
            {
                Title = "Notice",
                Content = "Cannot delete the only configuration. Multiple configuration support will be available in future versions.",
                CloseButtonText = "OK"
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
                    Title = "Success",
                    Content = "Settings saved successfully!",
                    CloseButtonText = "OK"
                };
                messageBox.ShowDialogAsync();
                this.Close();
            }
            catch (System.Exception ex)
            {
                var errorBox = new Wpf.Ui.Controls.MessageBox
                {
                    Title = "Save Failed",
                    Content = $"Error occurred while saving settings: {ex.Message}",
                    CloseButtonText = "OK"
                };
                errorBox.ShowDialogAsync();
            }
        }
    }
}