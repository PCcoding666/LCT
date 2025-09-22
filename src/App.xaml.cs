﻿﻿﻿﻿﻿﻿﻿using System;
using System.Threading;
using System.Windows;
using LiveCaptionsTranslator.utils;
using LiveCaptionsTranslator.windows;
using Serilog;
using System.Threading.Tasks;

namespace LiveCaptionsTranslator
{
    public partial class App : Application
    {
        private const string AppMutexName = "LiveCaptionsTranslator-7E8A1B2C-F0A9-4AA4-A8AF-71354C4D5C2B";
        private Mutex? _mutex;

        private SplashWindow? _splashWindow;
        private MainWindow? _mainWindow;

        public App()
        {
            // Initialize logger
            var logPath = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LiveCaptionsTranslator",
                "logs",
                "log-.txt"
            );

            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Debug()
                .WriteTo.File(logPath, rollingInterval: RollingInterval.Day)
                .CreateLogger();

            Log.Information("Application starting up");

            // Global exception handler
            this.DispatcherUnhandledException += App_DispatcherUnhandledException;

            // Added: Capture non-UI thread exceptions to prevent unobserved Task exceptions from causing crashes
            AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
            TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;
        }

        private void App_DispatcherUnhandledException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
        {
            Log.Fatal(e.Exception, "An unhandled exception occurred");
            MessageBox.Show($"An unexpected error occurred. Please check the logs for more details.\nError: {e.Exception.Message}", "Fatal Error", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
            Shutdown(-1);
        }

        // Added: Non-UI thread unhandled exception handler
        private void CurrentDomain_UnhandledException(object? sender, UnhandledExceptionEventArgs e)
        {
            try
            {
                if (e.ExceptionObject is Exception ex)
                    Log.Fatal(ex, "AppDomain.CurrentDomain.UnhandledException");
                else
                    Log.Fatal("UnhandledException: {ExceptionObject}", e.ExceptionObject);
            }
            catch
            {
                // Ignore secondary exceptions to prevent recursion
            }
        }

        // Added: Task unobserved exception handler
        private void TaskScheduler_UnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
        {
            try
            {
                Log.Fatal(e.Exception, "TaskScheduler.UnobservedTaskException");
                e.SetObserved(); // Prevent CLR from forcibly terminating the process
            }
            catch
            {
                // Ignore
            }
        }

        protected override async void OnStartup(StartupEventArgs e)
        {
            _mutex = new Mutex(true, AppMutexName, out bool createdNew);

            if (!createdNew)
            {
                // App is already running
                MessageBox.Show("Application is already running.", "Information", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
            }

            Log.Information("OnStartup entered");
            // If test mode, skip WPF initialization and exit directly
            if (e.Args.Length > 0 && e.Args[0] == "--test")
            {
                Log.Information("Test mode detected, shutting down");
                Shutdown();
                return;
            }

            // Add enterprise mode detection
            bool enterpriseMode = CheckEnterpriseMode();
            Log.Information("Enterprise mode: {EnterpriseMode}", enterpriseMode);

            base.OnStartup(e);

            try
            {
                Log.Information("Creating and showing splash window");
                // Show splash screen
                _splashWindow = new SplashWindow();
                _splashWindow.Show();

                // Create progress reporter
                var progress = new Progress<string>(status =>
                {
                    _splashWindow?.UpdateStatus(status);
                });

                Log.Information("Starting startup checks");
                // Execute startup checks
                var startupManager = new StartupManager(_splashWindow, progress);
                if (await startupManager.PerformStartupChecks())
                {
                    Log.Information("Startup checks passed. Creating main window.");
                    
                    try
                    {
                        // Startup successful, check if welcome page needs to be displayed
                        bool isFirstRun = IsFirstRun();
                        Log.Information("First run: {IsFirstRun}", isFirstRun);
                        
                        // Create main window
                        Log.Information("Creating MainWindow instance");
                        _mainWindow = new MainWindow();
                        
                        Log.Information("Setting main window as application MainWindow");
                        // Set as main window
                        MainWindow = _mainWindow;
                        
                        Log.Information("Showing main window");
                        _mainWindow.Show();
                        
                        Log.Information("Main window shown, checking if it's visible");
                        Log.Information("Main window IsVisible: {IsVisible}, WindowState: {WindowState}", 
                            _mainWindow.IsVisible, _mainWindow.WindowState);
                        
                        Log.Information("Closing splash window");
                        _splashWindow.Close();
                        
                        // If first run, show welcome page
                        if (isFirstRun)
                        {
                            Log.Information("First run detected, showing welcome window");
                            var welcomeWindow = enterpriseMode ? 
                                (Window)new EnterpriseWelcomeWindow() : 
                                new WelcomeWindow();
                            welcomeWindow.Owner = _mainWindow;
                            welcomeWindow.ShowDialog();
                            
                            // After welcome page closes, automatically initialize LiveCaptions
                            Log.Information("Welcome window closed, initializing LiveCaptions");
                            try
                            {
                                Translator.InitializeLiveCaptions();
                                Log.Information("LiveCaptions initialized successfully");
                            }
                            catch (Exception liveCaptionsEx)
                            {
                                Log.Warning(liveCaptionsEx, "Failed to initialize LiveCaptions, but application can continue");
                            }
                        }
                        
                        Log.Information("OnStartup completed successfully");
                        
                        // Add a brief delay to observe window state
                        await Task.Delay(1000);
                        Log.Information("After 1 second delay - Main window IsVisible: {IsVisible}, WindowState: {WindowState}", 
                            _mainWindow.IsVisible, _mainWindow.WindowState);
                    }
                    catch (Exception ex)
                    {
                        Log.Error(ex, "Error during main window creation or display");
                        throw;
                    }
                }
                else
                {
                    Log.Warning("Startup checks failed.");
                    // Startup failed, show error message and exit
                    MessageBox.Show(
                        "Application initialization failed. Please check logs for detailed information.",
                        "Startup Failed",
                        MessageBoxButton.OK,
                        MessageBoxImage.Error
                    );
                    Log.Information("Shutting down due to startup check failure");
                    Shutdown(-1);
                }
            }
            catch (Exception ex)
            {
                Log.Error(ex, "An error occurred during application startup.");
                MessageBox.Show(
                    $"Application startup failed: {ex.Message}",
                    "Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error
                );
                Log.Information("Shutting down due to startup exception");
                Environment.Exit(-1);
            }
        }

        private bool CheckEnterpriseMode()
        {
            // Check if it's enterprise mode
            // 1. Check if installation path contains Dell
            string installPath = System.Reflection.Assembly.GetExecutingAssembly().Location;
            Log.Debug("Checking for enterprise mode. Install path: {InstallPath}", installPath);
            if (installPath.Contains("Dell") || installPath.Contains("dell"))
            {
                Log.Information("Enterprise mode detected based on install path.");
                return true;
            }

            // 2. Check for enterprise flag file
            string enterpriseFlagPath = System.IO.Path.Combine(
                System.IO.Path.GetDirectoryName(installPath) ?? "", 
                "enterprise.flag");
            
            var enterpriseFlagExists = System.IO.File.Exists(enterpriseFlagPath);
            Log.Debug("Enterprise flag at {FlagPath} exists: {Exists}", enterpriseFlagPath, enterpriseFlagExists);
            return enterpriseFlagExists;
        }

        private bool IsFirstRun()
        {
            // Check if it's first run
            string settingsFile = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LiveCaptionsTranslator",
                "first_run.flag");
            
            if (!System.IO.File.Exists(settingsFile))
            {
                Log.Information("First run detected. Creating flag file at {FlagPath}", settingsFile);
                // Create first run flag file
                try
                {
                    System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(settingsFile) ?? "");
                    System.IO.File.WriteAllText(settingsFile, DateTime.Now.ToString());
                    return true;
                }
                catch(Exception ex)
                {
                    Log.Error(ex, "Failed to create first run flag file.");
                    return true; // If unable to create file, still treat as first run
                }
            }
            
            Log.Debug("Not first run. Flag file exists at {FlagPath}", settingsFile);
            return false;
        }

        protected override void OnExit(ExitEventArgs e)
        {
            Log.Information("Application exiting.");
            // Ensure Ollama server is properly stopped
            OllamaGuardian.StopServer();
            _mutex?.ReleaseMutex();
            _mutex?.Dispose();
            base.OnExit(e);
            Log.CloseAndFlush();
        }
    }
}
