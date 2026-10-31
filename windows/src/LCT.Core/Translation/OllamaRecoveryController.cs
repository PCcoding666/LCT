namespace LCT.Core.Translation;

/// <summary>
/// Pure decision logic for the capture-time Ollama patrol. The session feeds
/// it each probe's outcome and executes the returned step; the controller owns
/// only the restart bookkeeping (backoff, attempt cap, recovery transitions).
/// </summary>
public sealed class OllamaRecoveryController
{
    public enum ProbeOutcome
    {
        /// <summary>Service reachable and the translation model is in memory.</summary>
        Healthy,
        /// <summary>Service did not answer at all.</summary>
        ServiceUnreachable,
        /// <summary>Service answers but the model is not loaded.</summary>
        ModelNotLoaded,
    }

    public enum StepKind
    {
        ProbeAgain,
        RestartService,
        AnnounceRecovered,
        ReloadModel,
        GiveUp,
    }

    public readonly record struct Step(StepKind Kind, TimeSpan Delay = default, int Attempt = 0);

    public const int MaxRestartAttempts = 3;

    private readonly TimeSpan _baseBackoff;

    public int RestartAttempts { get; private set; }
    public bool IsRecovering { get; private set; }
    public bool GaveUp { get; private set; }

    public OllamaRecoveryController(TimeSpan? baseBackoff = null)
    {
        _baseBackoff = baseBackoff ?? TimeSpan.FromSeconds(10);
    }

    /// <summary>10s → 20s → 40s for attempts 1…3.</summary>
    public TimeSpan Backoff(int attempt) => _baseBackoff * Math.Pow(2, Math.Max(attempt - 1, 0));

    public Step Next(ProbeOutcome outcome)
    {
        switch (outcome)
        {
            case ProbeOutcome.ServiceUnreachable:
                if (GaveUp)
                {
                    return new Step(StepKind.ProbeAgain);
                }
                if (RestartAttempts >= MaxRestartAttempts)
                {
                    GaveUp = true;
                    return new Step(StepKind.GiveUp);
                }
                RestartAttempts++;
                IsRecovering = true;
                return new Step(StepKind.RestartService, Backoff(RestartAttempts), RestartAttempts);
            case ProbeOutcome.ModelNotLoaded:
                return new Step(StepKind.ReloadModel);
            default:
                var wasRecovering = IsRecovering || GaveUp;
                RestartAttempts = 0;
                IsRecovering = false;
                GaveUp = false;
                return new Step(wasRecovering ? StepKind.AnnounceRecovered : StepKind.ProbeAgain);
        }
    }
}
