using LCT.Core.Audio;
using LCT.Core.Models;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Serilog;

namespace LiveCaptionsTranslator.Services.Audio;

/// <summary>
/// One capture lane: WASAPI loopback for system audio or WASAPI capture for the
/// microphone, converted to 16 kHz mono floats. Raises Frames on the capture
/// thread; the consumer marshals as needed.
/// </summary>
public sealed class WasapiChannel : IDisposable
{
    public const int TargetSampleRate = 16000;
    /// <summary>KSDATAFORMAT_SUBTYPE_IEEE_FLOAT.</summary>
    private static readonly Guid IeeeFloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    public AudioSource Source { get; }
    public string? DeviceName { get; private set; }
    public bool IsRunning { get; private set; }

    /// <summary>16 kHz mono samples plus the RMS of the block (device-rate RMS, before resampling).</summary>
    public event Action<AudioSource, float[], float>? Frames;
    /// <summary>The device stopped on its own (unplugged, exclusive-mode conflict).</summary>
    public event Action<AudioSource, Exception?>? Stopped;

    private readonly string? _deviceId;
    private IWaveIn? _capture;
    private Resampler? _resampler;
    private int _bits;
    private int _channels;
    private bool _isFloat;
    private volatile bool _muted;

    public WasapiChannel(AudioSource source, string? deviceId = null)
    {
        Source = source;
        _deviceId = deviceId;
    }

    /// <summary>While muted, incoming data is dropped (pause). Capture keeps running so resume is instant.</summary>
    public bool Muted
    {
        get => _muted;
        set => _muted = value;
    }

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }
        using var enumerator = new MMDeviceEnumerator();
        if (Source == AudioSource.System)
        {
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            DeviceName = device.FriendlyName;
            _capture = new WasapiLoopbackCapture(device);
        }
        else
        {
            MMDevice device;
            if (!string.IsNullOrEmpty(_deviceId))
            {
                try
                {
                    device = enumerator.GetDevice(_deviceId);
                    if (device.State != DeviceState.Active)
                    {
                        throw new InvalidOperationException("device not active");
                    }
                }
                catch (Exception ex)
                {
                    Log.Warning(ex, "[Audio] Selected microphone {Id} unavailable; using the default input", _deviceId);
                    device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
                }
            }
            else
            {
                device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            }
            DeviceName = device.FriendlyName;
            _capture = new WasapiCapture(device, true, 20);
        }

        var format = _capture.WaveFormat;
        _bits = format.BitsPerSample;
        _channels = format.Channels;
        _isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubtype);
        _resampler = new Resampler(format.SampleRate, TargetSampleRate);
        Log.Information("[Audio] {Source} capture on '{Device}': {Rate} Hz, {Channels} ch, {Bits}-bit {Kind}", Source, DeviceName, format.SampleRate, _channels, _bits, _isFloat ? "float" : "pcm");

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        _capture.StartRecording();
        IsRunning = true;
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_muted || e.BytesRecorded == 0 || _resampler == null)
        {
            return;
        }
        try
        {
            var mono = PcmConvert.ToMonoFloat(e.Buffer.AsSpan(0, e.BytesRecorded), _bits, _channels, _isFloat);
            var rms = LevelMeter.Rms(mono);
            var resampled = _resampler.Process(mono);
            Frames?.Invoke(Source, resampled, rms);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "[Audio] {Source} conversion failed", Source);
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        var wasRunning = IsRunning;
        IsRunning = false;
        if (e.Exception != null)
        {
            Log.Warning(e.Exception, "[Audio] {Source} capture stopped with error", Source);
        }
        if (wasRunning)
        {
            Stopped?.Invoke(Source, e.Exception);
        }
    }

    public void Stop()
    {
        if (_capture == null)
        {
            return;
        }
        IsRunning = false;
        try
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.StopRecording();
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Audio] {Source} stop failed", Source);
        }
        finally
        {
            _capture.RecordingStopped -= OnRecordingStopped;
            _capture.Dispose();
            _capture = null;
        }
    }

    public void Dispose() => Stop();
}
