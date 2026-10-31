namespace LCT.Core.Audio;

public enum VadEvent
{
    None,
    SpeechStarted,
    SpeechEnded,
}

/// <summary>
/// RMS-energy voice activity detector with hysteresis. Works on fixed frames
/// (20 ms at 16 kHz). Speech starts after <c>attackFrames</c> consecutive loud
/// frames and ends after <c>hangoverMs</c> of quiet. The threshold adapts to
/// the noise floor measured during silence, with an absolute minimum so a
/// perfectly quiet loopback does not trigger on dither.
/// </summary>
public sealed class EnergyVad
{
    public int FrameSamples { get; }
    public bool IsSpeech { get; private set; }
    public float NoiseFloor { get; private set; }
    public float Threshold => Math.Max(_minThreshold, NoiseFloor * _snrRatio);

    private readonly int _attackFrames;
    private readonly int _hangoverFrames;
    private readonly float _minThreshold;
    private readonly float _snrRatio;
    private int _loudRun;
    private int _quietRun;

    public EnergyVad(
        int sampleRate = 16000,
        int frameMs = 20,
        float minThreshold = 0.01f,
        float snrRatio = 3.0f,
        int attackFrames = 2,
        int hangoverMs = 600,
        float initialNoiseFloor = 0.002f)
    {
        FrameSamples = sampleRate * frameMs / 1000;
        _attackFrames = Math.Max(1, attackFrames);
        _hangoverFrames = Math.Max(1, hangoverMs / frameMs);
        _minThreshold = minThreshold;
        _snrRatio = snrRatio;
        NoiseFloor = initialNoiseFloor;
    }

    /// <summary>Feed exactly one frame. Returns the transition that happened, if any.</summary>
    public VadEvent ProcessFrame(ReadOnlySpan<float> frame)
    {
        var rms = LevelMeter.Rms(frame);
        var loud = rms >= Threshold;

        if (!IsSpeech)
        {
            // Track the noise floor only while quiet, slowly, so speech never lifts it.
            if (!loud)
            {
                NoiseFloor = NoiseFloor * 0.95f + rms * 0.05f;
            }
            _loudRun = loud ? _loudRun + 1 : 0;
            if (_loudRun >= _attackFrames)
            {
                IsSpeech = true;
                _loudRun = 0;
                _quietRun = 0;
                return VadEvent.SpeechStarted;
            }
            return VadEvent.None;
        }

        _quietRun = loud ? 0 : _quietRun + 1;
        if (_quietRun >= _hangoverFrames)
        {
            IsSpeech = false;
            _quietRun = 0;
            return VadEvent.SpeechEnded;
        }
        return VadEvent.None;
    }

    public void Reset()
    {
        IsSpeech = false;
        _loudRun = 0;
        _quietRun = 0;
    }
}
