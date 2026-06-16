using System.Diagnostics;
using System.Windows.Automation;

namespace LiveCaptionsTranslator.utils
{
    public static class LiveCaptionsHandler
    {
        public static readonly string PROCESS_NAME = "LiveCaptions";

        private static AutomationElement? captionsTextBlock = null;
        private static DateTime lastCacheRefresh = DateTime.MinValue;
        private static readonly TimeSpan CACHE_REFRESH_INTERVAL = TimeSpan.FromSeconds(10); // Force refresh cache every 10 seconds

        public static AutomationElement LaunchLiveCaptions()
        {
            try
            {
                Console.WriteLine("LaunchLiveCaptions: Starting...");
                
                // Init - First try to clean existing processes
                KillAllProcessesByPName(PROCESS_NAME);
                
                // Wait for process to exit completely
                Thread.Sleep(1000);
                
                // Start new process
                Console.WriteLine("LaunchLiveCaptions: Starting LiveCaptions process...");
                var process = Process.Start(PROCESS_NAME);
                if (process == null)
                {
                    throw new Exception("Failed to start LiveCaptions process");
                }

                Console.WriteLine($"LaunchLiveCaptions: Process started with ID {process.Id}");

                // Search for window with timeout and proper delays
                AutomationElement? window = null;
                const int maxAttempts = 100; // Reduce maximum attempts
                const int delayMs = 100; // Increase delay time
                
                for (int attemptCount = 0; attemptCount < maxAttempts; attemptCount++)
                {
                    try
                    {
                        // Add delay to avoid high CPU usage
                        Thread.Sleep(delayMs);
                        
                        window = FindWindowByPId(process.Id);
                        
                        if (window != null)
                        {
                            // Check window class name
                            string className = window.Current.ClassName;
                            Console.WriteLine($"LaunchLiveCaptions: Found window with class '{className}' (attempt {attemptCount + 1})");
                            
                            if (className == "LiveCaptionsDesktopWindow")
                            {
                                Console.WriteLine("LaunchLiveCaptions: Successfully found LiveCaptions window");
                                return window;
                            }
                        }
                        
                        // Output progress every 10 attempts
                        if ((attemptCount + 1) % 10 == 0)
                        {
                            Console.WriteLine($"LaunchLiveCaptions: Still searching for window... (attempt {attemptCount + 1}/{maxAttempts})");
                        }
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"LaunchLiveCaptions: FindWindowByPId attempt {attemptCount + 1} failed: {ex.Message}");
                        
                        // Check if process still exists
                        if (process.HasExited)
                        {
                            throw new Exception($"LiveCaptions process exited unexpectedly with code {process.ExitCode}");
                        }
                    }
                }

                // Throw exception after timeout
                throw new Exception($"Failed to find LiveCaptions window after {maxAttempts} attempts ({maxAttempts * delayMs / 1000} seconds)");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"LaunchLiveCaptions failed: {ex.Message}");
                throw; // Re-throw exception for caller to handle
            }
        }

        public static void KillLiveCaptions(AutomationElement window)
        {
            try
            {
                if (window == null)
                    return;

                // Search for process
                nint hWnd = new nint((long)window.Current.NativeWindowHandle);
                WindowsAPI.GetWindowThreadProcessId(hWnd, out int processId);
                var process = Process.GetProcessById(processId);

                // Kill process
                process.Kill();
                process.WaitForExit();
            }
            catch (Exception ex)
            {
                // Ignore permission errors and other exceptions to avoid crashes
                Console.WriteLine($"KillLiveCaptions failed: {ex.Message}");
            }
        }

        public static void HideLiveCaptions(AutomationElement window)
        {
            try
            {
                if (window == null)
                {
                    Console.WriteLine("HideLiveCaptions: window is null, skipping");
                    return;
                }

                var nativeHandle = window.Current.NativeWindowHandle;
                if (nativeHandle == 0)
                {
                    Console.WriteLine("HideLiveCaptions: NativeWindowHandle is 0, skipping");
                    return;
                }

                nint hWnd = new nint((long)nativeHandle);
                if (hWnd == IntPtr.Zero)
                {
                    Console.WriteLine("HideLiveCaptions: Invalid window handle, skipping");
                    return;
                }

                int exStyle = WindowsAPI.GetWindowLong(hWnd, WindowsAPI.GWL_EXSTYLE);

                WindowsAPI.ShowWindow(hWnd, WindowsAPI.SW_MINIMIZE);
                WindowsAPI.SetWindowLong(hWnd, WindowsAPI.GWL_EXSTYLE, exStyle | WindowsAPI.WS_EX_TOOLWINDOW);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"HideLiveCaptions failed: {ex.Message}");
            }
        }

        public static void RestoreLiveCaptions(AutomationElement window)
        {
            try
            {
                if (window == null)
                {
                    Console.WriteLine("RestoreLiveCaptions: window is null, skipping");
                    return;
                }

                var nativeHandle = window.Current.NativeWindowHandle;
                if (nativeHandle == 0)
                {
                    Console.WriteLine("RestoreLiveCaptions: NativeWindowHandle is 0, skipping");
                    return;
                }

                nint hWnd = new nint((long)nativeHandle);
                if (hWnd == IntPtr.Zero)
                {
                    Console.WriteLine("RestoreLiveCaptions: Invalid window handle, skipping");
                    return;
                }

                int exStyle = WindowsAPI.GetWindowLong(hWnd, WindowsAPI.GWL_EXSTYLE);

                WindowsAPI.SetWindowLong(hWnd, WindowsAPI.GWL_EXSTYLE, exStyle & ~WindowsAPI.WS_EX_TOOLWINDOW);
                WindowsAPI.ShowWindow(hWnd, WindowsAPI.SW_RESTORE);
                WindowsAPI.SetForegroundWindow(hWnd);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"RestoreLiveCaptions failed: {ex.Message}");
            }
        }

        public static void FixLiveCaptions(AutomationElement window)
        {
            try
            {
                if (window == null)
                {
                    Console.WriteLine("FixLiveCaptions: window is null, skipping");
                    return;
                }

                var nativeHandle = window.Current.NativeWindowHandle;
                if (nativeHandle == 0)
                {
                    Console.WriteLine("FixLiveCaptions: NativeWindowHandle is 0, skipping");
                    return;
                }

                nint hWnd = new nint((long)nativeHandle);
                if (hWnd == IntPtr.Zero)
                {
                    Console.WriteLine("FixLiveCaptions: Invalid window handle, skipping");
                    return;
                }

                RECT rect;
                if (!WindowsAPI.GetWindowRect(hWnd, out rect))
                {
                    Console.WriteLine("FixLiveCaptions: Unable to get the window rectangle of LiveCaptions");
                    return;
                }
                
                int width = rect.Right - rect.Left;
                int height = rect.Bottom - rect.Top;
                int x = rect.Left;
                int y = rect.Top;

                bool isSuccess = true;
                if (x < 0 || y < 0 || width < 100 || height < 100)
                    isSuccess = WindowsAPI.MoveWindow(hWnd, 800, 600, 600, 200, true);
                if (!isSuccess)
                {
                    Console.WriteLine("FixLiveCaptions: Failed to fix LiveCaptions window position");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"FixLiveCaptions failed: {ex.Message}");
            }
        }

        public static string GetCaptions(AutomationElement window)
        {
            try
            {
                // Check if cache needs timed refresh
                if (DateTime.Now - lastCacheRefresh > CACHE_REFRESH_INTERVAL)
                {
                    Console.WriteLine("GetCaptions: Cache refresh interval reached, clearing cache");
                    ClearElementCache();
                }
                
                // First try to use cached elements
                if (captionsTextBlock != null)
                {
                    try
                    {
                        var cachedName = captionsTextBlock.Current.Name;
                        // If content can be successfully retrieved, return it
                        if (!string.IsNullOrEmpty(cachedName))
                        {
                            return cachedName;
                        }
                    }
                    catch
                    {
                        // Cached element is invalid, clear and search again
                        Console.WriteLine("GetCaptions: Cached element failed, clearing cache");
                        captionsTextBlock = null;
                    }
                }
                
                // Search for elements again
                captionsTextBlock = FindElementByAId(window, "CaptionsTextBlock");
                
                if (captionsTextBlock == null)
                {
                    Console.WriteLine("GetCaptions: CaptionsTextBlock element not found");
                    return string.Empty;
                }
                
                var currentName = captionsTextBlock.Current.Name;
                Console.WriteLine($"GetCaptions: Retrieved text: '{currentName?.Substring(0, Math.Min(50, currentName?.Length ?? 0))}...'");
                return currentName ?? string.Empty;
            }
            catch (ElementNotAvailableException ex)
            {
                Console.WriteLine($"GetCaptions: Element not available, clearing cache: {ex.Message}");
                // 元素不可用，清空缓存并重新查找
                captionsTextBlock = null;
                try
                {
                    captionsTextBlock = FindElementByAId(window, "CaptionsTextBlock");
                    var name = captionsTextBlock?.Current.Name;
                    Console.WriteLine($"GetCaptions: After retry, retrieved: '{name?.Substring(0, Math.Min(50, name?.Length ?? 0))}...'");
                    return name ?? string.Empty;
                }
                catch (Exception retryEx)
                {
                    Console.WriteLine($"GetCaptions: Retry failed: {retryEx.Message}");
                    return string.Empty;
                }
            }
            catch (Exception ex)
            {
                // 其他异常也清空缓存，避免卡住
                Console.WriteLine($"GetCaptions: Unexpected error: {ex.Message}");
                captionsTextBlock = null;
                return string.Empty;
            }
        }

        private static AutomationElement FindWindowByPId(int processId)
        {
            var condition = new PropertyCondition(AutomationElement.ProcessIdProperty, processId);
            return AutomationElement.RootElement.FindFirst(TreeScope.Children, condition);
        }

        public static AutomationElement? FindElementByAId(
            AutomationElement window, string automationId, CancellationToken token = default)
        {
            try
            {
                PropertyCondition condition = new PropertyCondition(
                    AutomationElement.AutomationIdProperty, automationId);
                return window.FindFirst(TreeScope.Descendants, condition);
            }
            catch (OperationCanceledException)
            {
                return null;
            }
            catch (NullReferenceException)
            {
                return null;
            }
        }

        public static void PrintAllElementsAId(AutomationElement window)
        {
            var treeWalker = TreeWalker.RawViewWalker;
            var stack = new Stack<AutomationElement>();
            stack.Push(window);

            while (stack.Count > 0)
            {
                var element = stack.Pop();
                if (!string.IsNullOrEmpty(element.Current.AutomationId))
                    Console.WriteLine(element.Current.AutomationId);

                var child = treeWalker.GetFirstChild(element);
                while (child != null)
                {
                    stack.Push(child);
                    child = treeWalker.GetNextSibling(child);
                }
            }
        }

        public static bool ClickSettingsButton(AutomationElement window)
        {
            var settingsButton = FindElementByAId(window, "SettingsButton");
            if (settingsButton != null)
            {
                var invokePattern = settingsButton.GetCurrentPattern(InvokePattern.Pattern) as InvokePattern;
                if (invokePattern != null)
                {
                    invokePattern.Invoke();
                    return true;
                }
            }
            return false;
        }

        private static void KillAllProcessesByPName(string processName)
        {
            try
            {
                var processes = Process.GetProcessesByName(processName);
                if (processes.Length == 0)
                    return;
                    
                foreach (Process process in processes)
                {
                    try
                    {
                        if (!process.HasExited)
                        {
                            process.Kill();
                            process.WaitForExit(5000); // 等待最多5秒
                        }
                        process.Dispose();
                    }
                    catch (Exception ex)
                    {
                        // 忽略单个进程的权限错误
                        Console.WriteLine($"Failed to kill process {process.Id}: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                // 忽略整体的权限错误，避免崩溃
                Console.WriteLine($"KillAllProcessesByPName failed: {ex.Message}");
            }
        }

        /// <summary>
        /// 强制清空UI元素缓存，用于重新连接或刷新
        /// </summary>
        public static void ClearElementCache()
        {
            captionsTextBlock = null;
            lastCacheRefresh = DateTime.Now;
            Console.WriteLine("LiveCaptionsHandler: Element cache cleared");
        }
    }
}
