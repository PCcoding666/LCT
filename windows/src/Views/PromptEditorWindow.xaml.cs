using System.Windows;
using LCT.Core.Translation;

namespace LiveCaptionsTranslator.Views;

public partial class PromptEditorWindow : Window
{
    public string Prompt { get; private set; }

    public PromptEditorWindow(string prompt)
    {
        Prompt = prompt;
        InitializeComponent();
        Editor.Text = prompt;
    }

    private void Reset_Click(object sender, RoutedEventArgs e) => Editor.Text = "";
    private void Preview_Click(object sender, RoutedEventArgs e) => Editor.Text = PromptTemplate.Default;
    private void Cancel_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }
    private void Done_Click(object sender, RoutedEventArgs e)
    {
        Prompt = Editor.Text.Trim() == PromptTemplate.Default.Trim() ? "" : Editor.Text;
        DialogResult = true;
        Close();
    }
}
