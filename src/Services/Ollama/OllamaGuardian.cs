using System;
using System.Collections;
using System.Diagnostics;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using LiveCaptionsTranslator.models;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.IO;
using System.Linq;
using Serilog;

namespace LiveCaptionsTranslator.utils
{
    public static class OllamaGuardian
    {
        private static Process? ollamaProcess = null;
        private static Process? modelProcess = null;
        private const string OLLAMA_PROCESS_NAME = "ollama";
        // Remove hardcoded GetConfiguredModelName() - always use user configuration
        
        // 添加静态HttpClient实例以提高性能和避免端口耗尽
        private static readonly HttpClient httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(HTTP_CLIENT_TIMEOUT_SECONDS)
        };
        private static string GetServerUrl()
        {
            Debug.WriteLine("获取Ollama服务器URL...");
            Console.WriteLine("获取Ollama服务器URL...");
            try
            {
                var config = Translator.Setting.OllamaConfig as OllamaConfig;
                var host = config?.Host ?? "127.0.0.1";
                var port = config?.Port ?? 11434;
                var url = $"http://{host}:{port}";
                Debug.WriteLine($"Ollama服务器URL: {url}");
                Console.WriteLine($"Ollama服务器URL: {url}");
                return url;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"获取Ollama服务器URL失败: {ex.Message}");
                Console.WriteLine($"获取Ollama服务器URL失败: {ex.Message}");
                var defaultUrl = "http://127.0.0.1:11434";
                Debug.WriteLine($"使用默认URL: {defaultUrl}");
                Console.WriteLine($"使用默认URL: {defaultUrl}");
                return defaultUrl;
            }
        }
        private const int MAX_STARTUP_WAIT_SECONDS = 300; // 增加到5分钟，首次下载模型需要更长时间
        private const int MODEL_DOWNLOAD_TIMEOUT = 18000; // 5小时下载超时，之前是600秒(10分钟)
        private const int HEALTH_CHECK_INTERVAL_MS = 500;
        private const int HTTP_CLIENT_TIMEOUT_SECONDS = 21600; // 6小时HTTP超时

        // 添加下载进度跟踪变量
        private static long _totalBytes = 0;
        private static long _downloadedBytes = 0;
        private static DateTime _downloadStartTime = DateTime.MinValue;
        private static string _downloadStatus = "";
        
        /// <summary>
        /// Helper method to report progress and log to file simultaneously
        /// </summary>
        private static void ReportProgress(IProgress<string>? progress, string message)
        {
            progress?.Report(message);
            Log.Information("[OLLAMA] {Message}", message);
        }
        
        /// <summary>
        /// Get the configured model name from user settings
        /// Falls back to qwen3:4b-instruct-2507-q4_K_M if no configuration is available
        /// </summary>
        /// <returns>Model name to use</returns>
        private static string GetConfiguredModelName()
        {
            try
            {
                // Try to get model name from current setting
                var modelName = Translator.Setting?.OllamaConfig?.ModelName;
                if (!string.IsNullOrEmpty(modelName))
                {
                    Debug.WriteLine($"Using model from current settings: {modelName}");
                    Console.WriteLine($"Using model from current settings: {modelName}");
                    return modelName;
                }
                
                // If no current setting, use fallback
                var fallbackModel = "qwen3:4b-instruct-2507-q4_K_M";
                Debug.WriteLine($"No model configured in settings, using fallback: {fallbackModel}");
                Console.WriteLine($"No model configured in settings, using fallback: {fallbackModel}");
                return fallbackModel;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Failed to get configured model name: {ex.Message}, using fallback");
                Console.WriteLine($"Failed to get configured model name: {ex.Message}, using fallback");
                return "qwen3:4b-instruct-2507-q4_K_M";
            }
        }

        // 安全的HTTP任务等待辅助方法，避免未观察任务异常
        private static T SafeWaitForTask<T>(Task<T> task, int timeoutMs = 5000, string operation = "HTTP操作")
        {
            try
            {
                bool completed = task.Wait(timeoutMs);
                if (!completed)
                {
                    Debug.WriteLine($"{operation}超时({timeoutMs}ms)");
                    Console.WriteLine($"{operation}超时({timeoutMs}ms)");
                    throw new TimeoutException($"{operation}超时");
                }

                if (task.IsFaulted)
                {
                    var baseException = task.Exception?.GetBaseException();
                    Debug.WriteLine($"{operation}任务失败: {baseException?.Message}");
                    Console.WriteLine($"{operation}任务失败: {baseException?.Message}");
                    throw baseException ?? new Exception($"{operation}任务失败");
                }

                return task.Result;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"{operation}异常: {ex.Message}");
                Console.WriteLine($"{operation}异常: {ex.Message}");
                throw;
            }
        }

        // 完全同步的端口检查方法，避免任何异步操作产生未观察异常
        private static bool IsPortInUse(int port)
        {
            try
            {
                Debug.WriteLine($"开始检查端口 {port}...");
                Console.WriteLine($"开始检查端口 {port}...");
                
                using (var socket = new System.Net.Sockets.Socket(
                    System.Net.Sockets.AddressFamily.InterNetwork, 
                    System.Net.Sockets.SocketType.Stream, 
                    System.Net.Sockets.ProtocolType.Tcp))
                {
                    // 设置短超时时间
                    socket.SetSocketOption(System.Net.Sockets.SocketOptionLevel.Socket, 
                                         System.Net.Sockets.SocketOptionName.SendTimeout, 1000);
                    socket.SetSocketOption(System.Net.Sockets.SocketOptionLevel.Socket, 
                                         System.Net.Sockets.SocketOptionName.ReceiveTimeout, 1000);
                    
                    // 使用完全同步的连接测试
                    var endpoint = new System.Net.IPEndPoint(System.Net.IPAddress.Loopback, port);
                    
                    try
                    {
                        socket.Connect(endpoint);
                        Debug.WriteLine($"端口 {port} 已被占用");
                        Console.WriteLine($"端口 {port} 已被占用");
                        return true;
                    }
                    catch (System.Net.Sockets.SocketException ex)
                    {
                        // 连接被拒绝意味着端口未被占用
                        if (ex.SocketErrorCode == System.Net.Sockets.SocketError.ConnectionRefused ||
                            ex.SocketErrorCode == System.Net.Sockets.SocketError.TimedOut)
                        {
                            Debug.WriteLine($"端口 {port} 未被占用 (连接被拒绝或超时)");
                            Console.WriteLine($"端口 {port} 未被占用 (连接被拒绝或超时)");
                            return false;
                        }
                        // 其他Socket错误也视为未占用
                        Debug.WriteLine($"端口 {port} 检查异常: {ex.Message} (视为未占用)");
                        Console.WriteLine($"端口 {port} 检查异常: {ex.Message} (视为未占用)");
                        return false;
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"端口 {port} 检查失败: {ex.Message} (视为未占用)");
                Console.WriteLine($"端口 {port} 检查失败: {ex.Message} (视为未占用)");
                return false;
            }
        }

        public static bool StartServer(IProgress<string>? progress = null)
        {
            try
            {
                ReportProgress(progress, "开始启动Ollama服务...");
                Log.Information("🚀 OllamaGuardian.StartServer() 开始启动流程");

                StopServer(progress);

                if (!ApplicationSetup.IsCorrectVersionInstalled())
                {
                    ReportProgress(progress, "Ollama 未正确安装或版本不匹配，请重新启动应用以触发自动安装。");
                    return false;
                }
                ReportProgress(progress, "Ollama引擎检查通过。");

                var exePath = ApplicationSetup.GetOllamaExecutablePath();
                ReportProgress(progress, $"Ollama可执行文件: {exePath}");
                if (!File.Exists(exePath))
                {
                    ReportProgress(progress, "错误: Ollama可执行文件不存在。");
                    return false;
                }

                ReportProgress(progress, "配置Ollama环境变量 (GPU加速)...");
                var startInfo = new ProcessStartInfo
                {
                    FileName = exePath,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    WorkingDirectory = ApplicationSetup.OllamaPath,
                    Arguments = "serve"
                };

                startInfo.EnvironmentVariables["OLLAMA_MODELS"] = ApplicationSetup.ModelPath;
                
                // 从配置中动态获取Host和Port，确保与客户端连接配置一致
                var config = Translator.Setting.OllamaConfig as OllamaConfig;
                var host = config?.Host ?? "127.0.0.1";
                var port = config?.Port ?? 11434;
                startInfo.EnvironmentVariables["OLLAMA_HOST"] = $"{host}:{port}";
                
                startInfo.EnvironmentVariables["OLLAMA_NUM_GPU"] = "999";
                startInfo.EnvironmentVariables["ZES_ENABLE_SYSMAN"] = "1";
                startInfo.EnvironmentVariables["SYCL_CACHE_PERSISTENT"] = "1";

                ReportProgress(progress, "正在启动Ollama服务器进程...");
                ollamaProcess = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
                ollamaProcess.ErrorDataReceived += (s, e) => { if(e.Data != null) ReportProgress(progress, $"[Ollama Error] {e.Data}"); };
                ollamaProcess.OutputDataReceived += (s, e) => { if(e.Data != null) ReportProgress(progress, $"[Ollama] {e.Data}"); };

                ollamaProcess.Start();
                ollamaProcess.BeginErrorReadLine();
                ollamaProcess.BeginOutputReadLine();
                ReportProgress(progress, $"Ollama服务器进程已启动，PID: {ollamaProcess.Id}");

                ReportProgress(progress, "等待Ollama服务响应...");
                var startTime = DateTime.Now;
                while ((DateTime.Now - startTime).TotalSeconds < MAX_STARTUP_WAIT_SECONDS)
                {
                    if (IsServerOnline(progress))
                    {
                        ReportProgress(progress, "Ollama服务已在线。");
                        if (DownloadAndInitializeModel(progress))
                        {
                            ReportProgress(progress, "模型加载成功，正在进行最终验证...");
                            if (TestModel(progress))
                            {
                                ReportProgress(progress, "Ollama服务完全就绪！");
                                return true;
                            }
                        }
                        ReportProgress(progress, "模型初始化失败。");
                        return false;
                    }
                    Thread.Sleep(HEALTH_CHECK_INTERVAL_MS);
                }

                ReportProgress(progress, "Ollama服务器启动超时。");
                StopServer(progress);
                return false;
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"启动Ollama服务器时发生致命错误: {ex.Message}");
                return false;
            }
        }

        public static void StopServer(IProgress<string>? progress = null)
        {
            ReportProgress(progress, "正在停止所有Ollama进程...");
            try
            {
                var processes = Process.GetProcessesByName(OLLAMA_PROCESS_NAME);
                foreach (var process in processes)
                {
                    try
                    {
                        process.Kill();
                        ReportProgress(progress, $"已终止进程 PID: {process.Id}");
                    }
                    catch (Exception ex)
                    {
                        ReportProgress(progress, $"终止进程 PID: {process.Id} 失败: {ex.Message}");
                    }
                }
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"查找Ollama进程失败: {ex.Message}");
            }
            ollamaProcess = null;
        }

        private static bool DownloadAndInitializeModel(IProgress<string>? progress = null)
        {
            try
            {
                var modelName = GetConfiguredModelName();
                ReportProgress(progress, $"开始下载并初始化模型 {modelName}...");
                if (IsModelLoaded(progress))
                {
                    ReportProgress(progress, "模型已存在，跳过下载。");
                    return true;
                }

                ReportProgress(progress, "模型不存在，开始从网络拉取...");
                return DownloadModelWithProgress(progress);
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"下载和初始化模型失败: {ex.Message}");
                return false;
            }
        }

        private static bool DownloadModelWithProgress(IProgress<string>? progress = null)
        {
            var modelName = GetConfiguredModelName();
            ReportProgress(progress, $"触发模型 {modelName} 下载... (这可能需要很长时间)");
            using (var client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromSeconds(HTTP_CLIENT_TIMEOUT_SECONDS);
                var requestData = new { name = modelName, stream = true };
                var content = new StringContent(JsonSerializer.Serialize(requestData), Encoding.UTF8, "application/json");

                try
                {
                    using (var response = client.PostAsync($"{GetServerUrl()}/api/pull", content).Result)
                    {
                        if (!response.IsSuccessStatusCode)
                        {
                            ReportProgress(progress, $"模型拉取请求失败: {response.StatusCode}");
                            return false;
                        }

                        using (var stream = response.Content.ReadAsStreamAsync().Result)
                        using (var reader = new StreamReader(stream))
                        {
                            string? line;
                            while ((line = reader.ReadLine()) != null)
                            {
                                ReportProgress(progress, $"[下载] {line}");
                                if (line.Contains("success", StringComparison.OrdinalIgnoreCase))
                                {
                                    ReportProgress(progress, "模型文件下载完成。");
                                    return true; // 等待加载和最终测试
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                { 
                    ReportProgress(progress, $"下载模型时出错: {ex.Message}");
                    return false;
                }
            }
            return false; // Should not be reached
        }

        private static bool TestModel(IProgress<string>? progress = null)
        {
            try
            {
                ReportProgress(progress, "正在测试模型可用性...");
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(30);
                var modelName = GetConfiguredModelName();
                var requestData = new { model = modelName, prompt = "Hello", stream = false };
                var content = new StringContent(JsonSerializer.Serialize(requestData), Encoding.UTF8, "application/json");
                var response = client.PostAsync($"{GetServerUrl()}/api/generate", content).Result;

                if (response.IsSuccessStatusCode)
                {
                    ReportProgress(progress, "模型测试成功！");
                    return true;
                }
                else
                {
                    ReportProgress(progress, $"模型测试失败: {response.StatusCode}");
                    return false;
                }
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"模型测试时发生异常: {ex.Message}");
                return false;
            }
        }

        private static bool IsModelLoaded(IProgress<string>? progress = null)
        {
            try
            {
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(5);
                var response = client.GetAsync($"{GetServerUrl()}/api/tags").Result;
                if (response.IsSuccessStatusCode)
                {
                    var content = response.Content.ReadAsStringAsync().Result;
                    var modelName = GetConfiguredModelName();
                    bool loaded = content.Contains(modelName);
                    ReportProgress(progress, $"检查本地模型: {(loaded ? "已存在" : "未找到")}");
                    return loaded;
                }
            }
            catch (Exception ex)
            {
                ReportProgress(progress, $"检查本地模型失败: {ex.Message}");
            }
            return false;
        }

        public static bool IsServerOnline(IProgress<string>? progress = null)
        {
            try
            {
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(2);
                var response = client.GetAsync($"{GetServerUrl()}/api/version").Result;
                return response.IsSuccessStatusCode;
            }
            catch
            {
                return false;
            }
        }

        public static void StopServer()
        {
            try
            {
                Debug.WriteLine("开始停止Ollama服务...");
                Console.WriteLine("开始停止Ollama服务...");
                
                // 采用完整的进程清理流程，确保释放GPU显存
                Debug.WriteLine("执行完整进程清理模式，包括ollama-lib.exe");
                Console.WriteLine("执行完整进程清理模式，包括ollama-lib.exe");
                
                // 1. 清理进程引用
                try 
                {
                    Debug.WriteLine("清理进程引用...");
                    Console.WriteLine("清理进程引用...");
                    
                    ollamaProcess = null;
                    modelProcess = null;
                    
                    Debug.WriteLine("进程引用已清理");
                    Console.WriteLine("进程引用已清理");
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"清理进程引用失败: {ex.Message}");
                    Console.WriteLine($"清理进程引用失败: {ex.Message}");
                }
                
                // 2. 终止主要的ollama.exe进程
                try 
                {
                    Debug.WriteLine("终止ollama.exe进程...");
                    Console.WriteLine("终止ollama.exe进程...");
                    
                    var ollamaProcesses = Process.GetProcessesByName("ollama");
                    Debug.WriteLine($"找到 {ollamaProcesses.Length} 个 ollama.exe 进程");
                    Console.WriteLine($"找到 {ollamaProcesses.Length} 个 ollama.exe 进程");
                    
                    foreach (var proc in ollamaProcesses)
                    {
                        try
                        {
                            if (!proc.HasExited)
                            {
                                Debug.WriteLine($"终止ollama.exe进程 PID: {proc.Id}");
                                Console.WriteLine($"终止ollama.exe进程 PID: {proc.Id}");
                                proc.Kill();
                                
                                // 等待进程退出，给GPU一些时间
                                if (proc.WaitForExit(3000))
                                {
                                    Debug.WriteLine($"ollama.exe PID {proc.Id} 已正常退出");
                                    Console.WriteLine($"ollama.exe PID {proc.Id} 已正常退出");
                                }
                                else
                                {
                                    Debug.WriteLine($"ollama.exe PID {proc.Id} 退出超时");
                                    Console.WriteLine($"ollama.exe PID {proc.Id} 退出超时");
                                }
                            }
                            proc.Dispose();
                        }
                        catch (Exception procEx)
                        {
                            Debug.WriteLine($"终止ollama.exe进程失败: {procEx.Message}");
                            Console.WriteLine($"终止ollama.exe进程失败: {procEx.Message}");
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"查找ollama.exe进程失败: {ex.Message}");
                    Console.WriteLine($"查找ollama.exe进程失败: {ex.Message}");
                }
                
                // 🔥 3. 关键修复：终止占用GPU显存的ollama-lib.exe进程
                try 
                {
                    Debug.WriteLine("终止ollama-lib.exe进程（GPU显存占用者）...");
                    Console.WriteLine("终止ollama-lib.exe进程（GPU显存占用者）...");
                    
                    var ollamaLibProcesses = Process.GetProcessesByName("ollama-lib");
                    Debug.WriteLine($"找到 {ollamaLibProcesses.Length} 个 ollama-lib.exe 进程");
                    Console.WriteLine($"找到 {ollamaLibProcesses.Length} 个 ollama-lib.exe 进程");
                    
                    foreach (var proc in ollamaLibProcesses)
                    {
                        try
                        {
                            if (!proc.HasExited)
                            {
                                Debug.WriteLine($"🎯 终止ollama-lib.exe进程 PID: {proc.Id} (释放GPU显存)");
                                Console.WriteLine($"🎯 终止ollama-lib.exe进程 PID: {proc.Id} (释放GPU显存)");
                                proc.Kill();
                                
                                // 给GPU更多时间释放显存
                                if (proc.WaitForExit(8000))
                                {
                                    Debug.WriteLine($"✅ ollama-lib.exe PID {proc.Id} 已正常退出，GPU显存应已释放");
                                    Console.WriteLine($"✅ ollama-lib.exe PID {proc.Id} 已正常退出，GPU显存应已释放");
                                }
                                else
                                {
                                    Debug.WriteLine($"⚠️ ollama-lib.exe PID {proc.Id} 退出超时，GPU显存可能仍被占用");
                                    Console.WriteLine($"⚠️ ollama-lib.exe PID {proc.Id} 退出超时，GPU显存可能仍被占用");
                                }
                            }
                            proc.Dispose();
                        }
                        catch (Exception procEx)
                        {
                            Debug.WriteLine($"❌ 终止ollama-lib.exe进程失败: {procEx.Message}");
                            Console.WriteLine($"❌ 终止ollama-lib.exe进程失败: {procEx.Message}");
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"查找ollama-lib.exe进程失败: {ex.Message}");
                    Console.WriteLine($"查找ollama-lib.exe进程失败: {ex.Message}");
                }
                
                Debug.WriteLine("✅ Ollama服务停止流程完成，GPU显存应已释放");
                Console.WriteLine("✅ Ollama服务停止流程完成，GPU显存应已释放");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"停止Ollama服务时发生严重错误: {ex.Message}");
                Console.WriteLine($"停止Ollama服务时发生严重错误: {ex.Message}");
                Debug.WriteLine($"异常详情: {ex}");
                Console.WriteLine($"异常详情: {ex}");
                
                // 确保重要引用被清空
                try 
                {
                    ollamaProcess = null;
                    modelProcess = null;
                }
                catch { /* 忽略清理时的错误 */ }
            }
        }

        private static void KillProcessByPort(int port)
        {
            Debug.WriteLine($"尝试查找并终止占用端口{port}的进程...");
            Console.WriteLine($"尝试查找并终止占用端口{port}的进程...");
            
            try
            {
                // 使用netstat命令查找占用端口的进程ID
                var startInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/c netstat -ano | findstr :{port}",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };
                
                using (var process = Process.Start(startInfo))
                {
                    if (process == null)
                    {
                        Debug.WriteLine("无法启动netstat命令");
                        Console.WriteLine("无法启动netstat命令");
                        return;
                    }
                    
                    var output = process.StandardOutput.ReadToEnd();
                    var error = process.StandardError.ReadToEnd();
                    
                    if (!process.WaitForExit(5000))
                    {
                        Debug.WriteLine("netstat命令执行超时");
                        Console.WriteLine("netstat命令执行超时");
                        try { process.Kill(); } catch { }
                        return;
                    }
                    
                    if (!string.IsNullOrEmpty(error))
                    {
                        Debug.WriteLine($"netstat命令错误: {error}");
                        Console.WriteLine($"netstat命令错误: {error}");
                    }
                    
                    if (string.IsNullOrEmpty(output))
                    {
                        Debug.WriteLine($"端口{port}未被占用");
                        Console.WriteLine($"端口{port}未被占用");
                        return;
                    }
                    
                    Debug.WriteLine($"netstat输出:\n{output}");
                    Console.WriteLine($"netstat输出:\n{output}");
                    
                    // 解析输出找到进程ID
                    var lines = output.Split('\n');
                    foreach (var line in lines)
                    {
                        if (line.Contains($":{port}"))
                        {
                            try 
                            {
                                Debug.WriteLine($"处理行: {line.Trim()}");
                                Console.WriteLine($"处理行: {line.Trim()}");
                                
                                var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
                                if (parts.Length > 4 && int.TryParse(parts[parts.Length - 1], out int pid))
                                {
                                    // 跳过 PID=0 的 Idle 进程
                                    if (pid == 0)
                                    {
                                        Debug.WriteLine($"跳过 PID=0 的 Idle 进程，不尝试终止。");
                                        Console.WriteLine($"跳过 PID=0 的 Idle 进程，不尝试终止。");
                                        continue;
                                    }
                                    
                                    Debug.WriteLine($"找到占用端口{port}的进程，PID: {pid}");
                                    Console.WriteLine($"找到占用端口{port}的进程，PID: {pid}");
                                    
                                    // 安全地终止进程
                                    try
                                    {
                                        using (var procToKill = Process.GetProcessById(pid))
                                        {
                                            if (procToKill.HasExited)
                                            {
                                                Debug.WriteLine($"进程 PID {pid} 已经退出");
                                                Console.WriteLine($"进程 PID {pid} 已经退出");
                                                continue;
                                            }
                                            
                                            var processName = procToKill.ProcessName;
                                            Debug.WriteLine($"正在终止进程: {processName} (PID: {pid})");
                                            Console.WriteLine($"正在终止进程: {processName} (PID: {pid})");
                                            
                                            procToKill.Kill();
                                            
                                            if (procToKill.WaitForExit(3000))
                                            {
                                                Debug.WriteLine($"进程已正常终止: {processName} (PID: {pid})");
                                                Console.WriteLine($"进程已正常终止: {processName} (PID: {pid})");
                                            }
                                            else
                                            {
                                                Debug.WriteLine($"进程终止超时: {processName} (PID: {pid})");
                                                Console.WriteLine($"进程终止超时: {processName} (PID: {pid})");
                                            }
                                        }
                                    }
                                    catch (ArgumentException)
                                    {
                                        Debug.WriteLine($"进程 PID {pid} 不存在或已退出");
                                        Console.WriteLine($"进程 PID {pid} 不存在或已退出");
                                    }
                                    catch (Exception procEx)
                                    {
                                        Debug.WriteLine($"终止进程 PID {pid} 失败: {procEx.Message}");
                                        Console.WriteLine($"终止进程 PID {pid} 失败: {procEx.Message}");
                                    }
                                }
                                else
                                {
                                    Debug.WriteLine($"无法解析进程ID，行内容: {line.Trim()}");
                                    Console.WriteLine($"无法解析进程ID，行内容: {line.Trim()}");
                                }
                            }
                            catch (Exception lineEx)
                            {
                                Debug.WriteLine($"处理netstat输出行时出错: {lineEx.Message}, 行: {line}");
                                Console.WriteLine($"处理netstat输出行时出错: {lineEx.Message}, 行: {line}");
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"查找占用端口的进程时出错: {ex.Message}");
                Console.WriteLine($"查找占用端口的进程时出错: {ex.Message}");
                Debug.WriteLine($"异常详情: {ex}");
                Console.WriteLine($"异常详情: {ex}");
            }
        }

        /// <returns>如果服务器健康则返回 true，否则返回 false。</returns>
        public static bool IsServerHealthy()
        {
            Log.Information("📋 检查 Ollama 安装状态");

            if (IsServerOnline())
            {
                Log.Information("🔍 开始检查服务器连接: {ServerUrl}/api/version", GetServerUrl());
                Log.Information("📡 服务器响应状态: \"OK\" (在线)");
                
                // Check server version
                try
                {
                    using var client = new HttpClient();
                    client.Timeout = TimeSpan.FromSeconds(5);
                    var versionResponse = client.GetAsync($"{GetServerUrl()}/api/version").Result;
                    if (versionResponse.IsSuccessStatusCode)
                    {
                        var versionContent = versionResponse.Content.ReadAsStringAsync().Result;
                        Log.Information("✅ 服务器版本信息: {VersionInfo}", versionContent);
                    }
                }
                catch (Exception ex)
                {
                    Log.Warning("获取服务器版本信息失败: {Error}", ex.Message);
                }
                
                // Always check if the correct model is loaded
                bool modelLoaded = IsModelLoaded();
                if (modelLoaded)
                {
                    var configuredModel = GetConfiguredModelName();
                    Log.Information("✅ 默认模型 {ModelName} 已加载，服务器就绪。", configuredModel);
                    return true;
                }
                else
                {
                    var configuredModel = GetConfiguredModelName();
                    Log.Warning("⚠️ 服务器在线但默认模型 {ModelName} 未加载，需要下载。", configuredModel);
                    return false; // Force model download through StartupManager
                }
            }

            Log.Information("⚠️ 服务器不在线，开始启动流程...");

            try
            {
                Debug.WriteLine("开始检查Ollama服务器健康状态...");
                Console.WriteLine("开始检查Ollama服务器健康状态...");
                // 使用独立的HttpClient实例避免线程安全问题
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(2);
                
                // 1. 首先检查服务器是否在运行
                var serverUrl = $"{GetServerUrl()}/api/version";
                Debug.WriteLine($"发送服务器健康检查请求到: {serverUrl}");
                Console.WriteLine($"发送服务器健康检查请求到: {serverUrl}");
                var response = client.GetAsync(serverUrl).Result;
                
                if (!response.IsSuccessStatusCode)
                {
                    Debug.WriteLine($"服务器健康检查失败: {response.StatusCode}");
                    Console.WriteLine($"服务器健康检查失败: {response.StatusCode}");
                    return false;
                }
                
                // 2. 然后检查特定模型是否已加载并可用
                var modelUrl = $"{GetServerUrl()}/api/tags";
                Debug.WriteLine($"检查模型加载状态: {modelUrl}");
                Console.WriteLine($"检查模型加载状态: {modelUrl}");
                var modelResponse = client.GetAsync(modelUrl).Result;
                
                if (!modelResponse.IsSuccessStatusCode)
                {
                    Debug.WriteLine("模型列表请求失败");
                    Console.WriteLine("模型列表请求失败");
                    return false;
                }
                
                var content = modelResponse.Content.ReadAsStringAsync().Result;
                var modelName = GetConfiguredModelName();
                var modelLoaded = content.Contains(modelName);
                Debug.WriteLine($"模型 {modelName} {(modelLoaded ? "已加载" : "未加载")}");
                Console.WriteLine($"模型 {modelName} {(modelLoaded ? "已加载" : "未加载")}");
                
                return modelLoaded;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"健康检查失败: {ex.Message}");
                Console.WriteLine($"健康检查失败: {ex.Message}");
                if (ex.InnerException != null)
                {
                    Debug.WriteLine($"内部错误: {ex.InnerException.Message}");
                    Console.WriteLine($"内部错误: {ex.InnerException.Message}");
                }
                return false;
            }
        }

        private static bool IsModelLoaded()
        {
            try
            {
                Debug.WriteLine("开始检查模型加载状态...");
                Console.WriteLine("开始检查模型加载状态...");
                
                var url = $"{GetServerUrl()}/api/tags";
                Debug.WriteLine($"发送模型检查请求到: {url}");
                Console.WriteLine($"发送模型检查请求到: {url}");
                
                // 使用 CancellationToken 实现更可靠的超时控制
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8)); // 8秒超时
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(10); // 备用超时
                
                try
                {
                    // 使用 ConfigureAwait(false) 避免死锁
                    var response = client.GetAsync(url, cts.Token).ConfigureAwait(false).GetAwaiter().GetResult();
                    
                    Debug.WriteLine($"模型检查响应状态码: {response.StatusCode}");
                    Console.WriteLine($"模型检查响应状态码: {response.StatusCode}");
                    
                    if (!response.IsSuccessStatusCode)
                    {
                        Debug.WriteLine($"模型检查请求失败，状态码: {response.StatusCode}");
                        Console.WriteLine($"模型检查请求失败，状态码: {response.StatusCode}");
                        return false;
                    }

                    // 读取响应内容，同样使用超时控制
                    var content = response.Content.ReadAsStringAsync().ConfigureAwait(false).GetAwaiter().GetResult();
                    
                    Debug.WriteLine($"模型检查响应内容长度: {content.Length} 字符");
                    Console.WriteLine($"模型检查响应内容长度: {content.Length} 字符");
                    
                    // 输出前200个字符用于调试
                    var preview = content.Length > 200 ? content.Substring(0, 200) + "..." : content;
                    Debug.WriteLine($"响应内容预览: {preview}");
                    Console.WriteLine($"响应内容预览: {preview}");
                    
                    var modelName = GetConfiguredModelName();
                    var modelLoaded = content.Contains(modelName);
                    Debug.WriteLine($"模型 {modelName} {(modelLoaded ? "已加载" : "未加载")}");
                    Console.WriteLine($"模型 {modelName} {(modelLoaded ? "已加载" : "未加载")}");
                    return modelLoaded;
                }
                catch (OperationCanceledException ex)
                {
                    if (ex is TaskCanceledException)
                    {
                        Debug.WriteLine("模型检查请求被取消或超时 (8秒)");
                        Console.WriteLine("模型检查请求被取消或超时 (8秒)");
                    }
                    else
                    {
                        Debug.WriteLine("模型检查请求被取消");
                        Console.WriteLine("模型检查请求被取消");
                    }
                    return false;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"模型加载检查失败: {ex.Message}");
                Console.WriteLine($"模型加载检查失败: {ex.Message}");
                if (ex.InnerException != null)
                {
                    Debug.WriteLine($"内部错误: {ex.InnerException.Message}");
                    Console.WriteLine($"内部错误: {ex.InnerException.Message}");
                }
                return false;
            }
        }

        private static bool IsModelFullyInitialized()
        {
            try
            {
                Debug.WriteLine("开始检查模型是否完全初始化...");
                Console.WriteLine("开始检查模型是否完全初始化...");
                
                // 1. 先检查模型是否存在于标签列表中
                if (!IsModelLoaded())
                {
                    Debug.WriteLine($"模型 {GetConfiguredModelName()} 未在标签列表中找到");
                    Console.WriteLine($"模型 {GetConfiguredModelName()} 未在标签列表中找到");
                    return false;
                }
                
                // 2. 发送测试推理请求验证模型是否可用
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(30); // 首次推理可能较慢，增加超时时间
                
                var url = $"{GetServerUrl()}/api/generate";
                Debug.WriteLine($"发送测试推理请求到: {url}");
                Console.WriteLine($"发送测试推理请求到: {url}");
                
                var modelName = GetConfiguredModelName();
                var requestData = new
                {
                    model = modelName,
                    prompt = "测试模型初始化，请回复一个字",
                    stream = false,
                    options = new { temperature = 0 }
                };
                
                var json = JsonSerializer.Serialize(requestData);
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                
                var response = client.PostAsync(url, content).Result;
                Debug.WriteLine($"模型测试响应状态码: {response.StatusCode}");
                Console.WriteLine($"模型测试响应状态码: {response.StatusCode}");
                
                if (!response.IsSuccessStatusCode)
                {
                    Debug.WriteLine("模型测试请求失败，返回非成功状态码");
                    Console.WriteLine("模型测试请求失败，返回非成功状态码");
                    return false;
                }
                
                var responseText = response.Content.ReadAsStringAsync().Result;
                Debug.WriteLine($"模型测试响应内容: {responseText}");
                Console.WriteLine($"模型测试响应内容: {responseText}");
                
                return true;
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"模型初始化检查失败: {ex.Message}");
                Console.WriteLine($"模型初始化检查失败: {ex.Message}");
                if (ex.InnerException != null)
                {
                    Debug.WriteLine($"内部错误: {ex.InnerException.Message}");
                    Console.WriteLine($"内部错误: {ex.InnerException.Message}");
                }
                return false;
            }
        }

        public static bool IsServerOnline()
        {
            // 只检查服务器是否能响应请求，不检查模型（修复异步等待问题）
            try
            {
                var serverUrl = $"{GetServerUrl()}/api/version";
                Console.WriteLine($"  → 检查服务器: {serverUrl}");
                Log.Information("🔍 开始检查服务器连接: {Url}", serverUrl);
                
                // 使用独立的HttpClient实例避免线程安全问题
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(2);
                
                // 使用安全的异步等待方式，避免死锁和未观察异常
                var responseTask = client.GetAsync(serverUrl);
                bool completed = responseTask.Wait(3000); // 等待3秒
                
                if (!completed)
                {
                    Console.WriteLine($"  → 检查超时 (3秒)");
                    Log.Warning("⏰ 服务器连接检查超时（3秒）");
                    return false;
                }
                
                if (responseTask.IsFaulted)
                {
                    var error = responseTask.Exception?.GetBaseException()?.Message ?? "未知错误";
                    Console.WriteLine($"  → 检查失败: {error}");
                    Log.Error("❌ 服务器连接检查失败: {Error}", error);
                    return false;
                }
                
                var response = responseTask.Result;
                var isOnline = response.IsSuccessStatusCode;
                Console.WriteLine($"  → 响应状态: {response.StatusCode} ({(isOnline ? "在线" : "离线")})");
                Log.Information("📡 服务器响应状态: {StatusCode} ({Status})", response.StatusCode, isOnline ? "在线" : "离线");
                
                if (isOnline)
                {
                    try
                    {
                        var content = response.Content.ReadAsStringAsync().Result;
                        var truncated = content.Length > 50 ? content.Substring(0, 50) + "..." : content;
                        Console.WriteLine($"  → 版本信息: {truncated}");
                        Log.Information("✅ 服务器版本信息: {Version}", truncated);
                    }
                    catch (Exception ex) 
                    { 
                        Log.Warning("⚠️ 无法读取版本信息: {Error}", ex.Message);
                    }
                }
                
                return isOnline;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"  → 检查异常: {ex.Message}");
                Log.Error("💥 服务器连接检查异常: {Error}", ex.Message);
                if (ex.InnerException != null)
                {
                    Console.WriteLine($"  → 内部异常: {ex.InnerException.Message}");
                    Log.Error("🔍 内部异常: {InnerError}", ex.InnerException.Message);
                }
                return false;
            }
        }

        // 新增方法: 下载并初始化模型
        private static bool DownloadAndInitializeModel()
        {
            try
            {
                var modelName = GetConfiguredModelName();
                Debug.WriteLine($"开始下载并初始化模型 {modelName}...");
                Console.WriteLine($"开始下载并初始化模型 {modelName}...");
                
                // 1. 检查模型是否已存在
                Console.WriteLine("检查模型是否已在Ollama中注册...");
                if (IsModelLoaded())
                {
                    Debug.WriteLine("模型已在Ollama中注册，检查是否可用...");
                    Console.WriteLine("✅ 模型已在Ollama中注册，检查是否可用...");
                    return TestModel();
                }
                else
                {
                    Console.WriteLine("⚠️ 模型未在Ollama中注册，需要下载或重新注册");
                    Console.WriteLine("这可能需要较长时间，请耐心等待...");
                }
                
                // 重置下载进度变量
                _totalBytes = 0;
                _downloadedBytes = 0;
                _downloadStartTime = DateTime.Now;
                _downloadStatus = "准备下载";
                
                // 2. 使用API触发模型下载 (使用流式下载以获取进度)
                return DownloadModelWithProgress();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"下载和初始化模型失败: {ex.Message}");
                Console.WriteLine($"下载和初始化模型失败: {ex.Message}");
                if (ex.InnerException != null)
                {
                    Debug.WriteLine($"内部错误: {ex.InnerException.Message}");
                    Console.WriteLine($"内部错误: {ex.InnerException.Message}");
                }
                return false;
            }
        }
        
        // 新增下载模型和显示进度的方法
        private static bool DownloadModelWithProgress()
        {
            var modelName = GetConfiguredModelName();
            Debug.WriteLine($"触发模型 {modelName} 下载（带进度显示）...");
            Console.WriteLine($"触发模型 {modelName} 下载（带进度显示）...");
            Console.WriteLine($"已设置HTTP客户端超时时间为{HTTP_CLIENT_TIMEOUT_SECONDS}秒（{HTTP_CLIENT_TIMEOUT_SECONDS/3600}小时）");
            
            using (var client = new HttpClient())
            {
                client.Timeout = TimeSpan.FromSeconds(HTTP_CLIENT_TIMEOUT_SECONDS);
                
                var pullUrl = $"{GetServerUrl()}/api/pull";
                var requestData = new
                {
                    name = modelName,
                    stream = true // 使用流式响应获取进度
                };
                
                var json = JsonSerializer.Serialize(requestData);
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                
                try
                {
                    // 发送请求并获取流式响应，使用更安全的方式
                    var responseTask = client.PostAsync(pullUrl, content);
                    if (!responseTask.Wait(60000)) // 等待60秒发送请求
                    {
                        Debug.WriteLine("发送模型拉取请求超时");
                        Console.WriteLine("发送模型拉取请求超时");
                        return false;
                    }
                    
                    if (responseTask.IsFaulted)
                    {
                        var error = responseTask.Exception?.GetBaseException()?.Message ?? "未知错误";
                        Debug.WriteLine($"发送模型拉取请求失败: {error}");
                        Console.WriteLine($"发送模型拉取请求失败: {error}");
                        return false;
                    }
                    
                    using (var response = responseTask.Result)
                    {
                        if (!response.IsSuccessStatusCode)
                        {
                            Debug.WriteLine($"模型拉取请求失败: {response.StatusCode}");
                            Console.WriteLine($"模型拉取请求失败: {response.StatusCode}");
                            return false;
                        }
                        
                        Console.WriteLine("收到拉取请求响应，状态码: " + response.StatusCode);
                        Console.WriteLine("开始读取流式响应...");
                        
                        // 获取响应流，使用更安全的方式
                        var streamTask = response.Content.ReadAsStreamAsync();
                        if (!streamTask.Wait(30000)) // 等待30秒获取流
                        {
                            Debug.WriteLine("获取响应流超时");
                            Console.WriteLine("获取响应流超时");
                            return false;
                        }
                        
                        if (streamTask.IsFaulted)
                        {
                            var error = streamTask.Exception?.GetBaseException()?.Message ?? "未知错误";
                            Debug.WriteLine($"获取响应流失败: {error}");
                            Console.WriteLine($"获取响应流失败: {error}");
                            return false;
                        }
                        
                        using (var stream = streamTask.Result)
                        using (var reader = new StreamReader(stream))
                        {
                            string? line;
                            bool isDownloading = false;
                            int totalLines = 0;
                            int progressLines = 0;
                            
                            // 使用更简单的正则表达式，更容易匹配Ollama输出
                            var progressRegex = new Regex(@"(\d+)%"); // 简化的正则表达式只匹配百分比
                            var downloadSizeRegex = new Regex(@"(\d+\.\d+\s*[KMGT]?B)"); // 匹配下载大小
                            
                            _downloadStartTime = DateTime.Now;
                            Console.WriteLine("开始下载，等待进度信息...");
                            
                            // 读取流式响应的每一行
                            while ((line = reader.ReadLine()) != null)
                            {
                                totalLines++;
                                
                                // 输出原始行内容进行调试
                                Console.WriteLine($"原始行 #{totalLines}: {line}");
                                
                                // 检查是否包含进度信息
                                var progressMatch = progressRegex.Match(line);
                                var sizeMatch = downloadSizeRegex.Match(line);
                                
                                if (progressMatch.Success)
                                {
                                    progressLines++;
                                    isDownloading = true;
                                    var percent = progressMatch.Groups[1].Value;
                                    var downloadedSize = sizeMatch.Success ? sizeMatch.Groups[1].Value : "计算中...";
                                    
                                    var timeElapsed = (DateTime.Now - _downloadStartTime).TotalSeconds;
                                    var speedInfo = timeElapsed > 0 && sizeMatch.Success ? $", 约 {CalculateSpeed(downloadedSize, timeElapsed)}/s" : "";
                                    
                                    _downloadStatus = $"下载中: {percent}% | {downloadedSize}{speedInfo}";
                                    DrawTextProgressBar(int.Parse(percent), 100);
                                    
                                    // 强制控制台刷新显示
                                    Console.WriteLine();
                                }
                                else if (line.Contains("success", StringComparison.OrdinalIgnoreCase))
                                {
                                    // 下载完成
                                    _downloadStatus = "下载完成，正在加载模型...";
                                    Console.WriteLine("\n" + _downloadStatus);
                                    DrawTextProgressBar(100, 100);
                                    Console.WriteLine(); // 添加额外的换行
                                    isDownloading = true;
                                    break;
                                }
                            }
                            
                            // 打印处理的行数统计
                            Console.WriteLine($"处理了 {totalLines} 行内容，其中包含 {progressLines} 行进度信息");
                            
                            // 等待模型加载
                            if (isDownloading)
                            {
                                DateTime modelStartTime = DateTime.Now;
                                Console.WriteLine("模型下载完成，等待加载...");
                                
                                while ((DateTime.Now - modelStartTime).TotalSeconds < MODEL_DOWNLOAD_TIMEOUT)
                                {
                                    if (IsModelLoaded())
                                    {
                                        DrawTextProgressBar(100, 100);
                                        Console.WriteLine("模型已加载，进行可用性测试...");
                                        
                                        if (TestModel())
                                        {
                                            Console.WriteLine("模型测试通过，初始化成功!");
                                            
                                            // 🎯 【关键】验证GPU使用情况
                                            Console.WriteLine("\n🔍 验证GPU使用情况...");
                                            CheckGpuMemoryAfter();
                                            
                                            // 验证模型是否真正使用GPU
                                            Console.WriteLine("\n🧪 验证模型GPU加速状态...");
                                            VerifyModelUsingGpu();
                                            
                                            // 检查Level Zero状态
                                            Console.WriteLine("\n🔧 检查Intel Level Zero状态...");
                                            CheckLevelZeroStatus();
                                            
                                            return true;
                                        }
                                        else
                                        {
                                            Console.WriteLine("模型加载后测试失败，可能仍在初始化...");
                                            Thread.Sleep(5000); // 等待5秒后重试
                                        }
                                    }
                                    else
                                    {
                                        Thread.Sleep(2000); // 每2秒检查一次
                                        Console.WriteLine("等待模型加载...");
                                    }
                                }
                                
                                Console.WriteLine($"模型加载超时，超过 {MODEL_DOWNLOAD_TIMEOUT} 秒");
                                return false;
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"下载模型时出错: {ex.Message}");
                    Console.WriteLine($"下载模型时出错: {ex.Message}");
                    if (ex.InnerException != null)
                    {
                        Debug.WriteLine($"内部错误: {ex.InnerException.Message}");
                        Console.WriteLine($"内部错误: {ex.InnerException.Message}");
                    }
                    return false;
                }
            }
            
            return false;
        }
        
        // 计算下载速度
        private static string CalculateSpeed(string downloadedSize, double timeElapsedSeconds)
        {
            try 
            {
                // 解析下载大小（支持KB, MB, GB等单位）
                var parts = downloadedSize.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 2) return "计算中...";
                
                double size = double.Parse(parts[0]);
                string unit = parts[1];
                
                // 估算下载速度
                double bytesPerSecond = size / timeElapsedSeconds;
                
                if (unit.StartsWith("K")) return $"{bytesPerSecond:F2} KB";
                if (unit.StartsWith("M")) return $"{bytesPerSecond:F2} MB";
                if (unit.StartsWith("G")) return $"{bytesPerSecond:F2} GB";
                
                return $"{bytesPerSecond:F2} {unit}/s";
            }
            catch
            {
                return "计算中...";
            }
        }
        
        // 绘制文本进度条
        private static void DrawTextProgressBar(int progress, int total)
        {
            // 绘制文本进度条 [####------] 40%
            int progressBarWidth = 50;
            int filledWidth = (int)Math.Round(progressBarWidth * progress / (double)total);
            
            Console.Write("\r[");
            
            // 填充已完成部分
            Console.BackgroundColor = ConsoleColor.Green;
            Console.Write(new string(' ', filledWidth));
            Console.ResetColor();
            
            // 填充剩余部分
            Console.Write(new string('-', progressBarWidth - filledWidth));
            Console.Write($"] {progress}% {_downloadStatus}".PadRight(30));
            
            // 将光标移到行末，防止覆盖
            Console.CursorLeft = 0;
        }

        // 新增方法: 测试模型是否可用
        private static bool TestModel()
        {
            try
            {
                Debug.WriteLine("开始测试模型可用性...");
                Console.WriteLine("开始测试模型可用性...");
                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(10);
                
                var url = $"{GetServerUrl()}/api/generate";
                Debug.WriteLine($"发送测试请求到: {url}");
                Console.WriteLine($"发送测试请求到: {url}");
                
                var requestData = new
                {
                    model = GetConfiguredModelName(),
                    prompt = "Hello",
                    stream = false,
                    keep_alive = "30m" // 保持模型在内存中30分钟
                };
                
                var json = JsonSerializer.Serialize(requestData);
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                
                var response = client.PostAsync(url, content).Result;
                Debug.WriteLine($"测试响应状态码: {response.StatusCode}");
                Console.WriteLine($"测试响应状态码: {response.StatusCode}");
                
                if (response.IsSuccessStatusCode)
                {
                    var responseContent = response.Content.ReadAsStringAsync().Result;
                    Debug.WriteLine($"模型测试成功，响应: {responseContent.Substring(0, Math.Min(100, responseContent.Length))}...");
                    Console.WriteLine($"模型测试成功，响应: {responseContent.Substring(0, Math.Min(100, responseContent.Length))}...");
                    return true;
                }
                else
                {
                    Debug.WriteLine($"模型测试失败: {response.StatusCode}");
                    Console.WriteLine($"模型测试失败: {response.StatusCode}");
                    return false;
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"模型测试失败: {ex.Message}");
                Console.WriteLine($"模型测试失败: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// 预热模型以减少后续请求的延迟
        /// </summary>
        private static void WarmupModel()
        {
            try
            {
                Debug.WriteLine("开始预热模型以减少后续延迟...");
                Console.WriteLine("开始预热模型以减少后续延迟...");

                // 发送测试请求来预热模型
                var testRequest = new
                {
                    model = GetConfiguredModelName(),
                    prompt = "Hello",
                    stream = false,
                    options = new
                    {
                        temperature = 0.1,
                        num_predict = 5
                    }
                };

                var json = System.Text.Json.JsonSerializer.Serialize(testRequest);
                var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

                using var httpClient = new HttpClient();
                httpClient.Timeout = TimeSpan.FromSeconds(30);

                var response = httpClient.PostAsync($"{GetServerUrl()}/api/generate", content).Result;

                if (response.IsSuccessStatusCode)
                {
                    var responseContent = response.Content.ReadAsStringAsync().Result;
                    Debug.WriteLine("模型预热完成");
                    Console.WriteLine("模型预热完成");
                    
                    // 检查响应时间来验证GPU加速
                    var startTime = DateTime.Now;
                    var testResponse = httpClient.PostAsync($"{GetServerUrl()}/api/generate", content).Result;
                    var endTime = DateTime.Now;
                    var responseTimeMs = (endTime - startTime).TotalMilliseconds;
                    
                    Console.WriteLine($"模型响应时间: {responseTimeMs:F0} ms");
                    
                    if (responseTimeMs < 2000) // 如果响应时间小于2秒，可能是使用了GPU
                    {
                        Console.WriteLine("✅ 模型响应速度较快，可能正在使用GPU加速");
                    }
                    else
                    {
                        Console.WriteLine("⚠️ 模型响应较慢，可能使用CPU推理，建议检查GPU配置");
                    }
                    
                    // 验证GPU内存使用情况
                    VerifyGpuMemoryUsage();
                    
                    // 验证模型是否真正使用GPU
                    if (VerifyModelUsingGpu())
                    {
                        Console.WriteLine("🎯 确认模型正在使用Intel Arc GPU进行推理");
                    }
                    else
                    {
                        Console.WriteLine("⚠️ 模型可能未正确使用GPU，建议检查驱动和环境配置");
                    }
                }
                else
                {
                    Debug.WriteLine($"模型预热失败: {response.StatusCode}");
                    Console.WriteLine($"模型预热失败: {response.StatusCode}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"模型预热过程中出错: {ex.Message}");
                Console.WriteLine($"模型预热过程中出错: {ex.Message}");
            }
        }
        
        /// <summary>
        /// 验证GPU内存使用情况
        /// </summary>
        private static void VerifyGpuMemoryUsage()
        {
            try
            {
                Console.WriteLine("检查GPU内存使用情况...");
                
                // 方法1: 使用Intel GPU监控工具检查GPU使用率
                var intelGpuTop = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/c intel_gpu_top -n 1 -o -",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using (var process = Process.Start(intelGpuTop))
                {
                    var output = process.StandardOutput.ReadToEnd();
                    var error = process.StandardError.ReadToEnd();
                    process.WaitForExit(5000); // 最多等待5秒

                    if (!string.IsNullOrEmpty(output))
                    {
                        Console.WriteLine($"Intel GPU使用情况:\n{output}");
                        
                        // 检查是否有显著的GPU活动
                        if (output.Contains("compute") || output.Contains("render"))
                        {
                            Console.WriteLine("✅ 检测到GPU计算活动，模型正在使用GPU");
                        }
                    }
                    
                    if (!string.IsNullOrEmpty(error) && !error.Contains("not found"))
                    {
                        Console.WriteLine($"GPU监控工具输出: {error}");
                    }
                }
                
                // 方法2: 使用WMI检查Intel GPU内存使用
                try 
                {
                    var wmiQuery = new ProcessStartInfo
                    {
                        FileName = "cmd.exe",
                        Arguments = "/c wmic path Win32_VideoController get Name,AdapterRAM,CurrentBitsPerPixel",
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    };
                    
                    using (var wmiProcess = Process.Start(wmiQuery))
                    {
                        var wmiOutput = wmiProcess.StandardOutput.ReadToEnd();
                        wmiProcess.WaitForExit(3000);
                        
                        if (!string.IsNullOrEmpty(wmiOutput) && wmiOutput.ToLower().Contains("intel"))
                        {
                            Console.WriteLine($"GPU硬件信息:\n{wmiOutput}");
                        }
                    }
                }
                catch (Exception wmiEx)
                {
                    Console.WriteLine($"WMI GPU查询失败: {wmiEx.Message}");
                }
                
                // 方法3: 检查Level Zero运行时状态
                CheckLevelZeroStatus();
                
            }
            catch (Exception ex)
            {
                Console.WriteLine($"GPU内存使用检查失败: {ex.Message}");
                Console.WriteLine("注意: 这不影响模型运行，仅用于诊断GPU使用情况");
            }
        }

                 private static void CheckLevelZeroStatus()
         {
             try
             {
                 Console.WriteLine("检查Level Zero运行时状态...");
                 
                 // 尝试检查Level Zero环境
                 var zeInfo = new ProcessStartInfo
                 {
                     FileName = "cmd.exe",
                     Arguments = "/c set ZE_",
                     UseShellExecute = false,
                     RedirectStandardOutput = true,
                     RedirectStandardError = true,
                     CreateNoWindow = true
                 };
                 
                 using (var process = Process.Start(zeInfo))
                 {
                     var output = process.StandardOutput.ReadToEnd();
                     process.WaitForExit(2000);
                     
                     if (!string.IsNullOrEmpty(output))
                     {
                         Console.WriteLine($"Level Zero环境变量:\n{output}");
                     }
                     else
                     {
                         Console.WriteLine("未找到Level Zero环境变量，可能需要安装Intel GPU驱动");
                     }
                 }
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"Level Zero状态检查失败: {ex.Message}");
             }
         }

         /// <summary>
         /// 验证模型是否真正在使用GPU
         /// </summary>
         private static bool VerifyModelUsingGpu()
         {
             try
             {
                 Console.WriteLine("验证模型GPU使用情况...");
                 
                 // 检查1: 查找ollama.exe进程的内存使用情况
                 var ollamaProcesses = Process.GetProcessesByName("ollama");
                 var totalMemoryMB = 0L;
                 
                 foreach (var proc in ollamaProcesses)
                 {
                     try
                     {
                         totalMemoryMB += proc.WorkingSet64 / (1024 * 1024);
                         Console.WriteLine($"Ollama进程 PID {proc.Id}: 内存使用 {proc.WorkingSet64 / (1024 * 1024)} MB");
                     }
                     catch (Exception ex)
                     {
                         Console.WriteLine($"无法获取进程 {proc.Id} 的内存信息: {ex.Message}");
                     }
                 }
                 
                 Console.WriteLine($"Ollama总内存使用: {totalMemoryMB} MB");
                 
                 // 检查2: 发送请求并监控GPU使用
                 Console.WriteLine("发送测试请求并监控GPU活动...");
                 var startTime = DateTime.Now;
                 
                 using var client = new HttpClient();
                 client.Timeout = TimeSpan.FromSeconds(15);
                 
                 var requestData = new
                 {
                     model = GetConfiguredModelName(),
                     prompt = "Please translate the following English text to Chinese: Hello world",
                     stream = false,
                     options = new
                     {
                         temperature = 0.1,
                         num_predict = 50
                     }
                 };
                 
                 var json = JsonSerializer.Serialize(requestData);
                 var content = new StringContent(json, Encoding.UTF8, "application/json");
                 
                 var response = client.PostAsync($"{GetServerUrl()}/api/generate", content).Result;
                 var endTime = DateTime.Now;
                 var responseTime = (endTime - startTime).TotalMilliseconds;
                 
                 Console.WriteLine($"推理响应时间: {responseTime:F0} ms");
                 
                 // 检查3: 基于响应时间判断是否使用GPU
                 bool likelyUsingGpu = false;
                 
                 if (response.IsSuccessStatusCode)
                 {
                     var responseContent = response.Content.ReadAsStringAsync().Result;
                     Console.WriteLine($"测试响应: {responseContent.Substring(0, Math.Min(100, responseContent.Length))}...");
                     
                     // GPU加速的推理通常比CPU快得多
                     if (responseTime < 3000) // 小于3秒
                     {
                         Console.WriteLine("✅ 响应时间较快，很可能正在使用GPU加速");
                         likelyUsingGpu = true;
                     }
                     else
                     {
                         Console.WriteLine("⚠️ 响应时间较慢，可能在使用CPU推理");
                     }
                 }
                 
                 // 检查4: 查看进程Command Line是否包含GPU相关参数
                 CheckOllamaProcessCommandLine();
                 
                 return likelyUsingGpu;
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"验证模型GPU使用失败: {ex.Message}");
                 return false;
             }
         }

         /// <summary>
         /// 检查Ollama进程的命令行参数
         /// </summary>
         private static void CheckOllamaProcessCommandLine()
         {
             try
             {
                 Console.WriteLine("检查Ollama进程启动参数...");
                 
                 var wmiQuery = new ProcessStartInfo
                 {
                     FileName = "cmd.exe",
                     Arguments = "/c wmic process where \"name='ollama.exe'\" get ProcessId,CommandLine",
                     UseShellExecute = false,
                     RedirectStandardOutput = true,
                     RedirectStandardError = true,
                     CreateNoWindow = true
                 };
                 
                 using (var process = Process.Start(wmiQuery))
                 {
                     var output = process.StandardOutput.ReadToEnd();
                     process.WaitForExit(3000);
                     
                     if (!string.IsNullOrEmpty(output))
                     {
                         Console.WriteLine($"Ollama进程信息:\n{output}");
                     }
                 }
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"检查进程命令行失败: {ex.Message}");
             }
         }

        /// <summary>
        /// 尝试优雅地卸载模型，释放GPU内存
        /// </summary>
        private static void TryUnloadModel()
        {
            try
            {
                Debug.WriteLine("尝试优雅卸载模型以释放GPU内存...");
                Console.WriteLine("尝试优雅卸载模型以释放GPU内存...");

                if (!IsServerOnline())
                {
                    Debug.WriteLine("服务器不在线，跳过模型卸载");
                    Console.WriteLine("服务器不在线，跳过模型卸载");
                    return;
                }

                using var client = new HttpClient();
                client.Timeout = TimeSpan.FromSeconds(10);
                
                // 发送空的generate请求来卸载模型
                var url = $"{GetServerUrl()}/api/generate";
                var unloadData = new
                {
                    model = GetConfiguredModelName(),
                    keep_alive = 0 // 立即卸载模型
                };
                
                var json = JsonSerializer.Serialize(unloadData);
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                
                Debug.WriteLine("发送模型卸载请求...");
                Console.WriteLine("发送模型卸载请求...");
                var response = client.PostAsync(url, content).Result;
                
                if (response.IsSuccessStatusCode)
                {
                    Debug.WriteLine("模型卸载请求发送成功");
                    Console.WriteLine("模型卸载请求发送成功");
                    Thread.Sleep(1000); // 等待卸载完成
                }
                else
                {
                    Debug.WriteLine($"模型卸载请求失败: {response.StatusCode}");
                    Console.WriteLine($"模型卸载请求失败: {response.StatusCode}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"模型卸载过程中出错: {ex.Message}");
                Console.WriteLine($"模型卸载过程中出错: {ex.Message}");
            }
        }

        /// <summary>
        /// 强制清理GPU内存和缓存
        /// </summary>
        private static void ForceCleanupGpuMemory()
        {
            try
            {
                Debug.WriteLine("开始强制清理GPU内存和缓存...");
                Console.WriteLine("开始强制清理GPU内存和缓存...");

                // 1. 清理SYCL缓存目录
                ClearSyclCache();

                // 2. 尝试运行垃圾回收
                GC.Collect();
                GC.WaitForPendingFinalizers();
                GC.Collect();

                // 3. 等待GPU内存释放
                Thread.Sleep(1000);

                Debug.WriteLine("GPU内存清理完成");
                Console.WriteLine("GPU内存清理完成");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"GPU内存清理过程中出错: {ex.Message}");
                Console.WriteLine($"GPU内存清理过程中出错: {ex.Message}");
            }
        }

        /// <summary>
        /// 清理SYCL缓存目录
        /// </summary>
        private static void ClearSyclCache()
        {
            try
            {
                Debug.WriteLine("清理SYCL缓存目录...");
                Console.WriteLine("清理SYCL缓存目录...");

                // SYCL缓存通常位于用户临时目录
                var tempPath = Path.GetTempPath();
                var syclCachePaths = new[]
                {
                    Path.Combine(tempPath, "sycl_cache"),
                    Path.Combine(tempPath, "intel_opencl_cache"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "sycl_cache")
                };

                foreach (var cachePath in syclCachePaths)
                {
                    if (Directory.Exists(cachePath))
                    {
                        try
                        {
                            Debug.WriteLine($"清理缓存目录: {cachePath}");
                            Console.WriteLine($"清理缓存目录: {cachePath}");
                            
                            // 删除缓存文件但保留目录结构
                            var files = Directory.GetFiles(cachePath, "*", SearchOption.AllDirectories);
                            foreach (var file in files)
                            {
                                try
                                {
                                    File.Delete(file);
                                }
                                catch (Exception ex)
                                {
                                    Debug.WriteLine($"无法删除缓存文件 {file}: {ex.Message}");
                                    Console.WriteLine($"无法删除缓存文件 {file}: {ex.Message}");
                                }
                            }
                            
                            Debug.WriteLine($"缓存目录 {cachePath} 清理完成");
                            Console.WriteLine($"缓存目录 {cachePath} 清理完成");
                        }
                        catch (Exception ex)
                        {
                            Debug.WriteLine($"清理缓存目录 {cachePath} 时出错: {ex.Message}");
                            Console.WriteLine($"清理缓存目录 {cachePath} 时出错: {ex.Message}");
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"SYCL缓存清理过程中出错: {ex.Message}");
                Console.WriteLine($"SYCL缓存清理过程中出错: {ex.Message}");
            }
        }

        // 新增方法: 强制清理所有 ollama 相关进程
        private static void ForceKillAllOllamaProcesses()
        {
            try
            {
                Debug.WriteLine("查找并终止所有残留的Ollama相关进程...");
                Console.WriteLine("查找并终止所有残留的Ollama相关进程...");
                
                // 终止所有 ollama.exe 进程
                try 
                {
                    var ollamaProcesses = Process.GetProcessesByName(OLLAMA_PROCESS_NAME);
                    Debug.WriteLine($"找到 {ollamaProcesses.Length} 个 ollama.exe 进程");
                    Console.WriteLine($"找到 {ollamaProcesses.Length} 个 ollama.exe 进程");
                    
                    foreach (var process in ollamaProcesses)
                    {
                        try
                        {
                            // 检查进程是否仍然有效
                            if (process.HasExited)
                            {
                                Debug.WriteLine($"ollama.exe 进程 PID {process.Id} 已经退出");
                                Console.WriteLine($"ollama.exe 进程 PID {process.Id} 已经退出");
                                continue;
                            }
                            
                            Debug.WriteLine($"正在终止 ollama.exe 进程，PID: {process.Id}");
                            Console.WriteLine($"正在终止 ollama.exe 进程，PID: {process.Id}");
                            process.Kill();
                            
                            // 使用更短的等待时间避免阻塞
                            if (process.WaitForExit(3000))
                            {
                                Debug.WriteLine($"ollama.exe 进程 PID {process.Id} 已正常终止");
                                Console.WriteLine($"ollama.exe 进程 PID {process.Id} 已正常终止");
                            }
                            else
                            {
                                Debug.WriteLine($"ollama.exe 进程 PID {process.Id} 终止超时");
                                Console.WriteLine($"ollama.exe 进程 PID {process.Id} 终止超时");
                            }
                        }
                        catch (Exception ex)
                        {
                            Debug.WriteLine($"停止 ollama.exe 进程 PID {process.Id} 时出错: {ex.Message}");
                            Console.WriteLine($"停止 ollama.exe 进程 PID {process.Id} 时出错: {ex.Message}");
                        }
                        finally
                        {
                            try 
                            {
                                process?.Dispose();
                            }
                            catch { /* 忽略 Dispose 错误 */ }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"查找 ollama.exe 进程时出错: {ex.Message}");
                    Console.WriteLine($"查找 ollama.exe 进程时出错: {ex.Message}");
                }

                // 终止所有 ollama-lib.exe 进程 (这是GPU内存的关键)
                try 
                {
                    var ollamaLibProcesses = Process.GetProcessesByName("ollama-lib");
                    Debug.WriteLine($"找到 {ollamaLibProcesses.Length} 个 ollama-lib.exe 进程");
                    Console.WriteLine($"找到 {ollamaLibProcesses.Length} 个 ollama-lib.exe 进程");
                    
                    foreach (var process in ollamaLibProcesses)
                    {
                        try
                        {
                            if (process.HasExited)
                            {
                                Debug.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 已经退出");
                                Console.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 已经退出");
                                continue;
                            }
                            
                            Debug.WriteLine($"正在终止 ollama-lib.exe 进程，PID: {process.Id}");
                            Console.WriteLine($"正在终止 ollama-lib.exe 进程，PID: {process.Id}");
                            process.Kill();
                            
                            if (process.WaitForExit(5000))  // 给GPU释放足够时间
                            {
                                Debug.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 已正常终止");
                                Console.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 已正常终止");
                            }
                            else
                            {
                                Debug.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 终止超时");
                                Console.WriteLine($"ollama-lib.exe 进程 PID {process.Id} 终止超时");
                            }
                        }
                        catch (Exception ex)
                        {
                            Debug.WriteLine($"停止 ollama-lib.exe 进程 PID {process.Id} 时出错: {ex.Message}");
                            Console.WriteLine($"停止 ollama-lib.exe 进程 PID {process.Id} 时出错: {ex.Message}");
                        }
                        finally
                        {
                            try 
                            {
                                process?.Dispose();
                            }
                            catch { /* 忽略 Dispose 错误 */ }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"查找 ollama-lib.exe 进程时出错: {ex.Message}");
                    Console.WriteLine($"查找 ollama-lib.exe 进程时出错: {ex.Message}");
                }
                
                Debug.WriteLine("Ollama进程清理尝试完成");
                Console.WriteLine("Ollama进程清理尝试完成");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"停止所有 ollama 相关进程时出错: {ex.Message}");
                Console.WriteLine($"停止所有 ollama 相关进程时出错: {ex.Message}");
                Debug.WriteLine($"异常详情: {ex}");
                Console.WriteLine($"异常详情: {ex}");
            }
        }

                 /// <summary>
         /// 输出所有GPU相关环境变量用于调试
         /// </summary>
         private static void LogAllGpuEnvironmentVariables(ProcessStartInfo startInfo)
         {
             try
             {
                 Console.WriteLine("\n=== GPU环境变量配置详情 ===");
                 
                 var gpuVars = new[]
                 {
                     "OLLAMA_NUM_GPU", "ZES_ENABLE_SYSMAN", "SYCL_CACHE_PERSISTENT",
                     "SYCL_DEVICE_TYPE", "ONEAPI_DEVICE_SELECTOR", 
                     "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS",
                     "SYCL_PI_LEVEL_ZERO_USE_UNIFIED_MEMORY_POOL",
                     "SYCL_PI_LEVEL_ZERO_DEVICE_SCOPE_EVENTS",
                     "SYCL_PI_LEVEL_ZERO_USE_COPY_ENGINE",
                     "SYCL_PREFER_UR", "SYCL_ENABLE_PCI", "SYCL_DEVICE_ALLOWLIST",
                     "ZE_FLAT_DEVICE_HIERARCHY", "ZE_ENABLE_PCI_ID_DEVICE_ORDER", "ZE_AFFINITY_MASK",
                     "SYCL_PI_TRACE", "SYCL_RT_WARNING_LEVEL", "ZE_ENABLE_VALIDATION_LAYER",
                     "NEOReadDebugKeys", "OverrideDefaultFP64Settings"
                 };
                 
                 foreach (var varName in gpuVars)
                 {
                     if (startInfo.EnvironmentVariables.ContainsKey(varName))
                     {
                         Console.WriteLine($"  {varName} = {startInfo.EnvironmentVariables[varName]}");
                     }
                     else
                     {
                         Console.WriteLine($"  {varName} = <未设置>");
                     }
                 }
                 Console.WriteLine("========================\n");
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"环境变量调试输出失败: {ex.Message}");
             }
         }

          /// <summary>
          /// 验证 Ollama 是否为 IPEX-LLM 版本
          /// </summary>
          private static void VerifyOllamaVersion(string exePath)
          {
              try
              {
                  Console.WriteLine("=== 验证 Ollama 版本信息 ===");
                  
                  // 1. 检查文件版本信息
                  if (File.Exists(exePath))
                  {
                      var fileInfo = new FileInfo(exePath);
                      Console.WriteLine($"可执行文件大小: {fileInfo.Length:N0} bytes");
                      Console.WriteLine($"文件创建时间: {fileInfo.CreationTime}");
                      Console.WriteLine($"文件修改时间: {fileInfo.LastWriteTime}");
                      
                      try
                      {
                          var versionInfo = FileVersionInfo.GetVersionInfo(exePath);
                          Console.WriteLine($"文件描述: {versionInfo.FileDescription}");
                          Console.WriteLine($"产品名称: {versionInfo.ProductName}");
                          Console.WriteLine($"版本号: {versionInfo.FileVersion}");
                          
                          // 检查是否包含 IPEX-LLM 相关信息
                          var description = versionInfo.FileDescription ?? "";
                          var productName = versionInfo.ProductName ?? "";
                          
                          if (description.Contains("IPEX") || productName.Contains("IPEX") ||
                              description.Contains("Intel") || productName.Contains("Intel"))
                          {
                              Console.WriteLine("✅ 检测到 Intel IPEX-LLM 版本特征");
                          }
                          else
                          {
                              Console.WriteLine("⚠️ 警告: 未检测到明显的 IPEX-LLM 版本特征");
                              Console.WriteLine("   请确认下载的是 Intel IPEX-LLM 便携版");
                          }
                      }
                      catch (Exception ex)
                      {
                          Console.WriteLine($"读取版本信息失败: {ex.Message}");
                      }
                  }
                  
                  // 2. 检查版本记录文件
                  var versionFile = Path.Combine(ApplicationSetup.OllamaPath, ".version");
                  if (File.Exists(versionFile))
                  {
                      var versionText = File.ReadAllText(versionFile).Trim();
                      Console.WriteLine($"安装版本标识: {versionText}");
                      
                      if (versionText.Contains("ipex-llm"))
                      {
                          Console.WriteLine("✅ 版本记录确认为 IPEX-LLM 版本");
                      }
                      else
                      {
                          Console.WriteLine("⚠️ 警告: 版本记录不匹配 IPEX-LLM");
                      }
                  }
                  else
                  {
                      Console.WriteLine("⚠️ 警告: 未找到版本记录文件");
                  }
                  
                  // 3. 检查目录结构
                  var ollamaDir = ApplicationSetup.OllamaPath;
                  Console.WriteLine($"Ollama 安装目录: {ollamaDir}");
                  
                  if (Directory.Exists(ollamaDir))
                  {
                      var files = Directory.GetFiles(ollamaDir, "*", SearchOption.AllDirectories);
                      Console.WriteLine($"目录包含 {files.Length} 个文件");
                      
                      // 查找 IPEX-LLM 相关的文件
                      var ipexFiles = files.Where(f => 
                          Path.GetFileName(f).ToLower().Contains("ipex") ||
                          Path.GetFileName(f).ToLower().Contains("intel") ||
                          Path.GetFileName(f).ToLower().Contains("sycl") ||
                          Path.GetFileName(f).ToLower().Contains("level")
                      ).ToArray();
                      
                      if (ipexFiles.Length > 0)
                      {
                          Console.WriteLine($"✅ 找到 {ipexFiles.Length} 个 Intel/IPEX 相关文件:");
                          foreach (var file in ipexFiles.Take(5)) // 显示前5个
                          {
                              Console.WriteLine($"   - {Path.GetFileName(file)}");
                          }
                      }
                      else
                      {
                          Console.WriteLine("⚠️ 警告: 未找到 Intel/IPEX 相关文件");
                          Console.WriteLine("   可能不是正确的 IPEX-LLM 版本");
                      }
                  }
                  
                  Console.WriteLine("========================");
              }
              catch (Exception ex)
              {
                  Console.WriteLine($"版本验证过程出错: {ex.Message}");
              }
          }

          private static void VerifyIntelGpuStatus()
         {
             try
             {
                 Debug.WriteLine("验证Intel GPU驱动和设备状态...");
                 Console.WriteLine("验证Intel GPU驱动和设备状态...");

                 // 使用Windows系统信息检查Intel GPU
                 var intelGpuCheck = new ProcessStartInfo
                 {
                     FileName = "cmd.exe",
                     Arguments = "/c wmic path win32_VideoController get name,status",
                     UseShellExecute = false,
                     RedirectStandardOutput = true,
                     RedirectStandardError = true,
                     CreateNoWindow = true
                 };

                 using (var process = Process.Start(intelGpuCheck))
                 {
                     var output = process.StandardOutput.ReadToEnd();
                     var error = process.StandardError.ReadToEnd();
                     process.WaitForExit();

                     Debug.WriteLine($"GPU设备检查结果:\n{output}");
                     Console.WriteLine($"GPU设备检查结果:\n{output}");
                     
                     if (!string.IsNullOrEmpty(error))
                     {
                         Debug.WriteLine($"GPU检查错误: {error}");
                         Console.WriteLine($"GPU检查错误: {error}");
                     }

                     // 检查是否有Intel GPU
                     bool hasIntelGpu = output.ToLower().Contains("intel") && output.ToLower().Contains("graphics");
                     Console.WriteLine($"检测到Intel GPU: {hasIntelGpu}");
                     
                     if (!hasIntelGpu)
                     {
                         Console.WriteLine("⚠️ 警告: 未检测到Intel GPU，可能会使用CPU进行AI推理，速度较慢");
                         Console.WriteLine("请确保：1) 安装了最新的Intel GPU驱动 2) 系统支持Intel Arc/Iris Xe GPU");
                     }
                     else
                     {
                         Console.WriteLine("✅ 检测到Intel GPU，将使用GPU加速进行AI推理");
                     }
                 }
             }
             catch (Exception ex)
             {
                 Debug.WriteLine($"验证Intel GPU驱动和设备状态时出错: {ex.Message}");
                 Console.WriteLine($"验证Intel GPU驱动和设备状态时出错: {ex.Message}");
             }
         }

         /// <summary>
         /// 检查模型加载前的GPU内存状态（基线）
         /// </summary>
         private static void CheckGpuMemoryBefore()
         {
             try
             {
                 CheckCurrentGpuMemory("启动前");
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"检查启动前GPU内存失败: {ex.Message}");
             }
         }

         /// <summary>
         /// 检查模型加载后的GPU内存状态
         /// </summary>
         private static void CheckGpuMemoryAfter()
         {
             try
             {
                 CheckCurrentGpuMemory("模型加载后");
                 Console.WriteLine("💡 如果GPU内存使用没有明显增加，可能原因：");
                 Console.WriteLine("   1. 下载的不是Intel IPEX-LLM版本的Ollama");
                 Console.WriteLine("   2. Intel GPU驱动版本过低或不兼容");
                 Console.WriteLine("   3. 环境变量配置不正确");
                 Console.WriteLine("   4. 模型回退到CPU模式运行");
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"检查模型加载后GPU内存失败: {ex.Message}");
             }
         }

         /// <summary>
         /// 通用GPU内存检查方法
         /// </summary>
         private static void CheckCurrentGpuMemory(string stage)
         {
             try
             {
                 var psInfo = new ProcessStartInfo
                 {
                     FileName = "powershell.exe",
                     Arguments = @"-Command ""Get-WmiObject -Query 'SELECT * FROM Win32_PerfRawData_GPUPerformanceCounters_GPUEngine' | Where-Object {$_.Name -like '*Intel*'} | Select-Object Name, UtilizationPercentage""",
                     UseShellExecute = false,
                     RedirectStandardOutput = true,
                     RedirectStandardError = true,
                     CreateNoWindow = true
                 };

                 using var process = Process.Start(psInfo);
                 var output = process.StandardOutput.ReadToEnd();
                 var error = process.StandardError.ReadToEnd();
                 process.WaitForExit();

                 if (!string.IsNullOrEmpty(output))
                 {
                     Console.WriteLine($"📊 {stage} GPU状态:");
                     Console.WriteLine(output.Trim());
                 }
                 else
                 {
                     // 尝试备用方法：检查任务管理器可见的GPU进程
                     CheckGpuProcesses(stage);
                 }

                 if (!string.IsNullOrEmpty(error) && !error.Contains("WARNING"))
                 {
                     Console.WriteLine($"GPU内存检查警告: {error}");
                 }
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"GPU内存检查失败 ({stage}): {ex.Message}");
                 // 尝试简单的方法
                 CheckGpuProcesses(stage);
             }
         }

         /// <summary>
         /// 检查GPU相关进程（备用方法）
         /// </summary>
         private static void CheckGpuProcesses(string stage)
         {
             try
             {
                 Console.WriteLine($"📊 {stage} GPU进程检查:");
                 
                 var processes = Process.GetProcesses()
                     .Where(p => !p.HasExited && (
                         p.ProcessName.ToLower().Contains("ollama") ||
                         p.ProcessName.ToLower().Contains("intel") ||
                         p.ProcessName.ToLower().Contains("gpu")
                     ))
                     .ToArray();

                 Console.WriteLine($"找到 {processes.Length} 个相关进程:");
                 foreach (var proc in processes.Take(10)) // 限制输出数量
                 {
                     try
                     {
                         Console.WriteLine($"  - {proc.ProcessName} (PID: {proc.Id}, 内存: {proc.WorkingSet64 / 1024 / 1024} MB)");
                     }
                     catch (Exception ex)
                     {
                         Console.WriteLine($"  - {proc.ProcessName} (PID: {proc.Id}, 内存信息获取失败: {ex.Message})");
                     }
                 }

                 foreach (var proc in processes)
                 {
                     try { proc.Dispose(); } catch { }
                 }
             }
             catch (Exception ex)
             {
                 Console.WriteLine($"GPU进程检查失败: {ex.Message}");
             }
         }
    }
} 