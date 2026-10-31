using System.Net.Http;
using System.Windows;
using System.Windows.Threading;
using LCT.Core.Models;
using LCT.Core.Translation;
using LiveCaptionsTranslator.Services.Ollama;
using LiveCaptionsTranslator.Services.Platform;
using LiveCaptionsTranslator.Services.Speech;
using LiveCaptionsTranslator.ViewModels;
using LiveCaptionsTranslator.Views;
using Serilog;

namespace LiveCaptionsTranslator;

/// <summary>
/// Application lifetime: logging, single instance, services, first-run wizard,
/// main window, tray icon, global hotkeys and the overlay. The app keeps
/// running in the tray after the main window is closed, so these live here.
/// </summary>
public partial class App : Application
{
    private Mutex? _singleInstance;
    private TranscriptionViewModel? _vm;
    private MainWindow? _mainWindow;
    private OverlayWindow? _overlay;
    private TrayIcon? _tray;
    private GlobalHotKeys? _hotKeys;
    private bool _exiting;

    public static new App Current => (App)Application.Current;
    public TranscriptionViewModel ViewModel => _vm ?? throw new InvalidOperationException("not initialized");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = new Mutex(true, "LCT.LiveCaptionsTranslator.SingleInstance", out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("LCT is already running. Look for its icon in the system tray.", "LCT", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        AppPaths.EnsureDirectories();
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Debug()
            .WriteTo.File(AppPaths.LogFile, rollingInterval: RollingInterval.Day, retainedFileCountLimit: 7, shared: true,
                outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
            .CreateLogger();
        Log.Information("LCT {Version} starting ({Build})", AppInfo.Version, AppInfo.BuildInfo);

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += (_, args) => { Log.Error(args.Exception, "Unobserved task exception"); args.SetObserved(); };

        var settings = AppSettings.Load(AppPaths.SettingsFile);
        var http = new HttpClient();
        var ollama = new OllamaClient(http, OllamaClientOptions.From(settings));
        var guardian = new OllamaGuardian();
        if (settings.ValidatedOllamaEndpoint is { } endpoint)
        {
            guardian.UseEndpoint(endpoint);
        }
        var modelManager = new OllamaModelManager(ollama);
        var whisperStore = new WhisperModelStore(AppPaths.WhisperModelsDirectory);

        if (!File.Exists(AppPaths.SetupCompleteMarker))
        {
            var welcomeVm = new WelcomeViewModel(settings, guardian, ollama, modelManager, whisperStore);
            var welcome = new WelcomeWindow { DataContext = welcomeVm };
            welcomeVm.Completed += () =>
            {
                welcome.Close();
                StartMain(settings, ollama, guardian, modelManager, whisperStore);
            };
            welcome.Closed += (_, _) =>
            {
                if (_vm == null && !_exiting)
                {
                    // Wizard dismissed without finishing: nothing else is open, so quit.
                    Shutdown();
                }
            };
            welcome.Show();
            return;
        }

        StartMain(settings, ollama, guardian, modelManager, whisperStore);
    }

    private void StartMain(AppSettings settings, OllamaClient ollama, OllamaGuardian guardian, OllamaModelManager modelManager, WhisperModelStore whisperStore)
    {
        _vm = new TranscriptionViewModel(settings, ollama, guardian, modelManager, whisperStore);
        _vm.SettingsChanged += OnSettingsChanged;

        _mainWindow = new MainWindow(_vm);
        _mainWindow.Show();

        _tray = new TrayIcon(_vm, ShowMainWindow, ToggleOverlay, ExitApplication, OpenSettings);
        if (settings.HotkeysEnabled)
        {
            RegisterHotKeys();
        }

        _ = _vm.PrepareModelOnLaunchAsync();
    }

    private void RegisterHotKeys()
    {
        if (_hotKeys != null)
        {
            return;
        }
        _hotKeys = new GlobalHotKeys();
        _hotKeys.Pressed += action =>
        {
            if (_vm == null) return;
            switch (action)
            {
                case HotKeyAction.ToggleCapture:
                    ShowMainWindow();
                    _ = _vm.ToggleCaptureAsync();
                    break;
                case HotKeyAction.TogglePause:
                    _vm.TogglePause();
                    break;
                case HotKeyAction.ToggleOverlay:
                    ToggleOverlay();
                    break;
            }
        };
        _hotKeys.RegisterDefaults();
    }

    private void OnSettingsChanged(AppSettings settings)
    {
        if (settings.HotkeysEnabled)
        {
            RegisterHotKeys();
        }
        else if (_hotKeys != null)
        {
            _hotKeys.Dispose();
            _hotKeys = null;
        }
        _overlay?.ApplySettings(settings);
    }

    public void ShowMainWindow()
    {
        if (_mainWindow == null)
        {
            return;
        }
        if (!_mainWindow.IsVisible)
        {
            _mainWindow.Show();
        }
        if (_mainWindow.WindowState == WindowState.Minimized)
        {
            _mainWindow.WindowState = WindowState.Normal;
        }
        _mainWindow.Activate();
    }

    public bool IsOverlayVisible => _overlay is { IsVisible: true };

    public void ToggleOverlay()
    {
        if (_vm == null)
        {
            return;
        }
        if (_overlay == null)
        {
            _overlay = new OverlayWindow(_vm);
            _overlay.Closed += (_, _) => _overlay = null;
        }
        if (_overlay.IsVisible)
        {
            _overlay.Hide();
        }
        else
        {
            _overlay.Show();
        }
        _tray?.Refresh();
    }

    public void OpenSettings()
    {
        if (_vm == null)
        {
            return;
        }
        ShowMainWindow();
        _mainWindow?.OpenSettings();
    }

    /// <summary>Called when the main window is closed by the user.</summary>
    public void OnMainWindowCloseRequested()
    {
        if (_vm?.Settings.MinimizeToTrayOnClose == true)
        {
            _mainWindow?.Hide();
            _tray?.ShowBalloon("LCT keeps running in the tray", "Double-click the tray icon to bring it back.");
        }
        else
        {
            ExitApplication();
        }
    }

    public void ExitApplication()
    {
        if (_exiting)
        {
            return;
        }
        _exiting = true;
        _ = ExitAsync();
    }

    private async Task ExitAsync()
    {
        try
        {
            _hotKeys?.Dispose();
            _tray?.Dispose();
            _overlay?.Close();
            if (_vm != null)
            {
                _mainWindow?.SaveBounds();
                _vm.SaveSettings();
                await _vm.ShutdownAsync();
                _vm.Dispose();
            }
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Exit failed");
        }
        finally
        {
            Log.Information("LCT exiting");
            Log.CloseAndFlush();
            Shutdown();
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Fatal(e.Exception, "Unhandled UI exception");
        MessageBox.Show("LCT hit an unexpected error:\n\n" + e.Exception.Message + "\n\nDetails were written to " + AppPaths.LogFile, "LCT", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
