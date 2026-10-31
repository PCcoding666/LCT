namespace LCT.Core.Models;

public enum TranslationState
{
    /// <summary>Finalized while paused; enqueued on resume.</summary>
    Pending,
    Translating,
    Translated,
    Failed,
}

/// <summary>A finalized transcript line and its translation lifecycle.</summary>
public sealed class TranslationSegment
{
    public Guid Id { get; }
    public DateTime Timestamp { get; }
    public AudioSource Source { get; }
    public string SourceText { get; }
    public string TranslatedText { get; set; } = "";
    public TranslationState State { get; set; }
    public int LatencyMs { get; set; }

    public TranslationSegment(AudioSource source, string sourceText, DateTime timestamp, TranslationState state = TranslationState.Translating, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Source = source;
        SourceText = sourceText;
        Timestamp = timestamp;
        State = state;
    }
}

/// <summary>A completed translation used as context for later requests and as the history record.</summary>
public sealed record TranslationEntry(
    Guid Id,
    string SourceText,
    string TranslatedText,
    string TargetLanguage,
    DateTime Timestamp,
    int LatencyMs,
    AudioSource Source = AudioSource.System);
