using LCT.Core.Translation;
using LiveCaptionsTranslator.ViewModels;
using Serilog;

namespace LiveCaptionsTranslator.Services.Ollama;

/// <summary>
/// Pulls translation models through the Ollama API with progress, cancel and a
/// disk-space check. Bindable: the settings page and the wizard show its state.
/// Must be created on the UI thread (it posts property changes there).
/// </summary>
public sealed class OllamaModelManager : ObservableObject
{
    private const long FreeSpaceBufferBytes = 2_000_000_000;

    private readonly OllamaClient _client;
    private readonly SynchronizationContext _ui;
    private CancellationTokenSource? _pullCts;
    private bool _isPulling;
    private double _progress;
    private long _completedBytes;
    private long _totalBytes;
    private string _status = "";
    private string? _currentModel;
    private string? _lastError;

    public OllamaModelManager(OllamaClient client)
    {
        _client = client;
        _ui = SynchronizationContext.Current ?? new SynchronizationContext();
    }

    public bool IsPulling { get => _isPulling; private set => Set(ref _isPulling, value); }
    public double Progress { get => _progress; private set => Set(ref _progress, value); }
    public long CompletedBytes { get => _completedBytes; private set => Set(ref _completedBytes, value); }
    public long TotalBytes { get => _totalBytes; private set => Set(ref _totalBytes, value); }
    public string Status { get => _status; private set => Set(ref _status, value); }
    public string? CurrentModel { get => _currentModel; private set => Set(ref _currentModel, value); }
    public string? LastError { get => _lastError; private set => Set(ref _lastError, value); }

    public string ProgressText => TotalBytes > 0
        ? $"{(int)(Progress * 100)}% · {ByteFormat.Format(CompletedBytes)} / {ByteFormat.Format(TotalBytes)}"
        : Status;

    /// <summary>Free space on the drive that holds the Ollama model store (the user profile drive, or OLLAMA_MODELS).</summary>
    public static long AvailableDiskSpaceBytes()
    {
        var root = Environment.GetEnvironmentVariable("OLLAMA_MODELS");
        if (string.IsNullOrEmpty(root) || !Directory.Exists(root))
        {
            root = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
        return new DriveInfo(Path.GetPathRoot(root) ?? "C:\\").AvailableFreeSpace;
    }

    public static string? DiskSpaceProblem(TranslationModelInfo model)
    {
        try
        {
            var available = AvailableDiskSpaceBytes();
            var required = model.DownloadBytes + FreeSpaceBufferBytes;
            return available >= required ? null : $"Insufficient disk space. Required: {ByteFormat.Format(required)}, available: {ByteFormat.Format(available)}";
        }
        catch (Exception)
        {
            return null; // unknown drive layout: let the pull decide
        }
    }

    /// <summary>Pull a model. Throws OperationCanceledException after CancelPull, OllamaPullException on failure.</summary>
    public async Task PullAsync(string modelName)
    {
        if (IsPulling)
        {
            throw new InvalidOperationException("Already pulling a model");
        }
        var entry = ModelCatalog.Entry(modelName);
        if (entry != null && DiskSpaceProblem(entry) is { } problem)
        {
            LastError = problem;
            throw new OllamaPullException(problem);
        }

        var cts = new CancellationTokenSource();
        _pullCts = cts;
        IsPulling = true;
        Progress = 0;
        CompletedBytes = 0;
        TotalBytes = 0;
        Status = "Starting download...";
        CurrentModel = modelName;
        LastError = null;
        OnPropertyChanged(nameof(ProgressText));

        var progress = new Progress<PullSnapshot>(s => _ui.Post(_ =>
        {
            Progress = s.OverallProgress;
            CompletedBytes = s.CompletedBytes;
            TotalBytes = s.TotalBytes;
            Status = s.Status;
            OnPropertyChanged(nameof(ProgressText));
        }, null));

        try
        {
            await _client.PullModelAsync(modelName, progress, cts.Token);
            Progress = 1.0;
            Status = "Download complete";
            Log.Information("[Ollama] Pulled {Model}", modelName);
        }
        catch (OperationCanceledException)
        {
            Status = "Cancelled";
            throw;
        }
        catch (Exception ex)
        {
            Status = "Download failed";
            LastError = ex.Message;
            Log.Warning(ex, "[Ollama] Pull of {Model} failed", modelName);
            throw;
        }
        finally
        {
            IsPulling = false;
            CurrentModel = null;
            _pullCts = null;
            OnPropertyChanged(nameof(ProgressText));
        }
    }

    public void CancelPull()
    {
        _pullCts?.Cancel();
    }
}
