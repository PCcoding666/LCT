using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using Hardcodet.Wpf.TaskbarNotification;
using LiveCaptionsTranslator.ViewModels;

namespace LiveCaptionsTranslator.Services.Platform;

/// <summary>System tray icon: show window, overlay, start/stop, pause, settings, exit.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly TaskbarIcon _icon;
    private readonly TranscriptionViewModel _vm;
    private readonly MenuItem _captureItem;
    private readonly MenuItem _pauseItem;
    private readonly MenuItem _overlayItem;
    private readonly Func<bool> _isOverlayVisible;

    public TrayIcon(TranscriptionViewModel vm, Action showWindow, Action toggleOverlay, Action exit, Action openSettings)
    {
        _vm = vm;
        _isOverlayVisible = () => App.Current.IsOverlayVisible;
        var menu = new ContextMenu();

        var show = new MenuItem { Header = "Show LCT" };
        show.Click += (_, _) => showWindow();
        _overlayItem = new MenuItem { Header = "Show Overlay" };
        _overlayItem.Click += (_, _) => toggleOverlay();
        _captureItem = new MenuItem { Header = "Start Capture" };
        _captureItem.Click += (_, _) => _ = _vm.ToggleCaptureAsync();
        _pauseItem = new MenuItem { Header = "Pause" };
        _pauseItem.Click += (_, _) => _vm.TogglePause();
        var settings = new MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => openSettings();
        var quit = new MenuItem { Header = "Exit" };
        quit.Click += (_, _) => exit();

        menu.Items.Add(show);
        menu.Items.Add(_overlayItem);
        menu.Items.Add(new Separator());
        menu.Items.Add(_captureItem);
        menu.Items.Add(_pauseItem);
        menu.Items.Add(new Separator());
        menu.Items.Add(settings);
        menu.Items.Add(quit);

        _icon = new TaskbarIcon
        {
            IconSource = new BitmapImage(new Uri("pack://application:,,,/images/LCT_logo.ico")),
            ToolTipText = "LCT — idle",
            ContextMenu = menu,
        };
        _icon.TrayMouseDoubleClick += (_, _) => showWindow();
        _icon.TrayLeftMouseUp += (_, _) => showWindow();
        _vm.PropertyChanged += OnViewModelChanged;
        Refresh();
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TranscriptionViewModel.CaptureState) or nameof(TranscriptionViewModel.IsPaused) or nameof(TranscriptionViewModel.LanguageLabelText))
        {
            Refresh();
        }
    }

    public void Refresh()
    {
        _captureItem.Header = _vm.IsCapturing ? "Stop Capture" : "Start Capture";
        _captureItem.IsEnabled = !_vm.IsBusy;
        _pauseItem.Header = _vm.IsPaused ? "Resume" : "Pause";
        _pauseItem.IsEnabled = _vm.IsCapturing;
        _overlayItem.Header = _isOverlayVisible() ? "Hide Overlay" : "Show Overlay";
        _icon.ToolTipText = _vm.IsCapturing
            ? (_vm.IsPaused ? "LCT — paused" : $"LCT — recording · {_vm.LanguageLabelText}")
            : "LCT — idle";
    }

    public void ShowBalloon(string title, string message)
    {
        try
        {
            _icon.ShowBalloonTip(title, message, BalloonIcon.Info);
        }
        catch (Exception)
        {
            // Balloons are best-effort.
        }
    }

    public void Dispose()
    {
        _vm.PropertyChanged -= OnViewModelChanged;
        _icon.Dispose();
    }
}
