using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace LiveCaptionsTranslator.models
{
    public class TranslateAPIConfig : INotifyPropertyChanged
    {
        /*
         * The key of this property is used as the content for `targetLangBox` in the `SettingPage`.
         * Its purpose is to standardize the language selection interface.
         */
        [JsonIgnore]
        public static Dictionary<string, string> SupportedLanguages => new()
        {
            { "zh-CN", "zh-CN" },
            { "zh-TW", "zh-TW" },
            { "en-US", "en-US" },
            { "en-GB", "en-GB" },
            { "ja-JP", "ja-JP" },
            { "ko-KR", "ko-KR" },
            { "fr-FR", "fr-FR" },
            { "th-TH", "th-TH" },
        };

        public event PropertyChangedEventHandler? PropertyChanged;

        public void OnPropertyChanged([CallerMemberName] string propName = "")
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propName));
            Translator.Setting?.Save();
        }
    }

    public class BaseLLMConfig : TranslateAPIConfig
    {
        public class Message
        {
            public string role { get; set; } = "";
            public string content { get; set; } = "";
        }

        private string modelName = "";
        private double temperature = 1.0;

        public string ModelName
        {
            get => modelName;
            set
            {
                modelName = value;
                OnPropertyChanged("ModelName");
            }
        }
        public double Temperature
        {
            get => temperature;
            set
            {
                temperature = value;
                OnPropertyChanged("Temperature");
            }
        }
    }

    public class OllamaConfig : BaseLLMConfig
    {
        [JsonIgnore]
        public static readonly Dictionary<string, string> RecommendedModels = new()
        {
            { "qwen2.5:0.5b", "Qwen2.5 0.5B (Lightest, Fastest)" },
            { "qwen2.5:1.5b", "Qwen2.5 1.5B (Light, Fast)" },
            { "qwen2.5:3b", "Qwen2.5 3B (Default, Balanced)" },
            { "qwen2.5:7b", "Qwen2.5 7B (High Quality, Slower)" },
            { "llama3.2:1b", "Llama 3.2 1B (Alternative Light Option)" },
            { "llama3.2:3b", "Llama 3.2 3B (Alternative Balanced Option)" }
        };
        [JsonIgnore]
        public new static Dictionary<string, string> SupportedLanguages => new()
        {
            { "zh-CN", "Chinese (Simplified)" },
            { "zh-TW", "Chinese (Traditional)" },
            { "en-US", "English" },
            { "en-GB", "English" },
            { "ja-JP", "Japanese" },
            { "ko-KR", "한국어" },
            { "fr-FR", "Français" },
            { "th-TH", "ไทย" },
        };

        public class Response
        {
            public string? model { get; set; }
            public DateTime created_at { get; set; }
            public Message? message { get; set; }
            public bool done { get; set; }
            public long total_duration { get; set; }
            public int load_duration { get; set; }
            public int prompt_eval_count { get; set; }
            public long prompt_eval_duration { get; set; }
            public int eval_count { get; set; }
            public long eval_duration { get; set; }
        }

        private int port = 11434;
        private string host = "127.0.0.1";
        private string modelName = "qwen2.5:3b";
        private int timeoutSeconds = 60; // Default 60 seconds timeout
        private string customDownloadUrl = ""; // 自定义下载地址

        public new string ModelName
        {
            get => modelName;
            set
            {
                modelName = value;
                OnPropertyChanged("ModelName");
            }
        }

        public int Port
        {
            get => port;
            set
            {
                port = value;
                OnPropertyChanged("Port");
            }
        }

        public string Host
        {
            get => host;
            set
            {
                host = value;
                OnPropertyChanged("Host");
            }
        }

        public int TimeoutSeconds
        {
            get => timeoutSeconds;
            set
            {
                timeoutSeconds = Math.Max(10, Math.Min(300, value)); // Limit to 10-300 seconds
                OnPropertyChanged("TimeoutSeconds");
            }
        }

        public string CustomDownloadUrl
        {
            get => customDownloadUrl;
            set
            {
                customDownloadUrl = value;
                OnPropertyChanged("CustomDownloadUrl");
            }
        }
    }
}