using System.Threading.Channels;
using LCT.Core.Audio;
using LCT.Core.Models;
using LCT.Core.Session;
using LCT.Core.Speech;
using Serilog;
using Whisper.net;

namespace LiveCaptionsTranslator.Services.Speech;

/// <summary>
/// Runs whisper.cpp for one capture channel on a dedicated worker. Finals are
/// queued and never dropped; partials are coalesced so only the newest waits
/// while the decoder is busy. Results are raised on the worker thread.
/// </summary>
public sealed class WhisperRecognizer : IDisposable
{
    private static readonly Dictionary<string, WhisperFactory> Factories = new();
    private static readonly object FactoryGate = new();

    public AudioSource Source { get; }
    public SourceLanguage Language { get; }

    public event Action<RecognitionEvent>? Result;
    public event Action<AudioSource, Exception>? Failed;

    private readonly WhisperProcessor _processor;
    private readonly Channel<ChunkRequest> _finals = Channel.CreateUnbounded<ChunkRequest>(new UnboundedChannelOptions { SingleReader = true });
    private readonly SemaphoreSlim _wake = new(0);
    private readonly CancellationTokenSource _cts = new();
    private readonly Thread _worker;
    private ChunkRequest? _latestPartial;
    private readonly object _partialGate = new();
    private bool _disposed;

    public WhisperRecognizer(string modelPath, SourceLanguage language, AudioSource source, int threads = 0)
    {
        Source = source;
        Language = language;
        var factory = GetFactory(modelPath);
        var builder = factory.CreateBuilder()
            .WithLanguage(language.IsoCode())
            .WithThreads(threads > 0 ? threads : Math.Clamp(Environment.ProcessorCount / 2, 2, 8))
            .WithNoContext()
            .WithGreedySamplingStrategy();
        _processor = builder.Build();
        _worker = new Thread(Run) { IsBackground = true, Name = $"whisper-{source}" };
        _worker.Start();
    }

    private static WhisperFactory GetFactory(string modelPath)
    {
        lock (FactoryGate)
        {
            if (!Factories.TryGetValue(modelPath, out var factory))
            {
                Log.Information("[Whisper] Loading model {Path} (runtime: {Runtime})", modelPath, WhisperFactory.GetRuntimeInfo());
                factory = WhisperFactory.FromPath(modelPath);
                Factories[modelPath] = factory;
            }
            return factory;
        }
    }

    public void Submit(ChunkRequest request)
    {
        if (_disposed)
        {
            return;
        }
        if (request.IsFinal)
        {
            _finals.Writer.TryWrite(request);
            // A final supersedes any pending partial of the same utterance.
            lock (_partialGate)
            {
                if (_latestPartial?.UtteranceId == request.UtteranceId)
                {
                    _latestPartial = null;
                }
            }
        }
        else
        {
            lock (_partialGate)
            {
                _latestPartial = request;
            }
        }
        _wake.Release();
    }

    private void Run()
    {
        var token = _cts.Token;
        while (!token.IsCancellationRequested)
        {
            try
            {
                _wake.Wait(token);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            // Finals first, then the newest partial.
            if (_finals.Reader.TryRead(out var final))
            {
                Decode(final, token);
                continue;
            }
            ChunkRequest? partial;
            lock (_partialGate)
            {
                partial = _latestPartial;
                _latestPartial = null;
            }
            if (partial != null)
            {
                Decode(partial, token);
            }
        }
    }

    private void Decode(ChunkRequest request, CancellationToken token)
    {
        try
        {
            var started = DateTime.UtcNow;
            var text = DecodeAsync(request.Samples, token).GetAwaiter().GetResult();
            var cleaned = TextUtils.StripNonSpeechMarkers(text);
            Log.Debug("[Whisper] {Source} {Kind} {Seconds:F1}s audio in {Ms} ms: {Text}", Source, request.IsFinal ? "final" : "partial", request.Samples.Length / 16000.0, (DateTime.UtcNow - started).TotalMilliseconds, cleaned);
            if (!request.IsFinal && !TextUtils.HasSpeechContent(cleaned))
            {
                return;
            }
            Result?.Invoke(new RecognitionEvent(Source, request.UtteranceId, cleaned, request.IsFinal, DateTime.Now));
        }
        catch (OperationCanceledException)
        {
            // shutting down
        }
        catch (Exception ex)
        {
            Log.Error(ex, "[Whisper] {Source} decode failed", Source);
            Failed?.Invoke(Source, ex);
        }
    }

    private async Task<string> DecodeAsync(float[] samples, CancellationToken token)
    {
        var sb = new System.Text.StringBuilder();
        await foreach (var segment in _processor.ProcessAsync(samples, token).ConfigureAwait(false))
        {
            var text = segment.Text.Trim();
            if (text.Length == 0)
            {
                continue;
            }
            if (sb.Length > 0 && !TextUtils.IsCjk(text[0]))
            {
                sb.Append(' ');
            }
            sb.Append(text);
        }
        return sb.ToString();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _cts.Cancel();
        _finals.Writer.TryComplete();
        _wake.Release();
        if (!_worker.Join(TimeSpan.FromSeconds(5)))
        {
            Log.Warning("[Whisper] {Source} worker did not exit in time", Source);
        }
        _processor.Dispose();
        _cts.Dispose();
    }
}
