using System.Collections.ObjectModel;
using LCT.Core.History;
using LCT.Core.Models;

namespace LiveCaptionsTranslator.ViewModels;

public sealed class HistoryViewModel : ObservableObject
{
    private readonly TranscriptionViewModel _vm;
    private string _query = "";
    private string _status = "";
    private int _count;

    public ObservableCollection<TranslationEntry> Entries { get; } = new();
    public bool HistoryEnabled => _vm.Settings.HistoryEnabled;
    public string EnabledText => HistoryEnabled
        ? "History is on: finalized captions and translations are stored on this PC only."
        : "History is off (default). Enable it in Settings › History to keep transcripts between sessions.";

    public string Query { get => _query; set => Set(ref _query, value); }
    public string Status { get => _status; private set => Set(ref _status, value); }
    public int Count { get => _count; private set { if (Set(ref _count, value)) OnPropertyChanged(nameof(CountText)); } }
    public string CountText => $"{Count} entries stored";

    public AsyncRelayCommand RefreshCommand { get; }
    public AsyncRelayCommand SearchCommand { get; }
    public AsyncRelayCommand DeleteCommand { get; }
    public AsyncRelayCommand ClearCommand { get; }

    public HistoryViewModel(TranscriptionViewModel vm)
    {
        _vm = vm;
        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
        SearchCommand = new AsyncRelayCommand(RefreshAsync);
        DeleteCommand = new AsyncRelayCommand(p => DeleteAsync(p as TranslationEntry));
        ClearCommand = new AsyncRelayCommand(ClearAsync);
    }

    private HistoryStore? Store => _vm.HistoryStoreOrNull;

    public async Task RefreshAsync()
    {
        var store = Store;
        if (store == null)
        {
            Entries.Clear();
            Count = 0;
            Status = "No history database yet.";
            return;
        }
        var query = Query.Trim();
        try
        {
            var (entries, count) = await Task.Run(() => (query.Length == 0 ? store.LoadRecent(500) : store.Search(query), store.Count()));
            Entries.Clear();
            foreach (var e in entries) Entries.Add(e);
            Count = count;
            Status = query.Length == 0 ? "" : $"{entries.Count} match(es)";
        }
        catch (Exception ex)
        {
            Status = "Could not read history: " + ex.Message;
        }
    }

    private async Task DeleteAsync(TranslationEntry? entry)
    {
        var store = Store;
        if (entry == null || store == null) return;
        await Task.Run(() => store.Delete(entry.Id));
        Entries.Remove(entry);
        Count = Math.Max(0, Count - 1);
    }

    private async Task ClearAsync()
    {
        var store = Store;
        if (store == null) return;
        await Task.Run(store.Clear);
        Entries.Clear();
        Count = 0;
        Status = "History cleared.";
    }

    public string? ExportCsv() => Store?.ExportCsv();
}
