using System;
using System.ComponentModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using LiveCaptionsTranslator.utils;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace LiveCaptionsTranslator;

public partial class MainWindow : FluentWindow, INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public bool IsTranslationRunning { get; private set; } = false;
    private CancellationTokenSource? _translationCancellationTokenSource;
    public OverlayWindow? OverlayWindow { get; set; } = null;

    public MainWindow()
    {
        InitializeComponent();
        ApplicationThemeManager.ApplySystemTheme();
        DataContext = this;

        Loaded += OnMainWindowLoaded;
        Closing += OnMainWindowClosing;
    }

    private void OnMainWindowLoaded(object sender, RoutedEventArgs e)
    {
        // 导航到默认页面
        RootNavigation.Navigate(typeof(CaptionPage));

        if (Translator.Setting != null)
        {
            this.Topmost = Translator.Setting.MainWindow.Topmost;
            var icon = (TopmostButton.Icon as SymbolIcon);
            if (icon != null) icon.Filled = this.Topmost;
        }
    }

    private void OnMainWindowClosing(object? sender, CancelEventArgs e)
    {
        if (Translator.Setting != null)
        {
            Translator.Setting.MainWindow.Topmost = this.Topmost;
        }
        OllamaGuardian.StopServer();
        Translator.Setting?.Save();
        Application.Current.Shutdown();
    }

    #region Window Event Handlers
    private void MainWindow_LocationChanged(object? sender, EventArgs e)
    {
        // 处理窗口位置变化
        // 位置信息存储在Setting.WindowBounds中，这里可以选择不保存或使用WindowHandler
    }

    private void MainWindow_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // 处理窗口大小变化
        // 大小信息存储在Setting.WindowBounds中，这里可以选择不保存或使用WindowHandler
    }
    #endregion

    #region Title Bar Button Handlers

    private void CaptionLogButton_Click(object sender, RoutedEventArgs e)
    {
        // 切换字幕日志显示
        // 这个功能可以通过更新Setting.MainWindow.CaptionLogEnabled来实现
        if (Translator.Setting != null)
        {
            Translator.Setting.MainWindow.CaptionLogEnabled = !Translator.Setting.MainWindow.CaptionLogEnabled;
        }
    }

    public void LogOnlyButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (!IsTranslationRunning)
            {
                StartTranslation();
            }
            else
            {
                StopTranslation();
            }
        }
        catch (Exception ex)
        {
            ShowSnackbar("错误", $"操作失败: {ex.Message}", true);
        }
    }

    private void OverlayModeButton_Click(object sender, RoutedEventArgs e)
    {
        if (OverlayWindow == null)
        {
            OverlayWindow = new OverlayWindow();
            OverlayWindow.Closed += (s, args) => {
                OverlayWindow = null; 
                var icon = OverlayModeButton.Icon as SymbolIcon;
                if (icon != null) icon.Symbol = SymbolRegular.ClosedCaptionOff24;
            };
            
            var windowState = WindowHandler.LoadState(OverlayWindow, Translator.Setting);
            WindowHandler.RestoreState(OverlayWindow, windowState);
            OverlayWindow.Show();
            var iconShow = OverlayModeButton.Icon as SymbolIcon;
            if (iconShow != null) iconShow.Symbol = SymbolRegular.ClosedCaption24;
        }
        else
        {
            OverlayWindow.Close();
            OverlayWindow = null;
            var icon = OverlayModeButton.Icon as SymbolIcon;
            if (icon != null) icon.Symbol = SymbolRegular.ClosedCaptionOff24;
        }
    }

    private void TopmostButton_Click(object sender, RoutedEventArgs e)
    {
        this.Topmost = !this.Topmost;
        var icon = (TopmostButton.Icon as SymbolIcon);
        if (icon != null) icon.Filled = this.Topmost;
    }

    #endregion

    #region Overlay Window Management
    
    public void ShowOverlayWindow()
    {
        if (OverlayWindow == null)
        {
            OverlayWindow = new OverlayWindow();
            OverlayWindow.Closed += (s, args) => {
                OverlayWindow = null; 
            };
            
            var windowState = WindowHandler.LoadState(OverlayWindow, Translator.Setting);
            WindowHandler.RestoreState(OverlayWindow, windowState);
            OverlayWindow.Show();
        }
        else
        {
            OverlayWindow.Activate();
        }
    }

    #endregion

    private async void StartTranslation()
    {
        try
        {
            LogOnlyButton.IsEnabled = false;
            LogOnlyButton.ToolTip = "启动中...";

            Translator.ResetTranslation();

            bool initSuccess = await Task.Run(() =>
            {
                try
                {
                    Translator.InitializeLiveCaptions();
                    return Translator.Window != null;
                }
                catch
                {
                    return false;
                }
            });

            if (!initSuccess)
            {
                ShowSnackbar("错误", "无法启动 LiveCaptions，请检查系统是否支持", true);
                LogOnlyButton.ToolTip = "开始翻译";
                LogOnlyButton.IsEnabled = true;
                return;
            }

            Translator.ResetTranslation();
            _translationCancellationTokenSource = new CancellationTokenSource();
            
            Task.Run(() => Translator.SyncLoop());
            Task.Run(() => Translator.TranslateLoop());
            Task.Run(() => Translator.DisplayLoop());

            IsTranslationRunning = true;
            LogOnlyButton.ToolTip = "Pause Translation";
            (LogOnlyButton.Icon as SymbolIcon).Symbol = SymbolRegular.Pause24;
            LogOnlyButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            ShowSnackbar("错误", $"启动翻译失败: {ex.Message}", true);
            LogOnlyButton.ToolTip = "开始翻译";
            (LogOnlyButton.Icon as SymbolIcon).Symbol = SymbolRegular.Play24;
            LogOnlyButton.IsEnabled = true;
            IsTranslationRunning = false;
        }
    }

    private void StopTranslation()
    {
        try
        {
            LogOnlyButton.IsEnabled = false;
            LogOnlyButton.ToolTip = "停止中...";

            _translationCancellationTokenSource?.Cancel();
            _translationCancellationTokenSource?.Dispose();
            _translationCancellationTokenSource = null;

            Translator.StopTranslation();

            if (Translator.Window != null)
            {
                Translator.Window = null;
            }

            IsTranslationRunning = false;
            LogOnlyButton.ToolTip = "Start Translation";
            (LogOnlyButton.Icon as SymbolIcon).Symbol = SymbolRegular.Play24;
            LogOnlyButton.IsEnabled = true;
        }
        catch (Exception ex)
        {
            ShowSnackbar("错误", $"停止翻译失败: {ex.Message}", true);
            IsTranslationRunning = false;
            LogOnlyButton.ToolTip = "Start Translation";
            (LogOnlyButton.Icon as SymbolIcon).Symbol = SymbolRegular.Play24;
            LogOnlyButton.IsEnabled = true;
        }
    }

    public void AutoHeightAdjust(double minHeight = -1, double maxHeight = -1)
    {
        // This might need adjustment depending on how you want the main window to behave
    }

    public void ShowSnackbar(string title, string message, bool isError = false)
    {
        var snackbar = new Snackbar(SnackbarPresenter);
        snackbar.Title = title;
        snackbar.Content = message;
        snackbar.Show();
    }

    protected virtual void OnPropertyChanged([System.Runtime.CompilerServices.CallerMemberName] string propertyName = "")
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}