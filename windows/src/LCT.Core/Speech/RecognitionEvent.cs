using LCT.Core.Models;

namespace LCT.Core.Speech;

/// <summary>One recognizer output: a draft (partial) or a finalized utterance.</summary>
public sealed record RecognitionEvent(
    AudioSource Source,
    Guid UtteranceId,
    string Text,
    bool IsFinal,
    DateTime Timestamp);
