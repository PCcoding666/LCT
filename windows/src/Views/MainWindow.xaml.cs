using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using LCT.Core.Models;
using LCT.Core.Session;
using LiveCaptionsTranslator.Services.Platform;
using LiveCaptionsTranslator.ViewModels;
using Microsoft.Win32;

namespace LiveCaptionsTranslator.Views;

public sealed class NoticeActionLabelConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is NoticeAction a ? a.Label() : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public partial class MainWindow : Window
{
    private readonly TranscriptionViewModel _vm;
    private SettingsWindow? _settings;
    private HistoryWindow? _history;
    private bool _autoScroll = true;
    private bool _programmaticScroll;

    public RelayCommand NoticeActionCommand { get; }

    public MainWindow(TranscriptionViewModel vm)
    {
        _vm = vm;
        DataContext = vm;
        NoticeActionCommand = new RelayCommand(p => { if (p is NoticeAction action) _ = _vm.PerformAsync(action); });
        InitializeComponent();
        WindowPlacement.Apply(this, vm.Settings.MainWindowBounds);
        _vm.Segments.CollectionChanged += OnSegmentsChanged;
        _vm.PropertyChanged += OnViewModelPropertyChanged;
        _vm.OpenSettingsRequested += OpenSettings;
        Closing += OnClosing;
    }

    public void SaveBounds()
    {
        _vm.Settings.MainWindowBounds = WindowPlacement.Serialize(this);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        SaveBounds();
        if (App.Current.IsExiting)
        {
            return; // real shutdown: let the window go
        }
        _vm.SaveSettings();
        e.Cancel = true;
        App.Current.OnMainWindowCloseRequested();
    }

    // ---- Feed scrolling ----

    private void OnSegmentsChanged(object? sender, NotifyCollectionChangedEventArgs e) => ScrollToEndIfNeeded();

    private void OnViewModelPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TranscriptionViewModel.LiveSourceText) or nameof(TranscriptionViewModel.LiveTranslation))
        {
            ScrollToEndIfNeeded();
        }
    }

    private void ScrollToEndIfNeeded()
    {
        if (!_autoScroll)
        {
            return;
        }
        _programmaticScroll = true;
        Dispatcher.BeginInvoke(() =>
        {
            FeedScroll.ScrollToEnd();
            _programmaticScroll = false;
        });
    }

    private void FeedScroll_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_programmaticScroll || e.VerticalChange == 0)
        {
            return;
        }
        var atBottom = FeedScroll.VerticalOffset >= FeedScroll.ScrollableHeight - 2;
        if (!atBottom && _autoScroll && e.VerticalChange < 0)
        {
            SetAutoScroll(false);
        }
        else if (atBottom && !_autoScroll)
        {
            SetAutoScroll(true);
        }
    }

    private void SetAutoScroll(bool enabled)
    {
        _autoScroll = enabled;
        AutoScrollToggle.IsChecked = enabled;
        LatestButton.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
    }

    private void AutoScroll_Changed(object sender, RoutedEventArgs e)
    {
        SetAutoScroll(AutoScrollToggle.IsChecked == true);
        ScrollToEndIfNeeded();
    }

    private void Latest_Click(object sender, RoutedEventArgs e)
    {
        SetAutoScroll(true);
        ScrollToEndIfNeeded();
    }

    // ---- HUD actions ----

    private void Capture_Click(object sender, RoutedEventArgs e) => _ = _vm.ToggleCaptureAsync();
    private void Pause_Click(object sender, RoutedEventArgs e) => _vm.TogglePause();
    private void Clear_Click(object sender, RoutedEventArgs e) => _vm.Clear();
    private void DismissNotice_Click(object sender, RoutedEventArgs e) => _vm.DismissNotice();
    private void OllamaIndicator_Click(object sender, RoutedEventArgs e)
    {
        if (!_vm.OllamaUp)
        {
            _ = _vm.StartOllamaFromIndicatorAsync();
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => OpenSettings();

    public void OpenSettings()
    {
        if (_settings is { IsVisible: true })
        {
            _settings.Activate();
            return;
        }
        _settings = new SettingsWindow(_vm) { Owner = this };
        _settings.Closed += (_, _) => _settings = null;
        _settings.Show();
    }

    private void History_Click(object sender, RoutedEventArgs e)
    {
        if (_history is { IsVisible: true })
        {
            _history.Activate();
            return;
        }
        _history = new HistoryWindow(_vm) { Owner = this };
        _history.Closed += (_, _) => _history = null;
        _history.Show();
    }

    // ---- Language menu (built in code: items depend on settings) ----

    private void LanguageButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu { PlacementTarget = LanguageButton, Placement = PlacementMode.Bottom };
        var s = _vm.Settings;

        menu.Items.Add(new MenuItem { Header = "SYSTEM AUDIO", Style = (Style)FindResource("MenuSectionHeader") });
        foreach (var language in LanguageInfo.AllSources)
        {
            var item = new MenuItem { Header = language.DisplayName(), IsChecked = s.SourceLanguage == language };
            var captured = language;
            item.Click += (_, _) => _ = _vm.SetSourceLanguageAsync(captured, AudioSource.System);
            menu.Items.Add(item);
        }

        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = "MICROPHONE", Style = (Style)FindResource("MenuSectionHeader") });
        var same = new MenuItem { Header = "Same as System Audio", IsChecked = s.MicrophoneSourceLanguage == null };
        same.Click += (_, _) => _ = _vm.SetSourceLanguageAsync(null, AudioSource.Microphone);
        menu.Items.Add(same);
        var micMenu = new MenuItem { Header = "Choose language" };
        foreach (var language in LanguageInfo.AllSources)
        {
            var item = new MenuItem { Header = language.DisplayName(), IsChecked = s.MicrophoneSourceLanguage == language };
            var captured = language;
            item.Click += (_, _) => _ = _vm.SetSourceLanguageAsync(captured, AudioSource.Microphone);
            micMenu.Items.Add(item);
        }
        menu.Items.Add(micMenu);

        menu.Items.Add(new Separator());
        menu.Items.Add(new MenuItem { Header = "TRANSLATE TO", Style = (Style)FindResource("MenuSectionHeader") });
        foreach (var target in LanguageInfo.AllTargets)
        {
            var item = new MenuItem { Header = $"{target.DisplayName()} ({target.NativeName()})", IsChecked = s.TargetLanguage == target };
            var captured = target;
            item.Click += (_, _) => _ = _vm.SetTargetLanguageAsync(captured);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    // ---- Export ----

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (ExportButton.ContextMenu != null)
        {
            ExportButton.ContextMenu.PlacementTarget = ExportButton;
            ExportButton.ContextMenu.Placement = PlacementMode.Bottom;
            ExportButton.ContextMenu.IsOpen = true;
        }
    }

    private void ExportMarkdown_Click(object sender, RoutedEventArgs e) => Export(ExportFormat.Markdown);
    private void ExportText_Click(object sender, RoutedEventArgs e) => Export(ExportFormat.PlainText);
    private void ExportSrt_Click(object sender, RoutedEventArgs e) => Export(ExportFormat.Srt);

    private void Export(ExportFormat format)
    {
        var export = _vm.BuildExport(format);
        if (export == null)
        {
            _vm.ShowInfo("Nothing to export yet.");
            return;
        }
        var dialog = new SaveFileDialog
        {
            FileName = export.Value.FileName,
            Filter = format.FilterName(),
            DefaultExt = format.FileExtension(),
            Title = "Export session",
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            File.WriteAllText(dialog.FileName, export.Value.Content, new System.Text.UTF8Encoding(false));
            _vm.ShowInfo($"Exported {Path.GetFileName(dialog.FileName)}");
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Export failed: " + ex.Message, "LCT", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
