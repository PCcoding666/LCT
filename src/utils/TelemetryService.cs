using LiveCaptionsTranslator.Models;
using Serilog;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace LiveCaptionsTranslator.Utils
{
    /// <summary>
    /// Telemetry and error reporting service
    /// </summary>
    public class TelemetryService
    {
        private static readonly Lazy<TelemetryService> _instance = new(() => new TelemetryService());
        public static TelemetryService Instance => _instance.Value;

        private readonly HttpClient _httpClient;
        private readonly string _telemetryEndpoint;
        private readonly string _sessionId;
        private bool _isEnabled;

        private TelemetryService()
        {
            _httpClient = new HttpClient();
            _httpClient.DefaultRequestHeaders.Add(\"User-Agent\", \"LiveCaptions-Translator-Telemetry\");
            _telemetryEndpoint = \"https://telemetry.livecaptions-translator.com/api/events\";
            _sessionId = Guid.NewGuid().ToString();
            _isEnabled = true; // Default enabled, can be configured
        }

        /// <summary>
        /// Initialize telemetry service
        /// </summary>
        public async Task InitializeAsync()
        {
            try
            {
                var config = VersionManager.Instance.GetConfig();
                _isEnabled = config.TelemetryEnabled;
                
                if (_isEnabled)
                {
                    await SendEventAsync(new TelemetryEvent
                    {
                        EventType = \"app_start\",
                        Version = AppVersionInfo.Current.FullVersion,
                        Properties = new Dictionary<string, object>
                        {
                            [\"os_version\"] = Environment.OSVersion.ToString(),
                            [\"dotnet_version\"] = Environment.Version.ToString(),
                            [\"is_64bit\"] = Environment.Is64BitOperatingSystem,
                            [\"session_id\"] = _sessionId
                        }
                    });
                }
                
                Log.Information(\"Telemetry service initialized (enabled: {Enabled})\", _isEnabled);
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to initialize telemetry service\");
            }
        }

        /// <summary>
        /// Report version usage statistics
        /// </summary>
        public async Task ReportVersionUsageAsync()
        {
            if (!_isEnabled) return;
            
            try
            {
                await SendEventAsync(new TelemetryEvent
                {
                    EventType = \"version_usage\",
                    Version = AppVersionInfo.Current.FullVersion,
                    Properties = new Dictionary<string, object>
                    {
                        [\"major_version\"] = AppVersionInfo.Current.Major,
                        [\"minor_version\"] = AppVersionInfo.Current.Minor,
                        [\"patch_version\"] = AppVersionInfo.Current.Patch,
                        [\"is_dev_build\"] = AppVersionInfo.Current.IsDevelopmentBuild,
                        [\"is_prerelease\"] = AppVersionInfo.IsPreRelease,
                        [\"session_id\"] = _sessionId
                    }
                });
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to report version usage\");
            }
        }

        /// <summary>
        /// Report update check event
        /// </summary>
        public async Task ReportUpdateCheckAsync(bool updateAvailable, string? latestVersion = null)
        {
            if (!_isEnabled) return;
            
            try
            {
                var properties = new Dictionary<string, object>
                {
                    [\"update_available\"] = updateAvailable,
                    [\"current_version\"] = AppVersionInfo.Current.FullVersion,
                    [\"session_id\"] = _sessionId
                };
                
                if (latestVersion != null)
                {
                    properties[\"latest_version\"] = latestVersion;
                }
                
                await SendEventAsync(new TelemetryEvent
                {
                    EventType = \"update_check\",
                    Version = AppVersionInfo.Current.FullVersion,
                    Properties = properties
                });
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to report update check\");
            }
        }

        /// <summary>
        /// Report error with context
        /// </summary>
        public async Task ReportErrorAsync(Exception exception, string? context = null)
        {
            try
            {
                var config = VersionManager.Instance.GetConfig();
                if (!config.ErrorReportingEnabled) return;
                
                await SendEventAsync(new TelemetryEvent
                {
                    EventType = \"error\",
                    Version = AppVersionInfo.Current.FullVersion,
                    Properties = new Dictionary<string, object>
                    {
                        [\"error_type\"] = exception.GetType().Name,
                        [\"error_message\"] = exception.Message,
                        [\"stack_trace\"] = exception.StackTrace ?? \"\",
                        [\"context\"] = context ?? \"unknown\",
                        [\"session_id\"] = _sessionId
                    }
                });
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to report error\");
            }
        }

        /// <summary>
        /// Report feature usage
        /// </summary>
        public async Task ReportFeatureUsageAsync(string featureName, Dictionary<string, object>? additionalProperties = null)
        {
            if (!_isEnabled) return;
            
            try
            {
                var properties = new Dictionary<string, object>
                {
                    [\"feature_name\"] = featureName,
                    [\"session_id\"] = _sessionId
                };
                
                if (additionalProperties != null)
                {
                    foreach (var prop in additionalProperties)
                    {
                        properties[prop.Key] = prop.Value;
                    }
                }
                
                await SendEventAsync(new TelemetryEvent
                {
                    EventType = \"feature_usage\",
                    Version = AppVersionInfo.Current.FullVersion,
                    Properties = properties
                });
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to report feature usage\");
            }
        }

        /// <summary>
        /// Enable or disable telemetry
        /// </summary>
        public async Task SetTelemetryEnabledAsync(bool enabled)
        {
            _isEnabled = enabled;
            
            try
            {
                var config = VersionManager.Instance.GetConfig();
                config.TelemetryEnabled = enabled;
                await VersionManager.Instance.UpdateConfigAsync(config);
                
                Log.Information(\"Telemetry {Status}\", enabled ? \"enabled\" : \"disabled\");
            }
            catch (Exception ex)
            {
                Log.Warning(ex, \"Failed to update telemetry setting\");
            }
        }

        /// <summary>
        /// Send telemetry event
        /// </summary>
        private async Task SendEventAsync(TelemetryEvent telemetryEvent)
        {
            if (!_isEnabled) return;
            
            try
            {
                telemetryEvent.Timestamp = DateTime.UtcNow;
                telemetryEvent.Properties[\"app_name\"] = \"LiveCaptions-Translator\";
                
                var json = JsonSerializer.Serialize(telemetryEvent, new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
                });
                
                var content = new StringContent(json, Encoding.UTF8, \"application/json\");
                
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var response = await _httpClient.PostAsync(_telemetryEndpoint, content, cts.Token);
                
                if (!response.IsSuccessStatusCode)
                {
                    Log.Debug(\"Telemetry event failed with status: {Status}\", response.StatusCode);
                }
            }
            catch (OperationCanceledException)
            {
                Log.Debug(\"Telemetry request timed out\");
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to send telemetry event\");
            }
        }

        /// <summary>
        /// Report application shutdown
        /// </summary>
        public async Task ReportShutdownAsync()
        {
            if (!_isEnabled) return;
            
            try
            {
                await SendEventAsync(new TelemetryEvent
                {
                    EventType = \"app_shutdown\",
                    Version = AppVersionInfo.Current.FullVersion,
                    Properties = new Dictionary<string, object>
                    {
                        [\"session_id\"] = _sessionId
                    }
                });
            }
            catch (Exception ex)
            {
                Log.Debug(ex, \"Failed to report shutdown\");
            }
        }

        public void Dispose()
        {
            _httpClient?.Dispose();
        }
    }

    /// <summary>
    /// Telemetry event model
    /// </summary>
    public class TelemetryEvent
    {
        public required string EventType { get; set; }
        public required string Version { get; set; }
        public DateTime Timestamp { get; set; }
        public Dictionary<string, object> Properties { get; set; } = new();
    }
}"