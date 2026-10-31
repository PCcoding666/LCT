using System.Net.Http;
using System.Diagnostics;
using LCT.Core.Translation;
using Serilog;

namespace LiveCaptionsTranslator.Services.Ollama;

public enum OllamaStatus
{
    NotInstalled,
    Installed,
    Running,
    Starting,
    Stopped,
    Error,
}

public static class OllamaStatusExtensions
{
    public static string DisplayText(this OllamaStatus status) => status switch
    {
        OllamaStatus.NotInstalled => "Not Installed",
        OllamaStatus.Installed => "Installed (Not Running)",
        OllamaStatus.Running => "Running",
        OllamaStatus.Starting => "Starting...",
        OllamaStatus.Stopped => "Stopped",
        OllamaStatus.Error => "Error",
        _ => status.ToString(),
    };
}

public enum OllamaInstallKind
{
    None,
    /// <summary>The user's own Ollama for Windows (installer or PATH).</summary>
    User,
    /// <summary>The IPEX-LLM portable build LCT downloaded for Intel GPUs.</summary>
    PortableIpex,
}

public sealed record OllamaInstallation(OllamaInstallKind Kind, string? ExecutablePath)
{
    public bool IsInstalled => Kind != OllamaInstallKind.None;
    public static readonly OllamaInstallation None = new(OllamaInstallKind.None, null);
}

/// <summary>
/// Finds, starts and (only when LCT started it) stops the local Ollama
/// service. A service that is already answering, or that the user started
/// themselves, is used as-is and never touched.
/// </summary>
public sealed class OllamaGuardian
{
    public static readonly Uri DownloadPage = new("https://ollama.com/download/windows");

    private readonly HttpClient _probe = new() { Timeout = TimeSpan.FromSeconds(3) };
    private readonly object _gate = new();
    private Task? _startupTask;
    private Process? _serveProcess;

    public OllamaEndpoint Endpoint { get; private set; } = OllamaEndpoint.Local;
    public OllamaStatus Status { get; private set; } = OllamaStatus.Stopped;
    public string? StatusDetail { get; private set; }
    public string? Version { get; private set; }
    public bool IsChecking { get; private set; }
    /// <summary>True only when LCT spawned the running ollama serve process.</summary>
    public bool LaunchedByLct => _serveProcess is { HasExited: false };

    public event Action? Changed;

    public void UseEndpoint(OllamaEndpoint endpoint)
    {
        Endpoint = endpoint;
    }

    // ---- Detection ----

    public static string PortableExecutable => Path.Combine(AppPaths.PortableOllamaDirectory, "ollama.exe");

    public OllamaInstallation DetectInstallation()
    {
        var candidates = new List<string>
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Ollama", "ollama.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Ollama", "ollama.exe"),
        };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(dir.Trim(), "ollama.exe"));
        }
        foreach (var path in candidates)
        {
            try
            {
                if (File.Exists(path))
                {
                    return new OllamaInstallation(OllamaInstallKind.User, path);
                }
            }
            catch (Exception)
            {
                // malformed PATH entry
            }
        }
        if (File.Exists(PortableExecutable))
        {
            return new OllamaInstallation(OllamaInstallKind.PortableIpex, PortableExecutable);
        }
        return OllamaInstallation.None;
    }

    public async Task<bool> IsServiceUpAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var response = await _probe.GetAsync(Endpoint.Api("api/tags"), cancellationToken).ConfigureAwait(false);
            return response.IsSuccessStatusCode;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private async Task<string?> FetchVersionAsync()
    {
        try
        {
            var json = await _probe.GetStringAsync(Endpoint.Api("api/version")).ConfigureAwait(false);
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            return doc.RootElement.TryGetProperty("version", out var v) ? v.GetString() : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Full status refresh: running service wins even if no executable is found.</summary>
    public async Task RefreshStatusAsync()
    {
        IsChecking = true;
        Changed?.Invoke();
        try
        {
            if (await IsServiceUpAsync().ConfigureAwait(false))
            {
                Version = await FetchVersionAsync().ConfigureAwait(false);
                SetStatus(OllamaStatus.Running);
            }
            else if (_startupTask is { IsCompleted: false })
            {
                SetStatus(OllamaStatus.Starting);
            }
            else
            {
                SetStatus(DetectInstallation().IsInstalled ? OllamaStatus.Installed : OllamaStatus.NotInstalled);
            }
        }
        finally
        {
            IsChecking = false;
            Changed?.Invoke();
        }
    }

    // ---- Start / stop ----

    /// <summary>Make sure a service answers, starting one if nothing does. Concurrent callers share one startup.</summary>
    public Task EnsureRunningAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_startupTask is { IsCompleted: false })
            {
                return _startupTask;
            }
            _startupTask = StartupAsync(cancellationToken);
            return _startupTask;
        }
    }

    private async Task StartupAsync(CancellationToken cancellationToken)
    {
        if (!Endpoint.IsLoopback)
        {
            // Remote servers are never started by LCT.
            if (await IsServiceUpAsync(cancellationToken).ConfigureAwait(false))
            {
                SetStatus(OllamaStatus.Running);
                return;
            }
            throw new OllamaGuardianException("Remote Ollama server is not reachable.");
        }
        if (await IsServiceUpAsync(cancellationToken).ConfigureAwait(false))
        {
            Version = await FetchVersionAsync().ConfigureAwait(false);
            SetStatus(OllamaStatus.Running);
            return;
        }

        var installation = DetectInstallation();
        if (!installation.IsInstalled)
        {
            SetStatus(OllamaStatus.NotInstalled);
            throw new OllamaGuardianException("Ollama is not installed. Install it from ollama.com/download or configure a remote Ollama server.");
        }

        SetStatus(OllamaStatus.Starting);
        Process process;
        try
        {
            process = LaunchServe(installation);
        }
        catch (Exception ex)
        {
            SetStatus(OllamaStatus.Error, ex.Message);
            throw new OllamaGuardianException("Failed to start Ollama: " + ex.Message, ex);
        }

        for (var attempt = 1; attempt <= 30; attempt++)
        {
            await Task.Delay(1000, cancellationToken).ConfigureAwait(false);
            if (await IsServiceUpAsync(cancellationToken).ConfigureAwait(false))
            {
                Version = await FetchVersionAsync().ConfigureAwait(false);
                if (process.HasExited)
                {
                    // Something else answered (port already taken) — not ours to manage.
                    Log.Information("[Ollama] Our serve exited but a service answers; leaving it alone");
                    ForgetProcess(process);
                }
                SetStatus(OllamaStatus.Running);
                Log.Information("[Ollama] Service ready after {Attempt}s (version {Version})", attempt, Version);
                return;
            }
            if (process.HasExited)
            {
                ForgetProcess(process);
                SetStatus(OllamaStatus.Error, "ollama serve exited during startup");
                throw new OllamaGuardianException($"ollama serve exited during startup (code {process.ExitCode}). See {AppPaths.OllamaServeLog}.");
            }
        }
        await TerminateAsync(process).ConfigureAwait(false);
        ForgetProcess(process);
        SetStatus(OllamaStatus.Error, "Startup timeout");
        throw new OllamaGuardianException("Ollama startup timed out.");
    }

    private Process LaunchServe(OllamaInstallation installation)
    {
        var exe = installation.ExecutablePath!;
        var startInfo = new ProcessStartInfo
        {
            FileName = exe,
            Arguments = "serve",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Path.GetDirectoryName(exe) ?? AppPaths.Root,
        };
        if (Endpoint.Port != 11434)
        {
            startInfo.Environment["OLLAMA_HOST"] = $"127.0.0.1:{Endpoint.Port}";
        }
        if (installation.Kind == OllamaInstallKind.PortableIpex)
        {
            // What the IPEX-LLM start-ollama.bat sets.
            startInfo.Environment["OLLAMA_NUM_GPU"] = "999";
            startInfo.Environment["ZES_ENABLE_SYSMAN"] = "1";
            startInfo.Environment["SYCL_CACHE_PERSISTENT"] = "1";
            startInfo.Environment["no_proxy"] = "localhost,127.0.0.1";
            startInfo.Environment["OLLAMA_MODELS"] = Path.Combine(AppPaths.ModelsDirectory, "ollama");
        }

        Directory.CreateDirectory(AppPaths.LogsDirectory);
        var log = new StreamWriter(new FileStream(AppPaths.OllamaServeLog, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) { AutoFlush = true };
        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (e.Data != null) { lock (log) log.WriteLine(e.Data); } };
        process.ErrorDataReceived += (_, e) => { if (e.Data != null) { lock (log) log.WriteLine(e.Data); } };
        process.Exited += (_, _) =>
        {
            Log.Information("[Ollama] ollama serve exited (code {Code})", process.HasExited ? process.ExitCode : -1);
            lock (log) log.Dispose();
            lock (_gate)
            {
                if (ReferenceEquals(_serveProcess, process))
                {
                    _serveProcess = null;
                    if (Status is OllamaStatus.Running or OllamaStatus.Starting)
                    {
                        SetStatus(OllamaStatus.Stopped);
                    }
                }
            }
        };
        Log.Information("[Ollama] Starting '{Exe} serve' ({Kind}); log: {Log}", exe, installation.Kind, AppPaths.OllamaServeLog);
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        lock (_gate)
        {
            _serveProcess = process;
        }
        return process;
    }

    private void ForgetProcess(Process process)
    {
        lock (_gate)
        {
            if (ReferenceEquals(_serveProcess, process))
            {
                _serveProcess = null;
            }
        }
    }

    /// <summary>Stop only the serve process LCT spawned. A user-started Ollama is left running.</summary>
    public async Task StopServiceAsync()
    {
        Process? process;
        lock (_gate)
        {
            process = _serveProcess;
            _serveProcess = null;
        }
        if (process == null || process.HasExited)
        {
            Log.Information("[Ollama] StopService: no LCT-started serve process — leaving Ollama running");
            return;
        }
        Log.Information("[Ollama] Stopping the ollama serve process started by LCT (pid {Pid})", process.Id);
        await TerminateAsync(process).ConfigureAwait(false);
        if (Status is OllamaStatus.Running or OllamaStatus.Starting)
        {
            SetStatus(OllamaStatus.Stopped);
        }
    }

    private static async Task TerminateAsync(Process process)
    {
        try
        {
            if (process.HasExited)
            {
                return;
            }
            // ollama serve spawns a runner child; take the tree so no orphan keeps the model in memory.
            process.Kill(entireProcessTree: true);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Ollama] Terminate failed");
        }
    }

    private void SetStatus(OllamaStatus status, string? detail = null)
    {
        Status = status;
        StatusDetail = detail;
        Changed?.Invoke();
    }
}

public sealed class OllamaGuardianException : Exception
{
    public OllamaGuardianException(string message, Exception? inner = null) : base(message, inner) { }
}
