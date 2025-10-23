﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿﻿using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Automation;
using System.Windows.Threading;
using System.Text.Json;
using System.Speech.Synthesis;

using LiveCaptionsTranslator.models;
using LiveCaptionsTranslator.utils;

namespace LiveCaptionsTranslator
{
    public static class Translator
    {
        private static AutomationElement? window = null;
        private static Caption? caption = null;
        private static Setting? setting = null;
        public static MainWindow? MainWindow { get; set; }

        private static readonly Queue<string> pendingTextQueue = new();
        private static readonly TranslationTaskQueue translationTaskQueue = new();

        // Add flag for stopping translation
        private static volatile bool _isTranslationStopped = false;
        private static readonly object _stopLock = new object();
        
        // Add flag for pausing translation
        private static volatile bool _isTranslationPaused = false;
        private static readonly object _pauseLock = new object();
        
        public static bool IsPaused
        {
            get
            {
                lock (_pauseLock)
                {
                    return _isTranslationPaused;
                }
            }
            set
            {
                lock (_pauseLock)
                {
                    _isTranslationPaused = value;
                    Console.WriteLine($"Translator.IsPaused set to: {value}");
                }
            }
        }

        public static AutomationElement? Window
        {
            get => window;
            set => window = value;
        }
        public static Caption? Caption => caption;
        public static Setting? Setting => setting;

        public static bool LogOnlyFlag { get; set; } = false;
        private static bool _firstUseFlag;
        public static bool FirstUseFlag
        {
            get => _firstUseFlag;
            set => _firstUseFlag = value;
        }

        public static event Action? TranslationLogged;

        // Add method to stop translation
        public static void StopTranslation()
        {
            lock (_stopLock)
            {
                Console.WriteLine("Translator.StopTranslation: Setting stop flag");
                _isTranslationStopped = true;
                
                // Clear pending queue
                pendingTextQueue.Clear();
                
                // Clear translation task queue
                translationTaskQueue.Clear();
                
                // 🔥 New: Also try to clean up Ollama processes when stopping translation to free GPU memory
                try
                {
                    Console.WriteLine("Translator.StopTranslation: Attempting to clean up Ollama processes");
                    OllamaGuardian.StopServer();
                    Console.WriteLine("Translator.StopTranslation: Ollama cleanup completed");
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Translator.StopTranslation: Ollama cleanup failed: {ex.Message}");
                    // Do not throw exception, because cleanup failure should not block translation stopping
                }
                
                // 🔥 New: Try to unload model via API
                _ = Task.Run(async () =>
                {
                    try
                    {
                        Console.WriteLine("Translator.StopTranslation: Attempting to unload model via API");
                        bool unloadSuccess = await TranslateAPI.UnloadModel();
                        if (unloadSuccess)
                        {
                            Console.WriteLine("Translator.StopTranslation: Model unloaded successfully via API");
                        }
                        else
                        {
                            Console.WriteLine("Translator.StopTranslation: Model unload via API failed or incomplete");
                        }
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"Translator.StopTranslation: Model unload via API exception: {ex.Message}");
                    }
                });
                
                Console.WriteLine("Translator.StopTranslation: Translation stopped and queues cleared");
            }
        }

        // Add method to restart translation
        public static void ResetTranslation()
        {
            lock (_stopLock)
            {
                Console.WriteLine("Translator.ResetTranslation: Resetting translation state");
                _isTranslationStopped = false;
            }
        }

        // Check if translation should be stopped
        private static bool ShouldStopTranslation()
        {
            lock (_stopLock)
            {
                return _isTranslationStopped;
            }
        }

        static Translator()
        {
            try
            {
                // No longer automatically start LiveCaptions, change to lazy initialization
                // window = LiveCaptionsHandler.LaunchLiveCaptions();
                // LiveCaptionsHandler.FixLiveCaptions(Window);
                // LiveCaptionsHandler.HideLiveCaptions(Window);

                // Use same first run check logic as App.xaml.cs
                string firstRunFlagPath = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "LCT",
                    "first_run.flag");
                
                FirstUseFlag = !File.Exists(firstRunFlagPath);

                caption = Caption.GetInstance();
                setting = Setting.Load();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Translator static constructor failed: {ex.Message}");
                // Ensure basic objects are not null
                caption = Caption.GetInstance();
                setting = new Setting(); // Use default settings
                FirstUseFlag = false; // Do not show first-use interface on error to avoid further problems
            }
        }

        // New: Method to manually initialize LiveCaptions
        public static void InitializeLiveCaptions()
        {
            try
            {
                Console.WriteLine("InitializeLiveCaptions: Starting initialization");
                
                if (window == null)
                {
                    Console.WriteLine("InitializeLiveCaptions: Window is null, launching LiveCaptions");
                    // Clear UI element cache to ensure getting latest state
                    LiveCaptionsHandler.ClearElementCache();
                    window = LiveCaptionsHandler.LaunchLiveCaptions();
                    Console.WriteLine("InitializeLiveCaptions: LiveCaptions launched successfully");
                    
                    Console.WriteLine("InitializeLiveCaptions: Fixing LiveCaptions window position");
                    LiveCaptionsHandler.FixLiveCaptions(Window);
                    Console.WriteLine("InitializeLiveCaptions: Window position fixed");
                    
                    Console.WriteLine("InitializeLiveCaptions: Hiding LiveCaptions window");
                    LiveCaptionsHandler.HideLiveCaptions(Window);
                    Console.WriteLine("InitializeLiveCaptions: Window hidden successfully");
                }
                else
                {
                    Console.WriteLine("InitializeLiveCaptions: Window already exists, skipping initialization");
                }
                
                Console.WriteLine("InitializeLiveCaptions: Initialization completed successfully");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"InitializeLiveCaptions failed: {ex.Message}");
                Console.WriteLine($"InitializeLiveCaptions stack trace: {ex.StackTrace}");
                window = null; // Ensure window is null on failure
                throw; // Re-throw exception to let caller know it failed
            }
        }

        public static void SyncLoop()
        {
            int idleCount = 0;
            int syncCount = 0;
            int emptyTextCount = 0;

            Console.WriteLine("Translator.SyncLoop: Starting sync loop");

            while (!ShouldStopTranslation())
            {
                if (Window == null)
                {
                    Console.WriteLine("Translator.SyncLoop: Window is null, initializing LiveCaptions");
                    // Clear UI element cache to ensure getting latest state after reconnection
                    LiveCaptionsHandler.ClearElementCache();
                    // Initialize LiveCaptions only when needed
                    InitializeLiveCaptions();
                    if (Window == null)
                    {
                        Console.WriteLine("Translator.SyncLoop: Failed to initialize LiveCaptions, retrying in 2 seconds");
                        Thread.Sleep(2000);
                        continue;
                    }
                    Console.WriteLine("Translator.SyncLoop: LiveCaptions initialized successfully");
                }

                string fullText = string.Empty;
                try
                {
                    // Check LiveCaptions.exe still alive
                    var info = Window.Current;
                    var name = info.Name;
                    // Get the text recognized by LiveCaptions (10-20ms)
                    fullText = LiveCaptionsHandler.GetCaptions(Window);
                }
                catch (ElementNotAvailableException ex)
                {
                    Console.WriteLine($"Translator.SyncLoop: LiveCaptions element not available: {ex.Message}");
                    Window = null;
                    continue;
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Translator.SyncLoop: Error getting captions: {ex.Message}");
                    continue;
                }
                
                if (string.IsNullOrEmpty(fullText))
                {
                    emptyTextCount++;
                    if (emptyTextCount % 200 == 0) // Print once every 5 seconds (25ms * 200 = 5s)
                    {
                        Console.WriteLine($"Translator.SyncLoop: No text captured from LiveCaptions (count: {emptyTextCount})");
                    }
                    continue;
                }
                
                if (emptyTextCount > 0)
                {
                    Console.WriteLine($"Translator.SyncLoop: Got text after {emptyTextCount} empty attempts: '{fullText.Substring(0, Math.Min(50, fullText.Length))}...'");
                    emptyTextCount = 0;
                }

                // Preprocess
                fullText = RegexPatterns.Acronym().Replace(fullText, "$1$2");
                fullText = RegexPatterns.AcronymWithWords().Replace(fullText, "$1 $2");
                fullText = RegexPatterns.PunctuationSpace().Replace(fullText, "$1 ");
                fullText = RegexPatterns.CJPunctuationSpace().Replace(fullText, "$1");
                // Note: For certain languages (such as Japanese), LiveCaptions excessively uses `\n`.
                // Replace redundant `\n` within sentences with comma or period.
                fullText = TextUtil.ReplaceNewlines(fullText, TextUtil.MEDIUM_THRESHOLD);

                // Prevent adding the last sentence from previous running to log cards
                // before the first sentence is completed.
                if (fullText.IndexOfAny(TextUtil.PUNC_EOS) == -1 && Caption.Contexts.Count > 0)
                {
                    Caption.Contexts.Clear();
                    Caption.OnPropertyChanged("DisplayContexts");
                }

                // Get the last sentence.
                int lastEOSIndex;
                if (Array.IndexOf(TextUtil.PUNC_EOS, fullText[^1]) != -1)
                    lastEOSIndex = fullText[0..^1].LastIndexOfAny(TextUtil.PUNC_EOS);
                else
                    lastEOSIndex = fullText.LastIndexOfAny(TextUtil.PUNC_EOS);
                string latestCaption = fullText.Substring(lastEOSIndex + 1);

                // If the last sentence is too short, extend it by adding the previous sentence.
                // Note: LiveCaptions may generate multiple characters including EOS at once.
                if (lastEOSIndex > 0 && Encoding.UTF8.GetByteCount(latestCaption) < TextUtil.SHORT_THRESHOLD)
                {
                    lastEOSIndex = fullText[0..lastEOSIndex].LastIndexOfAny(TextUtil.PUNC_EOS);
                    latestCaption = fullText.Substring(lastEOSIndex + 1);
                }

                // `OverlayOriginalCaption`: The sentence to be displayed on Overlay Window.
                Caption.OverlayOriginalCaption = latestCaption;
                for (int historyCount = Math.Min(Setting.OverlayWindow.HistoryMax, Caption.Contexts.Count);
                     historyCount > 0 && lastEOSIndex > 0;
                     historyCount--)
                {
                    lastEOSIndex = fullText[0..lastEOSIndex].LastIndexOfAny(TextUtil.PUNC_EOS);
                    Caption.OverlayOriginalCaption = fullText.Substring(lastEOSIndex + 1);
                }
                // Caption.DisplayOriginalCaption =
                //     TextUtil.ShortenDisplaySentence(Caption.OverlayOriginalCaption, TextUtil.VERYLONG_THRESHOLD);

                // `DisplayOriginalCaption`: The sentence to be displayed on Main Window.
                if (string.CompareOrdinal(Caption.DisplayOriginalCaption, latestCaption) != 0)
                {
                    Caption.DisplayOriginalCaption = latestCaption;
                    // If the last sentence is too long, truncate it when displayed.
                    Caption.DisplayOriginalCaption =
                        TextUtil.ShortenDisplaySentence(Caption.DisplayOriginalCaption, TextUtil.VERYLONG_THRESHOLD);
                }

                // Prepare for `OriginalCaption`. If Expanded, only retain the complete sentence.
                int lastEOS = latestCaption.LastIndexOfAny(TextUtil.PUNC_EOS);
                if (lastEOS != -1)
                    latestCaption = latestCaption.Substring(0, lastEOS + 1);
                // `OriginalCaption`: The sentence to be really translated.
                if (string.CompareOrdinal(Caption.OriginalCaption, latestCaption) != 0)
                {
                    Caption.OriginalCaption = latestCaption;

                    idleCount = 0;
                    if (Array.IndexOf(TextUtil.PUNC_EOS, Caption.OriginalCaption[^1]) != -1)
                    {
                        syncCount = 0;
                        pendingTextQueue.Enqueue(Caption.OriginalCaption);
                    }
                    else if (Encoding.UTF8.GetByteCount(Caption.OriginalCaption) >= TextUtil.SHORT_THRESHOLD)
                        syncCount++;
                }
                else
                    idleCount++;

                // `TranslateFlag` determines whether this sentence should be translated.
                // When `OriginalCaption` remains unchanged, `idleCount` +1; when `OriginalCaption` changes, `MaxSyncInterval` +1.
                if (syncCount > Setting.MaxSyncInterval ||
                    idleCount == Setting.MaxIdleInterval)
                {
                    syncCount = 0;
                    pendingTextQueue.Enqueue(Caption.OriginalCaption);
                }

                Thread.Sleep(25);
            }
            
            Console.WriteLine("Translator.SyncLoop: Sync loop stopped");
        }

        public static async Task TranslateLoop()
        {
            Console.WriteLine("Translator.TranslateLoop: Starting translate loop");
            
            // Set GC to low latency mode to reduce GC pauses during translation
            var originalLatencyMode = System.Runtime.GCSettings.LatencyMode;
            System.Runtime.GCSettings.LatencyMode = System.Runtime.GCLatencyMode.LowLatency;
            Console.WriteLine($"Translator.TranslateLoop: GC latency mode set to {System.Runtime.GCSettings.LatencyMode}");
            
            try
            {
                int loopCount = 0;
                
                while (!ShouldStopTranslation())
            {
                loopCount++;
                if (loopCount % 250 == 0) // Print once every 10 seconds (40ms * 250 = 10s)
                {
                    Console.WriteLine($"Translator.TranslateLoop: Still running (loop: {loopCount}, pending: {pendingTextQueue.Count}, active: {translationTaskQueue.ActiveTasksCount}, total: {translationTaskQueue.QueueLength})");
                }
                
                // Check LiveCaptions.exe still alive
                if (Window == null)
                {
                    Console.WriteLine("Translator.TranslateLoop: LiveCaptions window is null, restarting...");
                    Caption.DisplayTranslatedCaption = "[WARNING] LiveCaptions was unexpectedly closed, restarting...";
                    Window = LiveCaptionsHandler.LaunchLiveCaptions();
                    Caption.DisplayTranslatedCaption = "";
                }

                // Translate
                if (pendingTextQueue.Count > 0)
                {
                    var originalSnapshot = pendingTextQueue.Dequeue();
                    Console.WriteLine($"Translator.TranslateLoop: Processing text: '{originalSnapshot.Substring(0, Math.Min(30, originalSnapshot.Length))}...'");

                    // 📊 New: Simple system resource pressure detection
                    bool isSystemUnderPressure = pendingTextQueue.Count > 5 || translationTaskQueue.QueueLength > 8;
                    
                    if (LogOnlyFlag)
                    {
                        bool isOverwrite = await IsOverwrite(originalSnapshot);
                        await LogOnly(originalSnapshot, isOverwrite);
                    }
                    else if (isSystemUnderPressure)
                    {
                        Console.WriteLine($"Translator.TranslateLoop: System under pressure - skipping translation (pending: {pendingTextQueue.Count}, queue: {translationTaskQueue.QueueLength})");
                        // Show simple hint instead of error during high load
                        Caption.DisplayTranslatedCaption = "[BUSY] System processing, please wait...";
                    }
                    else
                    {
                        // 🔥 Anti-accumulation mechanism: Skip translation if there are too many active tasks in the queue
                        if (translationTaskQueue.ActiveTasksCount < 1) // 🔥 Reduce to 1 concurrent task to completely solve HttpClient conflicts
                        {
                            translationTaskQueue.Enqueue(token => Task.Run(
                                () => Translate(originalSnapshot, token), token), originalSnapshot);
                            Console.WriteLine($"Translator.TranslateLoop: Translation task enqueued (active: {translationTaskQueue.ActiveTasksCount})");
                        }
                        else
                        {
                            Console.WriteLine($"Translator.TranslateLoop: Skipping translation due to queue backlog (active: {translationTaskQueue.ActiveTasksCount})");
                        }
                    }
                }

                await Task.Delay(40);
                }
                
                Console.WriteLine("Translator.TranslateLoop: Translate loop stopped");
            }
            finally
            {
                // Ensure original GC latency mode is restored no matter what
                System.Runtime.GCSettings.LatencyMode = originalLatencyMode;
                Console.WriteLine($"Translator.TranslateLoop: GC latency mode restored to {System.Runtime.GCSettings.LatencyMode}");
            }
        }

        public static async Task DisplayLoop()
        {
            Console.WriteLine("Translator.DisplayLoop: Starting display loop");
            
            while (!ShouldStopTranslation())
            {
                var (translatedText, isChoke) = translationTaskQueue.Output;

                if (LogOnlyFlag || IsPaused)
                {
                    Caption.TranslatedCaption = string.Empty;
                    Caption.DisplayTranslatedCaption = "[Paused]";
                    Caption.OverlayTranslatedCaption = "[Paused]";
                }
                else if (!string.IsNullOrEmpty(RegexPatterns.NoticePrefix().Replace(
                             translatedText, string.Empty).Trim()) &&
                         string.CompareOrdinal(Caption.TranslatedCaption, translatedText) != 0)
                {
                    // Main page
                    Caption.TranslatedCaption = translatedText;
                    Caption.DisplayTranslatedCaption =
                        TextUtil.ShortenDisplaySentence(Caption.TranslatedCaption, TextUtil.VERYLONG_THRESHOLD);

                    // Overlay window
                    if (Caption.TranslatedCaption.Contains("[ERROR]") || Caption.TranslatedCaption.Contains("[WARNING]"))
                        Caption.OverlayTranslatedCaption = Caption.TranslatedCaption;
                    else
                        Caption.OverlayTranslatedCaption = Caption.OverlayOriginalCaption + "\n" + Caption.TranslatedCaption;

                    // Log
                    bool isOverwrite = await IsOverwrite(Caption.OriginalCaption);
                    await Log(Caption.OriginalCaption, Caption.TranslatedCaption, isOverwrite);
                }

                await Task.Delay(40);
            }
            
            Console.WriteLine("Translator.DisplayLoop: Display loop stopped");
        }

        public static async Task<(string, bool)> Translate(string text, CancellationToken token = default)
        {
            string translatedText;
            bool isChoke = Array.IndexOf(TextUtil.PUNC_EOS, text[^1]) != -1;
            
            try
            {
                // Start timing only before actual translation call
                var sw = Setting.MainWindow.LatencyShow ? Stopwatch.StartNew() : null;
                
                if (Setting.ContextAware && !TranslateAPI.IsLLMBased)
                {
                    translatedText = await TranslateAPI.TranslateFunction($"{Caption.ContextPreviousCaption} <[{text}]>", token);
                    translatedText = RegexPatterns.TargetSentence().Match(translatedText).Groups[1].Value;
                }
                else
                {
                    translatedText = await TranslateAPI.TranslateFunction(text, token);
                    translatedText = translatedText.Replace("🔤", "");
                }
                
                // Stop timing immediately to ensure only pure translation time is counted
                if (sw != null)
                {
                    sw.Stop();
                    var actualLatency = sw.ElapsedMilliseconds;
                    // Add debug info to verify latency calculation
                    Console.WriteLine($"Translation completed - Pure latency: {actualLatency} ms");
                    translatedText = $"[{actualLatency} ms] " + translatedText;
                }
            }
            catch (OperationCanceledException ex)
            {
                throw;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[ERROR] Translation Failed: {ex.Message}");
                return ($"[ERROR] Translation Failed: {ex.Message}", isChoke);
            }

            return (translatedText, isChoke);
        }

        public static async Task Log(string originalText, string translatedText,
            bool isOverwrite = false, CancellationToken token = default)
        {
            string targetLanguage, apiName;
            if (Setting != null)
            {
                targetLanguage = Setting.TargetLanguage;
                apiName = Setting.ApiName;
            }
            else
            {
                targetLanguage = "N/A";
                apiName = "N/A";
            }

            try
            {
                if (isOverwrite)
                    await SQLiteHistoryLogger.DeleteLastTranslation(token);
                await SQLiteHistoryLogger.LogTranslation(originalText, translatedText, targetLanguage, apiName);
                TranslationLogged?.Invoke();
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[ERROR] Logging History Failed: {ex.Message}");
            }
        }

        public static async Task LogOnly(string originalText,
            bool isOverwrite = false, CancellationToken token = default)
        {
            try
            {
                if (isOverwrite)
                    await SQLiteHistoryLogger.DeleteLastTranslation(token);
                await SQLiteHistoryLogger.LogTranslation(originalText, "N/A", "N/A", "LogOnly");
                TranslationLogged?.Invoke();
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[ERROR] Logging History Failed: {ex.Message}");
            }
        }

        public static async Task AddLogCard(CancellationToken token = default)
        {
            var lastLog = await SQLiteHistoryLogger.LoadLastTranslation(token);
            if (lastLog == null)
                return;

            if (Caption?.Contexts.Count >= Setting?.MainWindow.CaptionLogMax)
                Caption.Contexts.Dequeue();
            Caption?.Contexts.Enqueue(lastLog);
            Caption?.OnPropertyChanged("DisplayContexts");
        }

        public static async Task<bool> IsOverwrite(string originalText, CancellationToken token = default)
        {
            // If this text is too similar to the last one, rewrite it when logging.
            string lastOriginalText = await SQLiteHistoryLogger.LoadLastSourceText(token);
            if (lastOriginalText == null)
                return false;
            double similarity = TextUtil.Similarity(originalText, lastOriginalText);
            return similarity > 0.66;
        }
    }
}
