namespace LCT.Core.Session;

public enum SilenceEvent
{
    None,
    SilenceDetected,
    AudioResumed,
}

/// <summary>
/// Silence watchdog for a capture channel: fires once per session when every
/// buffer's RMS stays below the threshold for the required duration. After
/// firing, a continuous audible streak of recoveryDuration reports AudioResumed once.
/// </summary>
public sealed class SilenceDetector
{
    public float RmsThreshold { get; }
    public TimeSpan RequiredDuration { get; }
    public TimeSpan RecoveryDuration { get; }

    private DateTime? _silenceStart;
    private bool _hasFired;
    private DateTime? _recoveryStart;
    private bool _hasReportedRecovery;

    public SilenceDetector(float rmsThreshold = 1e-4f, TimeSpan? requiredDuration = null, TimeSpan? recoveryDuration = null)
    {
        RmsThreshold = rmsThreshold;
        RequiredDuration = requiredDuration ?? TimeSpan.FromSeconds(6);
        RecoveryDuration = recoveryDuration ?? TimeSpan.FromSeconds(1);
    }

    public void Reset()
    {
        _silenceStart = null;
        _hasFired = false;
        _recoveryStart = null;
        _hasReportedRecovery = false;
    }

    public SilenceEvent Process(float rms, DateTime timestamp)
    {
        if (_hasFired)
        {
            if (_hasReportedRecovery)
            {
                return SilenceEvent.None;
            }
            if (rms < RmsThreshold)
            {
                _recoveryStart = null;
                return SilenceEvent.None;
            }
            _recoveryStart ??= timestamp;
            if (timestamp - _recoveryStart.Value < RecoveryDuration)
            {
                return SilenceEvent.None;
            }
            _hasReportedRecovery = true;
            return SilenceEvent.AudioResumed;
        }
        if (rms >= RmsThreshold)
        {
            _silenceStart = null;
            return SilenceEvent.None;
        }
        _silenceStart ??= timestamp;
        if (timestamp - _silenceStart.Value < RequiredDuration)
        {
            return SilenceEvent.None;
        }
        _hasFired = true;
        return SilenceEvent.SilenceDetected;
    }
}
