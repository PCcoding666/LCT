namespace LCT.Core.Audio;

/// <summary>
/// Streaming sample-rate converter to 16 kHz for speech recognition. A
/// windowed-sinc low-pass filter at the input rate removes everything above
/// the new Nyquist frequency, then linear interpolation picks the output
/// samples. State carries across calls so frame boundaries do not click.
/// Quality is more than enough for ASR; this is not a mastering resampler.
/// </summary>
public sealed class Resampler
{
    public int InputRate { get; }
    public int OutputRate { get; }

    private readonly float[] _taps;
    private readonly float[] _history;   // last (taps-1) input samples, for filter continuity
    private readonly double _step;       // input samples per output sample
    private double _position;            // fractional read position into the filtered stream
    private float _previousFiltered;     // last filtered input sample from the previous call
    private bool _hasPrevious;

    public Resampler(int inputRate, int outputRate = 16000, int tapCount = 63)
    {
        if (inputRate <= 0 || outputRate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(inputRate));
        }
        InputRate = inputRate;
        OutputRate = outputRate;
        _step = (double)inputRate / outputRate;
        _taps = inputRate > outputRate ? DesignLowPass(tapCount, 0.45 * outputRate / inputRate) : Array.Empty<float>();
        _history = new float[Math.Max(0, _taps.Length - 1)];
    }

    /// <summary>Convert a block of input samples. Output length varies by ±1 between calls.</summary>
    public float[] Process(ReadOnlySpan<float> input)
    {
        if (InputRate == OutputRate)
        {
            return input.ToArray();
        }

        var filtered = _taps.Length > 0 ? LowPass(input) : input.ToArray();

        // Virtual stream: [previousFiltered, filtered...]. Position 0 is previousFiltered.
        var output = new List<float>((int)(filtered.Length / _step) + 2);
        var totalLength = filtered.Length + (_hasPrevious ? 1 : 0);
        var baseOffset = _hasPrevious ? 1 : 0;

        while (_position + 1 < totalLength)
        {
            var index = (int)Math.Floor(_position);
            var fraction = (float)(_position - index);
            var a = Sample(filtered, index - baseOffset);
            var b = Sample(filtered, index + 1 - baseOffset);
            output.Add(a + (b - a) * fraction);
            _position += _step;
        }

        if (filtered.Length > 0)
        {
            _previousFiltered = filtered[^1];
            _hasPrevious = true;
            // Rebase so position 0 is the new previousFiltered.
            _position -= totalLength - 1;
        }
        return output.ToArray();
    }

    private float Sample(float[] filtered, int index) => index < 0 ? _previousFiltered : filtered[index];

    private float[] LowPass(ReadOnlySpan<float> input)
    {
        var tapCount = _taps.Length;
        var historyLength = _history.Length;
        var output = new float[input.Length];
        // Work buffer: history followed by the new input.
        var work = new float[historyLength + input.Length];
        _history.CopyTo(work, 0);
        input.CopyTo(work.AsSpan(historyLength));

        for (var n = 0; n < input.Length; n++)
        {
            float acc = 0;
            var start = n; // work[n + historyLength] is the newest sample for output n
            for (var k = 0; k < tapCount; k++)
            {
                acc += _taps[k] * work[start + k];
            }
            output[n] = acc;
        }

        if (input.Length >= historyLength)
        {
            input[^historyLength..].CopyTo(_history);
        }
        else
        {
            var keep = historyLength - input.Length;
            Array.Copy(_history, input.Length, _history, 0, keep);
            input.CopyTo(_history.AsSpan(keep));
        }
        return output;
    }

    /// <summary>Hamming-windowed sinc, normalized to unity DC gain. cutoff is a fraction of the input rate.</summary>
    internal static float[] DesignLowPass(int tapCount, double cutoff)
    {
        if (tapCount % 2 == 0)
        {
            tapCount++;
        }
        var taps = new float[tapCount];
        var center = (tapCount - 1) / 2.0;
        double sum = 0;
        for (var i = 0; i < tapCount; i++)
        {
            var x = i - center;
            var sinc = x == 0 ? 2 * cutoff : Math.Sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
            var window = 0.54 - 0.46 * Math.Cos(2 * Math.PI * i / (tapCount - 1));
            taps[i] = (float)(sinc * window);
            sum += taps[i];
        }
        for (var i = 0; i < tapCount; i++)
        {
            taps[i] = (float)(taps[i] / sum);
        }
        return taps;
    }
}
