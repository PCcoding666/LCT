using LCT.Core.Models;
using LCT.Core.Session;

namespace LCT.Core.Translation;

public enum TranslationPriority
{
    Low = 0,
    Normal = 1,
    High = 2,
}

public sealed class TranslationTask
{
    public Guid Id { get; } = Guid.NewGuid();
    public Guid SegmentId { get; }
    public string Text { get; }
    public IReadOnlyList<TranslationEntry> Context { get; }
    public TranslationPriority Priority { get; }
    public DateTime Timestamp { get; } = DateTime.UtcNow;
    /// <summary>Whether this is a final (non-draft) transcription.</summary>
    public bool IsFinal { get; }

    public TranslationTask(Guid segmentId, string text, IReadOnlyList<TranslationEntry> context, TranslationPriority priority, bool isFinal)
    {
        SegmentId = segmentId;
        Text = text;
        Context = context;
        Priority = priority;
        IsFinal = isFinal;
    }
}

public sealed record TranslationQueueResult(
    Guid TaskId,
    Guid SegmentId,
    string OriginalText,
    string TranslatedText,
    int LatencyMs,
    bool Success,
    bool IsFinal,
    Exception? Error);

/// <summary>
/// Translation queue with debouncing, streaming, preemption and task
/// management, ported from the macOS TranslationQueue. Thread-safe; callbacks
/// fire on a thread-pool thread, so UI callers marshal to their dispatcher.
/// </summary>
public sealed class TranslationQueue : IDisposable
{
    private readonly ITranslator _translator;
    private readonly TimeSpan _debounceInterval;
    private readonly int _maxRetries;
    private readonly int _maxPendingTasks;
    private readonly TimeSpan _maxTaskAge;
    private readonly int _shortTextMergeCharacterLimit;
    private readonly TimeSpan _shortTextMergeWindow;
    private readonly TimeSpan _retryBaseDelay;

    private readonly object _gate = new();
    private readonly List<TranslationTask> _pending = new();
    private TranslationTask? _currentTask;
    private CancellationTokenSource? _processingCts;
    private CancellationTokenSource? _debounceCts;
    private string _lastProcessedText = "";
    private ulong _generation;
    private bool _disposed;

    public bool IsProcessing { get; private set; }
    public int PendingCount { get { lock (_gate) { return _pending.Count; } } }
    public int DroppedCount { get; private set; }

    /// <summary>Fires when a task finishes (success or failure).</summary>
    public event Action<TranslationQueueResult>? TranslationCompleted;
    /// <summary>Fires on each token: (segmentId, accumulated text so far, isFinalTask).</summary>
    public event Action<Guid, string, bool>? StreamingUpdated;

    public TranslationQueue(
        ITranslator translator,
        TimeSpan? debounceInterval = null,
        int maxRetries = 2,
        int maxPendingTasks = 20,
        TimeSpan? maxTaskAge = null,
        int shortTextMergeCharacterLimit = 24,
        TimeSpan? shortTextMergeWindow = null,
        TimeSpan? retryBaseDelay = null)
    {
        _translator = translator;
        _debounceInterval = debounceInterval ?? TimeSpan.FromMilliseconds(300);
        _maxRetries = maxRetries;
        _maxPendingTasks = Math.Max(1, maxPendingTasks);
        _maxTaskAge = maxTaskAge ?? TimeSpan.FromSeconds(12);
        _shortTextMergeCharacterLimit = shortTextMergeCharacterLimit;
        _shortTextMergeWindow = shortTextMergeWindow ?? TimeSpan.FromMilliseconds(800);
        _retryBaseDelay = retryBaseDelay ?? TimeSpan.FromMilliseconds(500);
    }

    /// <summary>Drafts are debounced; finals go in immediately and preempt a running draft.</summary>
    public void Enqueue(Guid segmentId, string text, IReadOnlyList<TranslationEntry>? context = null, TranslationPriority priority = TranslationPriority.Normal, bool isFinal = true)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }
        var task = new TranslationTask(segmentId, trimmed, context ?? Array.Empty<TranslationEntry>(), priority, isFinal);

        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            if (isFinal && trimmed == _lastProcessedText)
            {
                return;
            }
            if (isFinal)
            {
                CancelPendingDebounceLocked();
                if (_currentTask is { IsFinal: false } && IsProcessing)
                {
                    // Preempt the running draft so the final text starts without waiting.
                    _processingCts?.Cancel();
                    _processingCts = null;
                    _currentTask = null;
                    IsProcessing = false;
                    _generation++;
                }
                EnqueueLocked(task);
                return;
            }

            CancelPendingDebounceLocked();
            var cts = new CancellationTokenSource();
            _debounceCts = cts;
            var token = cts.Token;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(_debounceInterval, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                lock (_gate)
                {
                    if (token.IsCancellationRequested || _disposed)
                    {
                        return;
                    }
                    if (ReferenceEquals(_debounceCts, cts))
                    {
                        _debounceCts = null;
                    }
                    EnqueueLocked(task);
                }
            });
        }
    }

    public void CancelAll()
    {
        lock (_gate)
        {
            CancelPendingDebounceLocked();
            _processingCts?.Cancel();
            _processingCts = null;
            _pending.Clear();
            _currentTask = null;
            IsProcessing = false;
            // Reset the dedup baseline: canceled work may be re-enqueued with the same text later.
            _lastProcessedText = "";
            _generation++;
        }
    }

    /// <summary>Cancel queued or in-flight work for specific segments (rollback, pause).</summary>
    public void Cancel(IEnumerable<Guid> segmentIds)
    {
        var set = new HashSet<Guid>(segmentIds);
        if (set.Count == 0)
        {
            return;
        }
        lock (_gate)
        {
            _pending.RemoveAll(t => set.Contains(t.SegmentId));
            if (_currentTask != null && set.Contains(_currentTask.SegmentId))
            {
                _processingCts?.Cancel();
                _processingCts = null;
                _currentTask = null;
                IsProcessing = false;
                _generation++;
            }
            ProcessNextLocked();
        }
    }

    public void CancelPendingDebounce()
    {
        lock (_gate)
        {
            CancelPendingDebounceLocked();
        }
    }

    private void CancelPendingDebounceLocked()
    {
        _debounceCts?.Cancel();
        _debounceCts = null;
    }

    private void EnqueueLocked(TranslationTask task)
    {
        PruneStaleLocked();
        var toQueue = CoalesceShortPendingLocked(task);
        _pending.RemoveAll(t => t.Text == toQueue.Text);
        _pending.Add(toQueue);
        _pending.Sort((a, b) => a.Priority != b.Priority ? b.Priority.CompareTo(a.Priority) : a.Timestamp.CompareTo(b.Timestamp));
        EnforcePendingLimitLocked();
        ProcessNextLocked();
    }

    private void ProcessNextLocked()
    {
        PruneStaleLocked();
        if (IsProcessing || _pending.Count == 0)
        {
            return;
        }
        var task = _pending[0];
        _pending.RemoveAt(0);
        _currentTask = task;
        IsProcessing = true;
        _generation++;
        var generation = _generation;
        var cts = new CancellationTokenSource();
        _processingCts = cts;
        _ = Task.Run(() => ProcessAsync(task, generation, cts));
    }

    private void PruneStaleLocked()
    {
        if (_maxTaskAge <= TimeSpan.Zero)
        {
            return;
        }
        var now = DateTime.UtcNow;
        var removed = _pending.RemoveAll(t => now - t.Timestamp > _maxTaskAge);
        DroppedCount += removed;
    }

    private void EnforcePendingLimitLocked()
    {
        while (_pending.Count > _maxPendingTasks)
        {
            var dropIndex = 0;
            for (var i = 1; i < _pending.Count; i++)
            {
                var a = _pending[i];
                var b = _pending[dropIndex];
                if (a.Priority < b.Priority || (a.Priority == b.Priority && a.Timestamp < b.Timestamp))
                {
                    dropIndex = i;
                }
            }
            _pending.RemoveAt(dropIndex);
            DroppedCount++;
        }
    }

    private TranslationTask CoalesceShortPendingLocked(TranslationTask task)
    {
        if (task.IsFinal || _shortTextMergeCharacterLimit <= 0 || task.Text.Length > _shortTextMergeCharacterLimit)
        {
            return task;
        }
        var now = DateTime.UtcNow;
        var existingIndex = _pending.FindLastIndex(t =>
            !t.IsFinal && t.SegmentId == task.SegmentId && t.Priority == task.Priority
            && t.Text.Length <= _shortTextMergeCharacterLimit && now - t.Timestamp <= _shortTextMergeWindow);
        if (existingIndex < 0)
        {
            return task;
        }
        var existing = _pending[existingIndex];
        _pending.RemoveAt(existingIndex);
        var merged = task.Text.StartsWith(existing.Text, StringComparison.Ordinal)
            ? task.Text
            : TextUtils.ConcatenateSentences(new[] { existing.Text, task.Text });
        return new TranslationTask(task.SegmentId, merged, task.Context.Count == 0 ? existing.Context : task.Context, task.Priority, false);
    }

    private async Task ProcessAsync(TranslationTask task, ulong generation, CancellationTokenSource cts)
    {
        var started = DateTime.UtcNow;
        var retry = 0;
        while (true)
        {
            var streamed = new System.Text.StringBuilder();
            try
            {
                var latency = await _translator.TranslateStreamingAsync(task.Text, task.Context, token =>
                {
                    lock (_gate)
                    {
                        if (_generation != generation)
                        {
                            return;
                        }
                        streamed.Append(token);
                    }
                    StreamingUpdated?.Invoke(task.SegmentId, streamed.ToString(), task.IsFinal);
                }, cts.Token).ConfigureAwait(false);

                lock (_gate)
                {
                    if (cts.IsCancellationRequested || _generation != generation)
                    {
                        return;
                    }
                    if (task.IsFinal)
                    {
                        _lastProcessedText = task.Text;
                    }
                }
                Complete(new TranslationQueueResult(task.Id, task.SegmentId, task.Text, streamed.ToString().Trim(), latency, true, task.IsFinal, null), generation);
                return;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                lock (_gate)
                {
                    if (cts.IsCancellationRequested || _generation != generation)
                    {
                        return;
                    }
                }
                if (retry < _maxRetries)
                {
                    var delay = _retryBaseDelay * Math.Pow(2, retry);
                    retry++;
                    try
                    {
                        await Task.Delay(delay, cts.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }
                    continue;
                }
                var latencyMs = (int)(DateTime.UtcNow - started).TotalMilliseconds;
                Complete(new TranslationQueueResult(task.Id, task.SegmentId, task.Text, "[ERROR] " + ex.Message, latencyMs, false, task.IsFinal, ex), generation);
                return;
            }
        }
    }

    private void Complete(TranslationQueueResult result, ulong generation)
    {
        lock (_gate)
        {
            if (_generation != generation)
            {
                return;
            }
            IsProcessing = false;
            _currentTask = null;
            _processingCts = null;
        }
        TranslationCompleted?.Invoke(result);
        lock (_gate)
        {
            ProcessNextLocked();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
        }
        CancelAll();
    }
}
