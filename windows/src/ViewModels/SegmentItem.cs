using LCT.Core.Models;

namespace LiveCaptionsTranslator.ViewModels;

/// <summary>Bindable transcript line.</summary>
public sealed class SegmentItem : ObservableObject
{
    private string _translatedText = "";
    private TranslationState _state;
    private int _latencyMs;

    public Guid Id { get; }
    public AudioSource Source { get; }
    public string SourceLabel => Source.Label();
    public bool IsMicrophone => Source == AudioSource.Microphone;
    public DateTime Timestamp { get; }
    public string TimeText => Timestamp.ToString("HH:mm:ss");
    public string SourceText { get; }

    public string TranslatedText
    {
        get => _translatedText;
        set
        {
            if (Set(ref _translatedText, value))
            {
                OnPropertyChanged(nameof(HasTranslation));
                OnPropertyChanged(nameof(ShowStreamingHint));
            }
        }
    }

    public TranslationState State
    {
        get => _state;
        set
        {
            if (Set(ref _state, value))
            {
                OnPropertyChanged(nameof(IsTranslating));
                OnPropertyChanged(nameof(IsPending));
                OnPropertyChanged(nameof(IsFailed));
                OnPropertyChanged(nameof(ShowStreamingHint));
                OnPropertyChanged(nameof(HasTranslation));
            }
        }
    }

    public int LatencyMs
    {
        get => _latencyMs;
        set => Set(ref _latencyMs, value);
    }

    public bool IsTranslating => State == TranslationState.Translating;
    public bool IsPending => State == TranslationState.Pending;
    public bool IsFailed => State == TranslationState.Failed;
    public bool HasTranslation => TranslatedText.Length > 0 && State != TranslationState.Failed;
    public bool ShowStreamingHint => State == TranslationState.Translating && TranslatedText.Length == 0;

    public SegmentItem(Guid id, AudioSource source, string sourceText, DateTime timestamp, TranslationState state)
    {
        Id = id;
        Source = source;
        SourceText = sourceText;
        Timestamp = timestamp;
        _state = state;
    }
}
