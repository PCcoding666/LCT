using System.Windows;
using LiveCaptionsTranslator.ViewModels;
using Microsoft.Win32;

namespace LiveCaptionsTranslator.Views;

public partial class SettingsWindow : Window
{
    private readonly SettingsViewModel _vm;

    public SettingsWindow(TranscriptionViewModel main)
    {
        _vm = new SettingsViewModel(main);
        DataContext = _vm;
        InitializeComponent();
        _vm.Saved += Close;
        Loaded += async (_, _) => await _vm.RefreshInstalledModelsAsync();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    private void EditPrompt_Click(object sender, RoutedEventArgs e)
    {
        var editor = new PromptEditorWindow(_vm.CustomPrompt) { Owner = this };
        if (editor.ShowDialog() == true)
        {
            _vm.CustomPrompt = editor.Prompt;
        }
    }

    private void ExportDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog { FileName = "LCT-diagnostics.txt", Filter = "Text (*.txt)|*.txt", DefaultExt = "txt", Title = "Export Diagnostics" };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }
        try
        {
            File.WriteAllText(dialog.FileName, _vm.BuildDiagnostics());
            _vm.ReportDiagnostics("Diagnostics saved. Attach this file when reporting issues.");
        }
        catch (Exception ex)
        {
            _vm.ReportDiagnostics("Export failed: " + ex.Message);
        }
    }
}
