using LCT.Core.Models;

namespace LCT.Core.Session;

/// <summary>
/// Watchdog for a channel that hears audio but produces no recognition results
/// — typically a wrong recognition language. Fed with meter levels (0…1);
/// time between samples accumulates while the level is above the threshold.
/// Fires once per channel per session when the accumulated audible time
/// reaches the required duration without a result.
/// </summary>
public sealed class RecognitionStallDetector
{
    private sealed class Lane
    {
        public double AudibleSeconds;
        public DateTime? LastSampleAt;
        public bool HasFired;
    }

    public float LevelThreshold { get; }
    public TimeSpan RequiredAudibleDuration { get; }

    private readonly Dictionary<AudioSource, Lane> _lanes = new();

    public RecognitionStallDetector(float levelThreshold = 0.25f, TimeSpan? requiredAudibleDuration = null)
    {
        LevelThreshold = levelThreshold;
        RequiredAudibleDuration = requiredAudibleDuration ?? TimeSpan.FromSeconds(8);
    }

    public void Reset() => _lanes.Clear();

    public void ResetLane(AudioSource source) => _lanes.Remove(source);

    /// <summary>Returns true exactly once per lane per session.</summary>
    public bool Process(float level, AudioSource source, DateTime timestamp)
    {
        if (!_lanes.TryGetValue(source, out var lane))
        {
            lane = new Lane();
            _lanes[source] = lane;
        }
        if (lane.LastSampleAt.HasValue)
        {
            var interval = (timestamp - lane.LastSampleAt.Value).TotalSeconds;
            if (interval > 0 && level > LevelThreshold)
            {
                lane.AudibleSeconds += interval;
            }
        }
        lane.LastSampleAt = timestamp;
        if (lane.HasFired || lane.AudibleSeconds < RequiredAudibleDuration.TotalSeconds)
        {
            return false;
        }
        lane.HasFired = true;
        return true;
    }

    /// <summary>The lane produced a result; its accumulation starts over (a fired lane stays fired).</summary>
    public void RegisterResult(AudioSource source)
    {
        if (_lanes.TryGetValue(source, out var lane))
        {
            lane.AudibleSeconds = 0;
            lane.LastSampleAt = null;
        }
    }
}
