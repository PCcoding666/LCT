namespace LCT.Core.Audio;

/// <summary>One decode request for the recognizer.</summary>
public sealed record ChunkRequest(Guid UtteranceId, float[] Samples, bool IsFinal, TimeSpan UtteranceStart);

/// <summary>
/// Turns a continuous 16 kHz mono stream into Whisper decode requests. Keeps
/// the audio of the current utterance (plus a short pre-roll so the first
/// consonant is not lost); while speech continues it emits a partial request
/// every <c>partialInterval</c>; when the VAD closes the utterance, or it grows
/// past <c>maxUtterance</c>, it emits a final request and starts over. Partials
/// are capped to the most recent <c>partialWindow</c> of audio to bound decode
/// time. Pure logic; the caller supplies the clock.
/// </summary>
public sealed class UtteranceChunker
{
    private readonly EnergyVad _vad;
    private readonly int _sampleRate;
    private readonly int _preRollSamples;
    private readonly int _partialIntervalSamples;
    private readonly int _partialWindowSamples;
    private readonly int _maxUtteranceSamples;
    private readonly int _minUtteranceSamples;

    private readonly float[] _preRoll;
    private int _preRollWritten;
    private readonly List<float> _utterance = new();
    private readonly float[] _frame;
    private int _frameFill;
    private long _streamSamples;
    private long _utteranceStartSample;
    private int _samplesSinceLastPartial;
    private Guid _utteranceId;
    private bool _inUtterance;
    private bool _hadSpeechInUtterance;

    public UtteranceChunker(
        EnergyVad? vad = null,
        int sampleRate = 16000,
        int preRollMs = 300,
        int partialIntervalMs = 1200,
        int partialWindowMs = 20000,
        int maxUtteranceMs = 25000,
        int minUtteranceMs = 300)
    {
        _vad = vad ?? new EnergyVad(sampleRate);
        _sampleRate = sampleRate;
        _preRollSamples = sampleRate * preRollMs / 1000;
        _partialIntervalSamples = sampleRate * partialIntervalMs / 1000;
        _partialWindowSamples = sampleRate * partialWindowMs / 1000;
        _maxUtteranceSamples = sampleRate * maxUtteranceMs / 1000;
        _minUtteranceSamples = sampleRate * minUtteranceMs / 1000;
        _preRoll = new float[_preRollSamples];
        _frame = new float[_vad.FrameSamples];
    }

    public bool IsSpeaking => _vad.IsSpeech;

    /// <summary>Feed samples of any length; returns zero or more decode requests.</summary>
    public IReadOnlyList<ChunkRequest> Process(ReadOnlySpan<float> samples)
    {
        var requests = new List<ChunkRequest>();
        foreach (var sample in samples)
        {
            _frame[_frameFill++] = sample;
            if (_frameFill < _frame.Length)
            {
                continue;
            }
            _frameFill = 0;
            ProcessFrame(requests);
        }
        return requests;
    }

    /// <summary>Stop: finalize whatever is in flight (e.g. the user hit stop mid-sentence).</summary>
    public ChunkRequest? Flush()
    {
        ChunkRequest? request = null;
        if (_inUtterance && _hadSpeechInUtterance && _utterance.Count >= _minUtteranceSamples)
        {
            request = new ChunkRequest(_utteranceId, _utterance.ToArray(), true, StartOffset());
        }
        ResetUtterance();
        _vad.Reset();
        return request;
    }

    public void Reset()
    {
        ResetUtterance();
        _vad.Reset();
        _preRollWritten = 0;
        _frameFill = 0;
        _streamSamples = 0;
    }

    private void ProcessFrame(List<ChunkRequest> requests)
    {
        var vadEvent = _vad.ProcessFrame(_frame);
        _streamSamples += _frame.Length;

        if (!_inUtterance)
        {
            PushPreRoll(_frame);
            if (vadEvent != VadEvent.SpeechStarted)
            {
                return;
            }
            // Speech began: the pre-roll already contains this frame.
            _inUtterance = true;
            _hadSpeechInUtterance = true;
            _utteranceId = Guid.NewGuid();
            _utteranceStartSample = _streamSamples - Math.Min(_preRollWritten, _preRollSamples);
            _utterance.Clear();
            _utterance.AddRange(PreRollSnapshot());
            _samplesSinceLastPartial = 0;
            return;
        }

        _utterance.AddRange(_frame);
        _samplesSinceLastPartial += _frame.Length;

        if (vadEvent == VadEvent.SpeechEnded)
        {
            EmitFinal(requests);
            return;
        }

        if (_utterance.Count >= _maxUtteranceSamples)
        {
            // Very long utterance: cut here and keep listening (VAD still in speech).
            EmitFinal(requests, keepSpeaking: true);
            return;
        }

        if (_samplesSinceLastPartial >= _partialIntervalSamples)
        {
            _samplesSinceLastPartial = 0;
            var window = _utterance.Count > _partialWindowSamples
                ? _utterance.GetRange(_utterance.Count - _partialWindowSamples, _partialWindowSamples).ToArray()
                : _utterance.ToArray();
            requests.Add(new ChunkRequest(_utteranceId, window, false, StartOffset()));
        }
    }

    private void EmitFinal(List<ChunkRequest> requests, bool keepSpeaking = false)
    {
        if (_utterance.Count >= _minUtteranceSamples)
        {
            requests.Add(new ChunkRequest(_utteranceId, _utterance.ToArray(), true, StartOffset()));
        }
        ResetUtterance();
        if (keepSpeaking)
        {
            // Continue straight into a new utterance; no pre-roll needed, speech is ongoing.
            _inUtterance = true;
            _hadSpeechInUtterance = true;
            _utteranceId = Guid.NewGuid();
            _utteranceStartSample = _streamSamples;
        }
    }

    private void ResetUtterance()
    {
        _inUtterance = false;
        _hadSpeechInUtterance = false;
        _utterance.Clear();
        _samplesSinceLastPartial = 0;
    }

    private TimeSpan StartOffset() => TimeSpan.FromSeconds((double)_utteranceStartSample / _sampleRate);

    private void PushPreRoll(ReadOnlySpan<float> frame)
    {
        if (_preRollSamples == 0)
        {
            return;
        }
        foreach (var s in frame)
        {
            _preRoll[_preRollWritten % _preRollSamples] = s;
            _preRollWritten++;
        }
    }

    private float[] PreRollSnapshot()
    {
        var count = Math.Min(_preRollWritten, _preRollSamples);
        var result = new float[count];
        var start = _preRollWritten - count;
        for (var i = 0; i < count; i++)
        {
            result[i] = _preRoll[(start + i) % _preRollSamples];
        }
        return result;
    }
}
