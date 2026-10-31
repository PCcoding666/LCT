using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LiveCaptionsTranslator.Controls;

/// <summary>OBS-style level meter for one capture lane.</summary>
public partial class LaneMeter : UserControl
{
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(nameof(Label), typeof(string), typeof(LaneMeter), new PropertyMetadata("SYS"));
    public static readonly DependencyProperty LevelProperty = DependencyProperty.Register(nameof(Level), typeof(float), typeof(LaneMeter), new PropertyMetadata(0f));
    public static readonly DependencyProperty IsActiveProperty = DependencyProperty.Register(nameof(IsActive), typeof(bool), typeof(LaneMeter), new PropertyMetadata(false, OnBrushInputChanged));
    public static readonly DependencyProperty TintProperty = DependencyProperty.Register(nameof(Tint), typeof(Brush), typeof(LaneMeter), new PropertyMetadata(Brushes.Cyan, OnBrushInputChanged));
    public static readonly DependencyProperty DeviceNameProperty = DependencyProperty.Register(nameof(DeviceName), typeof(string), typeof(LaneMeter), new PropertyMetadata(null));
    public static readonly DependencyProperty LabelBrushProperty = DependencyProperty.Register(nameof(LabelBrush), typeof(Brush), typeof(LaneMeter), new PropertyMetadata(Brushes.Gray));

    public LaneMeter()
    {
        InitializeComponent();
        UpdateLabelBrush();
    }

    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public float Level { get => (float)GetValue(LevelProperty); set => SetValue(LevelProperty, value); }
    public bool IsActive { get => (bool)GetValue(IsActiveProperty); set => SetValue(IsActiveProperty, value); }
    public Brush Tint { get => (Brush)GetValue(TintProperty); set => SetValue(TintProperty, value); }
    public string? DeviceName { get => (string?)GetValue(DeviceNameProperty); set => SetValue(DeviceNameProperty, value); }
    public Brush LabelBrush { get => (Brush)GetValue(LabelBrushProperty); private set => SetValue(LabelBrushProperty, value); }

    private static void OnBrushInputChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) => ((LaneMeter)d).UpdateLabelBrush();

    private void UpdateLabelBrush()
    {
        LabelBrush = IsActive ? Tint : (Brush?)TryFindResource("HudTextTertiary") ?? Brushes.Gray;
    }
}
