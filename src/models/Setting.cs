using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using System.Threading;

using LiveCaptionsTranslator.utils;

namespace LiveCaptionsTranslator.models
{
    public class Setting : INotifyPropertyChanged
    {
        public static readonly string FILENAME = "setting.json";
        public static string SettingPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), 
            "DellLiveCaptionsTranslator", 
            FILENAME
        );

        public event PropertyChangedEventHandler? PropertyChanged;

        private int maxIdleInterval = 50;
        private int maxSyncInterval = 3;
        private bool contextAware = false;

        private string targetLanguage;
        private string prompt;
        private string? ignoredUpdateVersion;
        

        private MainWindowState mainWindowState;
        private OverlayWindowState overlayWindowState;
        private Dictionary<string, string> windowBounds;

        private OllamaConfig ollamaConfig;
        
        public int MaxIdleInterval => maxIdleInterval;
        public int MaxSyncInterval
        {
            get => maxSyncInterval;
            set
            {
                maxSyncInterval = value;
                OnPropertyChanged("MaxSyncInterval");
            }
        }
        public bool ContextAware
        {
            get => contextAware;
            set
            {
                contextAware = value;
                OnPropertyChanged("ContextAware");
            }
        }

        // ApiName is no longer needed as we only support Ollama.
        [JsonIgnore] // Exclude from serialization
        public string ApiName => "Ollama";

        public string TargetLanguage
        {
            get => targetLanguage;
            set
            {
                targetLanguage = value;
                OnPropertyChanged("TargetLanguage");
            }
        }
        public string Prompt
        {
            get => prompt;
            set
            {
                prompt = value;
                OnPropertyChanged("Prompt");
            }
        }
        public string? IgnoredUpdateVersion
        {
            get => ignoredUpdateVersion;
            set
            {
                ignoredUpdateVersion = value;
                OnPropertyChanged("IgnoredUpdateVersion");
            }
        }

        public MainWindowState MainWindow
        {
            get => mainWindowState;
            set
            {
                mainWindowState = value;
                OnPropertyChanged("MainWindow");
            }
        }
        public OverlayWindowState OverlayWindow
        {
            get => overlayWindowState;
            set
            {
                overlayWindowState = value;
                OnPropertyChanged("OverlayWindow");
            }
        }
        public Dictionary<string, string> WindowBounds
        {
            get => windowBounds;
            set
            {
                windowBounds = value;
                OnPropertyChanged("WindowBounds");
            }
        }

        public OllamaConfig OllamaConfig
        {
            get => ollamaConfig;
            set
            {
                ollamaConfig = value;
                OnPropertyChanged("OllamaConfig");
            }
        }

        private static Timer? _saveTimer;
        private static readonly object _saveLock = new object();

        public Setting()
        {
            targetLanguage = "zh-CN";
            prompt = "You are a professional simultaneous interpreter specializing in international business communication. " +
                     "Your task is to translate speech content enclosed in 🔤 markers to {0}. " +
                     "CRITICAL RULES: " +
                     "1. Always output ONLY the translated text, never the original text " +
                     "2. Handle incomplete sentences naturally and professionally " +
                     "3. Preserve technical terms, company names, and proper nouns accurately " +
                     "4. Maintain appropriate business tone and formality " +
                     "5. For unclear speech, provide the most likely professional interpretation " +
                     "OUTPUT FORMAT: Single line translation only, remove all 🔤 markers, no explanations or original text.";

            mainWindowState = new MainWindowState();
            overlayWindowState = new OverlayWindowState();

            double screenWidth = System.Windows.SystemParameters.PrimaryScreenWidth;
            double screenHeight = System.Windows.SystemParameters.PrimaryScreenHeight;
            windowBounds = new Dictionary<string, string>
            {
                {
                    "MainWindow", string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0}, {1}, {2}, {3}", (screenWidth - 775) / 2, screenHeight * 3 / 4 - 167, 775, 167)
                },
                {
                    "OverlayWindow", string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0}, {1}, {2}, {3}", (screenWidth - 650) / 2, screenHeight * 5 / 6 - 135, 650, 135)
                },
            };

            ollamaConfig = new OllamaConfig();
        }

        [JsonConstructor]
        public Setting(string targetLanguage, string prompt, string? ignoredUpdateVersion,
                       MainWindowState mainWindowState, OverlayWindowState overlayWindowState,
                       OllamaConfig ollamaConfig, Dictionary<string, string> windowBounds)
        {
            this.targetLanguage = targetLanguage;
            this.prompt = prompt;
            this.ignoredUpdateVersion = ignoredUpdateVersion;
            this.mainWindowState = mainWindowState;
            this.overlayWindowState = overlayWindowState;
            this.ollamaConfig = ollamaConfig ?? new OllamaConfig();
            this.windowBounds = windowBounds;
        }

        public static Setting Load()
        {
            // If setting exists in AppData, load it
            if (File.Exists(SettingPath))
            {
                return Load(SettingPath);
            }
            
            // If not, check for setting file in application's directory (template)
            string templatePath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, FILENAME);
            if (File.Exists(templatePath))
            {
                // Ensure directory in AppData exists
                Directory.CreateDirectory(Path.GetDirectoryName(SettingPath));
                // Copy the template to the AppData path
                File.Copy(templatePath, SettingPath);
                return Load(SettingPath);
            }

            // If no file exists anywhere, create a new default setting
            return new Setting();
        }

        public static Setting Load(string jsonPath)
        {
            Setting setting;

            if (File.Exists(jsonPath))
            {
                using (FileStream fileStream = File.Open(jsonPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    var options = new JsonSerializerOptions
                    {
                        WriteIndented = true
                    };
                    setting = JsonSerializer.Deserialize<Setting>(fileStream, options) ?? new Setting();
                }
            }
            else
                setting = new Setting();

            // Ensure Ollama config is present
            setting.ollamaConfig ??= new OllamaConfig();

            return setting;
        }

        public void Save()
        {
            try
            {
                // Ensure the directory exists before saving.
                string? directory = Path.GetDirectoryName(SettingPath);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }
                Save(SettingPath);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Failed to save settings: {ex.Message}");
                // Do not throw to avoid crashing the app
            }
        }

        public void Save(string jsonPath)
        {
            const int maxRetries = 3;
            const int retryDelayMs = 100;
            
            for (int attempt = 1; attempt <= maxRetries; attempt++)
            {
                try
                {
                    using (FileStream fileStream = File.Open(jsonPath, FileMode.Create, FileAccess.Write, FileShare.Read))
                    {
                        var options = new JsonSerializerOptions
                        {
                            WriteIndented = true
                        };
                        JsonSerializer.Serialize(fileStream, this, options);
                    }
                    return; // Success
                }
                catch (IOException ex) when (attempt < maxRetries)
                {
                    Console.WriteLine($"Failed to save settings to {jsonPath} (attempt {attempt}/{maxRetries}): {ex.Message}");
                    Thread.Sleep(retryDelayMs);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Failed to save settings to {jsonPath}: {ex.Message}");
                    return; // Non-IO exception, don't retry
                }
            }
            
            Console.WriteLine($"Failed to save settings to {jsonPath} after {maxRetries} attempts");
        }

        public void OnPropertyChanged([CallerMemberName] string propName = "")
        {
            try
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propName));
                
                // Debounce saving to avoid frequent writes
                lock (_saveLock)
                {
                    _saveTimer?.Dispose();
                    _saveTimer = new Timer((_) =>
                    {
                        try
                        {
                            Translator.Setting?.Save();
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"Delayed save failed: {ex.Message}");
                        }
                        finally
                        {
                            _saveTimer?.Dispose();
                            _saveTimer = null;
                        }
                    }, null, 1000, Timeout.Infinite); // 1 second delay
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"OnPropertyChanged error for {propName}: {ex.Message}");
            }
        }

        public static bool IsConfigExist()
        {
            string jsonPath = Path.Combine(Directory.GetCurrentDirectory(), FILENAME);
            Console.WriteLine($"Config file path: {jsonPath}");
            return File.Exists(jsonPath) || File.Exists(SettingPath);
        }
    }
}