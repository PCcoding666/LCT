using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LCT.Core.Models;
using LiveCaptionsTranslator.ViewModels;
using Microsoft.Win32;

namespace LiveCaptionsTranslator.Views;

public partial class HistoryWindow : Window
{
    private readonly HistoryViewModel _vm;

    public HistoryWindow(TranscriptionViewModel main)
    {
        _vm = new HistoryViewModel(main);
        DataContext = _vm;
        InitializeComponent();
        Loaded += async (_, _) => await _vm.RefreshAsync();
    }

    private void Search_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            _vm.SearchCommand.Execute(null);
        }
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is TranslationEntry entry)
        {
            try { Clipboard.SetText(entry.SourceText + "\n" + entry.TranslatedText); } catch (Exception) { }
        }
    }

    private void ExportCsv_Click(object sender, RoutedEventArgs e)
    {
        var csv = _vm.ExportCsv();
        if (csv == null)
        {
            return;
        }
        var dialog = new SaveFileDialog { FileName = "LCT history.csv", Filter = "CSV (*.csv)|*.csv", DefaultExt = "csv" };
        if (dialog.ShowDialog(this) == true)
        {
            File.WriteAllText(dialog.FileName, csv, new System.Text.UTF8Encoding(true));
        }
    }

    private void ClearAll_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Delete every history entry? This cannot be undone.", "LCT", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes)
        {
            _vm.ClearCommand.Execute(null);
        }
    }
}
