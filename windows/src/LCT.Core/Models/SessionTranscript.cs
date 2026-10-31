namespace LCT.Core.Models;

/// <summary>
/// Untrimmed record of one capture session: every finalized caption from the
/// moment a start succeeds until the next one. Kept independently of the
/// on-screen cards (trimmed to MaxDisplayCards) and of the opt-in persistent
/// history, so an export always covers the whole session.
/// </summary>
public sealed class SessionTranscript
{
    public sealed class Entry
    {
        public Guid Id { get; init; }
        public AudioSource Source { get; init; }
        public string SourceText { get; init; } = "";
        public string TranslatedText { get; set; } = "";
        /// <summary>When the caption was finalized (session offsets derive from this).</summary>
        public DateTime FinalizedAt { get; init; }
    }

    private readonly List<Entry> _entries = new();

    /// <summary>When the current session began; null before the first start and after Clear.</summary>
    public DateTime? StartedAt { get; private set; }

    public IReadOnlyList<Entry> Entries => _entries;

    public void Begin(DateTime at)
    {
        StartedAt = at;
        _entries.Clear();
    }

    public void Append(Guid id, AudioSource source, string sourceText, DateTime finalizedAt)
        => _entries.Add(new Entry { Id = id, Source = source, SourceText = sourceText, FinalizedAt = finalizedAt });

    /// <summary>Record the completed translation. Only final results reach this.</summary>
    public void UpdateTranslation(Guid id, string text)
    {
        var entry = _entries.Find(e => e.Id == id);
        if (entry != null)
        {
            entry.TranslatedText = text;
        }
    }

    public void Remove(IEnumerable<Guid> ids)
    {
        var set = new HashSet<Guid>(ids);
        if (set.Count == 0)
        {
            return;
        }
        _entries.RemoveAll(e => set.Contains(e.Id));
    }

    public void Clear()
    {
        StartedAt = null;
        _entries.Clear();
    }
}
