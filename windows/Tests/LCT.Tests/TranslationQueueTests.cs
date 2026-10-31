using LCT.Core.Models;
using LCT.Core.Translation;
using Xunit;

namespace LCT.Tests;

internal sealed class FakeTranslator : ITranslator
{
    public Func<string, CancellationToken, Task<string>> Translate { get; set; } = (text, _) => Task.FromResult("T:" + text);
    public List<string> Requested { get; } = new();
    public int Calls => Requested.Count;

    public async Task<int> TranslateStreamingAsync(string text, IReadOnlyList<TranslationEntry> context, Action<string> onToken, CancellationToken cancellationToken)
    {
        lock (Requested) { Requested.Add(text); }
        var result = await Translate(text, cancellationToken);
        foreach (var token in result.Select(c => c.ToString()))
        {
            cancellationToken.ThrowIfCancellationRequested();
            onToken(token);
        }
        return 5;
    }
}

public class TranslationQueueTests
{
    private static async Task<T> WaitFor<T>(Func<T?> probe, int timeoutMs = 3000) where T : class
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            var value = probe();
            if (value != null) return value;
            await Task.Delay(10);
        }
        throw new TimeoutException("condition not met");
    }

    [Fact]
    public async Task testFinal_IsTranslatedAndStreamed()
    {
        var translator = new FakeTranslator();
        using var queue = new TranslationQueue(translator);
        var results = new List<TranslationQueueResult>();
        var streamed = new List<string>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        queue.StreamingUpdated += (_, text, _) => { lock (streamed) streamed.Add(text); };
        var id = Guid.NewGuid();
        queue.Enqueue(id, "hello", isFinal: true);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.Equal("T:hello", result.TranslatedText);
        Assert.True(result.Success);
        Assert.True(result.IsFinal);
        Assert.Equal(id, result.SegmentId);
        Assert.Equal("T:hello", streamed.Last());
        Assert.False(queue.IsProcessing);
    }

    [Fact]
    public async Task testDuplicateFinal_IsSkipped()
    {
        var translator = new FakeTranslator();
        using var queue = new TranslationQueue(translator);
        var count = 0;
        queue.TranslationCompleted += _ => Interlocked.Increment(ref count);
        queue.Enqueue(Guid.NewGuid(), "same", isFinal: true);
        await WaitFor(() => count == 1 ? "ok" : null);
        queue.Enqueue(Guid.NewGuid(), "same", isFinal: true);
        await Task.Delay(150);
        Assert.Equal(1, count);
        Assert.Single(translator.Requested);
    }

    [Fact]
    public async Task testDraft_IsDebounced_OnlyLastSurvives()
    {
        var translator = new FakeTranslator();
        using var queue = new TranslationQueue(translator, debounceInterval: TimeSpan.FromMilliseconds(80), shortTextMergeCharacterLimit: 0);
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        var id = Guid.NewGuid();
        queue.Enqueue(id, "the qui", isFinal: false);
        queue.Enqueue(id, "the quick br", isFinal: false);
        queue.Enqueue(id, "the quick brown", isFinal: false);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.Equal("the quick brown", result.OriginalText);
        Assert.False(result.IsFinal);
        await Task.Delay(100);
        Assert.Single(translator.Requested);
    }

    [Fact]
    public async Task testFinal_PreemptsRunningDraft()
    {
        var gate = new TaskCompletionSource();
        var translator = new FakeTranslator
        {
            Translate = async (text, ct) =>
            {
                if (text.StartsWith("draft"))
                {
                    await Task.Delay(5000, ct); // hangs until cancelled
                }
                return "T:" + text;
            },
        };
        using var queue = new TranslationQueue(translator, debounceInterval: TimeSpan.FromMilliseconds(10));
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        var id = Guid.NewGuid();
        queue.Enqueue(id, "draft text", isFinal: false);
        await WaitFor(() => queue.IsProcessing ? "ok" : null);
        queue.Enqueue(id, "final text", isFinal: true);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.Equal("final text", result.OriginalText);
        Assert.Single(results);
    }

    [Fact]
    public async Task testFailure_RetriesThenReportsError()
    {
        var attempts = 0;
        var translator = new FakeTranslator
        {
            Translate = (_, _) => { Interlocked.Increment(ref attempts); throw new InvalidOperationException("boom"); },
        };
        using var queue = new TranslationQueue(translator, maxRetries: 2, retryBaseDelay: TimeSpan.FromMilliseconds(5));
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        queue.Enqueue(Guid.NewGuid(), "x", isFinal: true);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.False(result.Success);
        Assert.StartsWith("[ERROR] boom", result.TranslatedText);
        Assert.Equal(3, attempts);
    }

    [Fact]
    public async Task testTransientFailure_SucceedsOnRetry()
    {
        var attempts = 0;
        var translator = new FakeTranslator
        {
            Translate = (text, _) => Interlocked.Increment(ref attempts) == 1 ? throw new InvalidOperationException("once") : Task.FromResult("ok"),
        };
        using var queue = new TranslationQueue(translator, maxRetries: 2, retryBaseDelay: TimeSpan.FromMilliseconds(5));
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        queue.Enqueue(Guid.NewGuid(), "x", isFinal: true);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.True(result.Success);
        Assert.Equal("ok", result.TranslatedText);
    }

    [Fact]
    public async Task testCancelAll_DropsPendingAndResetsDedup()
    {
        var translator = new FakeTranslator { Translate = async (t, ct) => { await Task.Delay(200, ct); return "T:" + t; } };
        using var queue = new TranslationQueue(translator);
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        queue.Enqueue(Guid.NewGuid(), "a", isFinal: true);
        queue.Enqueue(Guid.NewGuid(), "b", isFinal: true);
        await WaitFor(() => queue.IsProcessing ? "ok" : null);
        queue.CancelAll();
        Assert.Equal(0, queue.PendingCount);
        Assert.False(queue.IsProcessing);
        await Task.Delay(300);
        Assert.Empty(results);
        // Same text can be re-enqueued after cancel
        queue.Enqueue(Guid.NewGuid(), "a", isFinal: true);
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.Equal("a", result.OriginalText);
    }

    [Fact]
    public async Task testCancelSegment_RemovesOnlyThatSegment()
    {
        var translator = new FakeTranslator { Translate = async (t, ct) => { await Task.Delay(150, ct); return "T:" + t; } };
        using var queue = new TranslationQueue(translator);
        var results = new List<TranslationQueueResult>();
        queue.TranslationCompleted += r => { lock (results) results.Add(r); };
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        queue.Enqueue(first, "first", isFinal: true);
        queue.Enqueue(second, "second", isFinal: true);
        await WaitFor(() => queue.IsProcessing ? "ok" : null);
        queue.Cancel(new[] { first });
        var result = await WaitFor(() => { lock (results) return results.FirstOrDefault(); });
        Assert.Equal(second, result.SegmentId);
        await Task.Delay(100);
        Assert.Single(results);
    }

    [Fact]
    public async Task testPendingLimit_DropsLowestPriorityOldest()
    {
        var release = new TaskCompletionSource();
        var translator = new FakeTranslator { Translate = async (t, ct) => { await release.Task.WaitAsync(ct); return "T:" + t; } };
        using var queue = new TranslationQueue(translator, maxPendingTasks: 2);
        queue.Enqueue(Guid.NewGuid(), "running", isFinal: true);
        await WaitFor(() => queue.IsProcessing ? "ok" : null);
        queue.Enqueue(Guid.NewGuid(), "p1", priority: TranslationPriority.Low, isFinal: true);
        queue.Enqueue(Guid.NewGuid(), "p2", priority: TranslationPriority.Normal, isFinal: true);
        queue.Enqueue(Guid.NewGuid(), "p3", priority: TranslationPriority.High, isFinal: true);
        Assert.Equal(2, queue.PendingCount);
        Assert.Equal(1, queue.DroppedCount);
        release.SetResult();
    }
}
