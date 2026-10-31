using System.ComponentModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Shapes;
using LiveCaptionsTranslator.ViewModels;

namespace LiveCaptionsTranslator.Views;

public partial class WelcomeWindow : Window
{
    public WelcomeWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is WelcomeViewModel vm)
            {
                vm.PropertyChanged += OnViewModelChanged;
                UpdateDots(vm.StepIndex);
            }
        };
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(WelcomeViewModel.StepIndex) && sender is WelcomeViewModel vm)
        {
            UpdateDots(vm.StepIndex);
        }
    }

    private void UpdateDots(int active)
    {
        var accent = (Brush)FindResource("HudAccent");
        var idle = (Brush)FindResource("HudHairlineStrong");
        var i = 0;
        foreach (var child in Dots.Children)
        {
            if (child is Ellipse dot)
            {
                dot.Fill = i <= active ? accent : idle;
            }
            i++;
        }
    }
}
