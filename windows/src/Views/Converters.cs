using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using LCT.Core.Models;
using LiveCaptionsTranslator.ViewModels;

namespace LiveCaptionsTranslator.Views;

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var b = value is true;
        if (Invert) b = !b;
        return b ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => value is Visibility.Visible ^ Invert;
}

public sealed class InverseBoolConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is not true;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => value is not true;
}

public sealed class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value == null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class StringToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => string.IsNullOrEmpty(value as string) ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class SourceToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is AudioSource.Microphone ? Application.Current.Resources["HudOrange"] : Application.Current.Resources["HudCyan"];
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class SeverityToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        NoticeSeverity.Error => Application.Current.Resources["HudRed"],
        NoticeSeverity.Warning => Application.Current.Resources["HudOrange"],
        _ => Application.Current.Resources["HudAccent"],
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class SegmentBorderBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        TranslationState.Translating => Application.Current.Resources["HudAccent"],
        TranslationState.Pending => Application.Current.Resources["HudOrange"],
        TranslationState.Failed => Application.Current.Resources["HudRed"],
        _ => Application.Current.Resources["HudHairlineStrong"],
    };
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class CaptureStateToBrushConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        var state = values.Length > 0 && values[0] is CaptureState s ? s : CaptureState.Idle;
        var paused = values.Length > 1 && values[1] is true;
        return state switch
        {
            CaptureState.Idle => Application.Current.Resources["HudTextTertiary"],
            CaptureState.Stopping => Application.Current.Resources["HudOrange"],
            CaptureState.Capturing when paused => Application.Current.Resources["HudOrange"],
            _ => Application.Current.Resources["HudAccent"],
        };
    }
    public object[] ConvertBack(object value, Type[] targetTypes, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Meter fill width: level (0…1) × track width, or 0 when inactive.</summary>
public sealed class LevelToWidthConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        var level = values.Length > 0 && values[0] is float f ? f : 0f;
        var width = values.Length > 1 && values[1] is double d ? d : 0;
        var active = values.Length <= 2 || values[2] is true;
        return active ? Math.Max(0, Math.Min(level, 1)) * width : 0d;
    }
    public object[] ConvertBack(object value, Type[] targetTypes, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class LevelToDbConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => LCT.Core.Audio.LevelMeter.DbText(value is float f ? f : 0);
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class BoolToBrushConverter : IValueConverter
{
    public Brush? TrueBrush { get; set; }
    public Brush? FalseBrush { get; set; }
    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is true ? TrueBrush : FalseBrush;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Two-way: bound enum equals the ConverterParameter (string name). Used for radio groups.</summary>
public sealed class EnumEqualsConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value != null && parameter != null && string.Equals(value.ToString(), parameter.ToString(), StringComparison.Ordinal);
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true && parameter != null ? Enum.Parse(targetType, parameter.ToString()!) : Binding.DoNothing;
}

public sealed class PercentConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is double d ? $"{d * 100:0}%" : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Font size plus an offset (ConverterParameter), for the overlay's original line.</summary>
public sealed class FontSizeOffsetConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var size = value is double d ? d : 14;
        var offset = parameter != null && double.TryParse(parameter.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var o) ? o : 0;
        return Math.Max(8, size + offset);
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class BoolToOpacityConverter : IValueConverter
{
    public double TrueOpacity { get; set; } = 0.5;
    public double FalseOpacity { get; set; } = 1.0;
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is true ? TrueOpacity : FalseOpacity;
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class SourceToLabelConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value is AudioSource s ? s.Label() : "";
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Overlay background: near-black with the configured opacity.</summary>
public sealed class OpacityToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var opacity = value is double d ? Math.Clamp(d, 0.05, 1.0) : 0.85;
        return new SolidColorBrush(Color.FromArgb((byte)(opacity * 255), 0x14, 0x14, 0x16));
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
