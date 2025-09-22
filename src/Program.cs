using LiveCaptionsTranslator.utils;
using System;
using System.IO;
using System.Threading.Tasks;

namespace LiveCaptionsTranslator
{
    internal class Program
    {
        static async Task Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--test")
            {
                if (args.Length > 1 && args[1] == "6")
                {
                    await RunTest6();
                }
                else
                {
                    await RunTests();
                }
                return;
            }
        }

        static async Task RunTest6()
        {
            Console.WriteLine("Test 6: Ollama Server Startup");
            try
            {
                // Ensure environment variables are set
                ApplicationSetup.SetupEnvironmentVariables();
                
                if (OllamaGuardian.StartServer())
                {
                    Console.WriteLine("✓ Ollama server started successfully");
                    Console.WriteLine($"- Server health status: {OllamaGuardian.IsServerHealthy()}");
                }
                else
                {
                    Console.WriteLine("× Ollama server startup failed");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× Ollama server startup error: {ex.Message}");
            }
            finally
            {
                OllamaGuardian.StopServer();
            }
            Console.WriteLine();

            Console.WriteLine("Test completed. Press any key to exit...");
            Console.ReadKey();
        }

        static async Task RunTests()
        {
            Console.WriteLine("Starting ApplicationSetup class tests...\n");

            // Test 1: Check first run status
            Console.WriteLine("Test 1: Check first run status");
            Console.WriteLine($"IsFirstRun = {ApplicationSetup.IsFirstRun}");
            Console.WriteLine($"AppDataPath = {ApplicationSetup.AppDataPath}");
            Console.WriteLine($"OllamaPath = {ApplicationSetup.OllamaPath}");
            Console.WriteLine($"ModelPath = {ApplicationSetup.ModelPath}");
            Console.WriteLine($"DownloadsPath = {ApplicationSetup.DownloadsPath}");
            Console.WriteLine();

            // Test 2: Create directory structure
            Console.WriteLine("Test 2: Create directory structure");
            try
            {
                ApplicationSetup.EnsureDirectoryStructure();
                Console.WriteLine("✓ Directory structure created successfully");
                Console.WriteLine($"- AppDataPath exists: {Directory.Exists(ApplicationSetup.AppDataPath)}");
                Console.WriteLine($"- OllamaPath exists: {Directory.Exists(ApplicationSetup.OllamaPath)}");
                Console.WriteLine($"- ModelPath exists: {Directory.Exists(ApplicationSetup.ModelPath)}");
                Console.WriteLine($"- DownloadsPath exists: {Directory.Exists(ApplicationSetup.DownloadsPath)}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× Directory structure creation failed: {ex.Message}");
            }
            Console.WriteLine();

            // Test 3: Download and install Ollama
            Console.WriteLine("Test 3: Download and install Ollama");
            try
            {
                var progress = new Progress<string>(message => Console.WriteLine($"- {message}"));
                await ApplicationSetup.ExtractOllamaAsync(progress);
                var exePath = ApplicationSetup.GetOllamaExecutablePath();
                Console.WriteLine($"✓ Ollama installation successful");
                Console.WriteLine($"- Executable path: {exePath}");
                Console.WriteLine($"- File exists: {File.Exists(exePath)}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× Ollama installation failed: {ex.Message}");
                if (ex.InnerException != null)
                    Console.WriteLine($"  Inner error: {ex.InnerException.Message}");
            }
            Console.WriteLine();

            // Test 4: Set environment variables
            Console.WriteLine("Test 4: Set environment variables");
            try
            {
                ApplicationSetup.SetupEnvironmentVariables();
                var vars = new[]
                {
                    "OLLAMA_NUM_GPU",
                    "ZES_ENABLE_SYSMAN",
                    "SYCL_CACHE_PERSISTENT",
                    "SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS",
                    "OLLAMA_MODELS",
                    "OLLAMA_HOST"
                };

                foreach (var var in vars)
                {
                    var value = Environment.GetEnvironmentVariable(var);
                    Console.WriteLine($"- {var} = {value}");
                }
                Console.WriteLine("✓ Environment variables set successfully");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× Environment variables setup failed: {ex.Message}");
            }
            Console.WriteLine();

            // Test 5: Complete first-time setup
            Console.WriteLine("Test 5: Complete first-time setup");
            try
            {
                var progress = new Progress<string>(message => Console.WriteLine($"- {message}"));
                await ApplicationSetup.PerformFirstTimeSetup(progress);
                Console.WriteLine("✓ First-time setup completed");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× First-time setup failed: {ex.Message}");
                if (ex.InnerException != null)
                    Console.WriteLine($"  Inner error: {ex.InnerException.Message}");
            }
            Console.WriteLine();

            // Test 6: Ollama server startup
            Console.WriteLine("Test 6: Ollama server startup");
            try
            {
                if (OllamaGuardian.StartServer())
                {
                    Console.WriteLine("✓ Ollama server started successfully");
                    Console.WriteLine($"- Server health status: {OllamaGuardian.IsServerHealthy()}");
                }
                else
                {
                    Console.WriteLine("× Ollama server startup failed");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"× Ollama server startup error: {ex.Message}");
            }
            finally
            {
                OllamaGuardian.StopServer();
            }
            Console.WriteLine();

            Console.WriteLine("Test completed. Press any key to exit...");
            Console.ReadKey();
        }
    }
} 