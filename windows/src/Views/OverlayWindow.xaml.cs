using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using LCT.Core.Models;
using LiveCaptionsTranslator.Services.Platform;
using LiveCaptionsTranslator.ViewModels;

namespace LiveCaptionsTranslator.Views;

/// <summary>
/// Floating subtitle window: borderless, topmost, draggable, resizable, click-through
/// when configured, remembers its position and size.
/// </summary>
public partial class OverlayWindow : Window
{
    private readonly TranscriptionViewModel _vm;
    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(600) };
    private nint _hwnd;

    public OverlayWindow(TranscriptionViewModel vm)
    {
        _vm = vm;
        DataContext = vm;
        InitializeComponent();
        RestorePlacement(vm.Settings);
        Topmost = vm.Settings.OverlayStayOnTop;
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            NativeMethods.SetExtendedStyle(_hwnd, NativeMethods.WS_EX_TOOLWINDOW, true);
            ApplyClickThrough(vm.Settings.OverlayClickThrough);
        };
        LocationChanged += (_, _) => ScheduleSave();
        SizeChanged += (_, _) => ScheduleSave();
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); SavePlacement(); };
    }

    public void ApplySettings(AppSettings settings)
    {
        Topmost = settings.OverlayStayOnTop;
        ApplyClickThrough(settings.OverlayClickThrough);
        if (Math.Abs(Width - settings.OverlayWidth) > 1 || Math.Abs(Height - settings.OverlayHeight) > 1)
        {
            Width = settings.OverlayWidth;
            Height = settings.OverlayHeight;
        }
    }

    private void ApplyClickThrough(bool enabled)
    {
        if (_hwnd != nint.Zero)
        {
            NativeMethods.SetExtendedStyle(_hwnd, NativeMethods.WS_EX_TRANSPARENT, enabled);
        }
        Shell.Cursor = enabled ? Cursors.Arrow : Cursors.SizeAll;
    }

    private void RestorePlacement(AppSettings settings)
    {
        Width = Math.Max(MinWidth, settings.OverlayWidth);
        Height = Math.Max(MinHeight, settings.OverlayHeight);
        var screen = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        if ((settings.OverlayPositionX != 0 || settings.OverlayPositionY != 0) && screen.Contains(new Point(settings.OverlayPositionX, settings.OverlayPositionY)))
        {
            Left = settings.OverlayPositionX;
            Top = settings.OverlayPositionY;
        }
        else
        {
            var work = SystemParameters.WorkArea;
            Left = work.Right - Width - 20;
            Top = work.Top + 20;
        }
    }

    private void ScheduleSave()
    {
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void SavePlacement()
    {
        if (WindowState != WindowState.Normal)
        {
            return;
        }
        var s = _vm.Settings;
        s.OverlayPositionX = Left;
        s.OverlayPositionY = Top;
        s.OverlayWidth = ActualWidth;
        s.OverlayHeight = ActualHeight;
        _vm.SaveSettings();
    }

    private void Shell_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch (InvalidOperationException) { }
        }
    }

    private void Shell_MouseEnter(object sender, MouseEventArgs e) => Header.Visibility = Visibility.Visible;
    private void Shell_MouseLeave(object sender, MouseEventArgs e) => Header.Visibility = Visibility.Collapsed;
    private void Pause_Click(object sender, RoutedEventArgs e) => _vm.TogglePause();
    private void Hide_Click(object sender, RoutedEventArgs e) => Hide();

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        var text = _vm.LatestTranslationText;
        if (!string.IsNullOrEmpty(text))
        {
            try { Clipboard.SetText(text); } catch (Exception) { }
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        SavePlacement();
        base.OnClosed(e);
    }
}
