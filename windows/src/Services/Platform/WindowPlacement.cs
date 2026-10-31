using System.Globalization;
using System.Windows;

namespace LiveCaptionsTranslator.Services.Platform;

/// <summary>Persist and restore window bounds as "left,top,width,height" (DIPs), clamped to the virtual screen.</summary>
public static class WindowPlacement
{
    public static string Serialize(Window window)
    {
        var r = window.WindowState == WindowState.Normal
            ? new Rect(window.Left, window.Top, window.ActualWidth, window.ActualHeight)
            : window.RestoreBounds;
        return string.Join(",", new[] { r.Left, r.Top, r.Width, r.Height }.Select(v => Math.Round(v).ToString(CultureInfo.InvariantCulture)));
    }

    public static bool TryParse(string? value, out Rect rect)
    {
        rect = Rect.Empty;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }
        var parts = value.Split(',');
        if (parts.Length != 4)
        {
            return false;
        }
        var values = new double[4];
        for (var i = 0; i < 4; i++)
        {
            if (!double.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]))
            {
                return false;
            }
        }
        if (values[2] < 200 || values[3] < 120)
        {
            return false;
        }
        rect = new Rect(values[0], values[1], values[2], values[3]);
        return true;
    }

    /// <summary>Apply saved bounds; windows that would be off-screen come back onto the virtual desktop.</summary>
    public static void Apply(Window window, string? saved)
    {
        if (!TryParse(saved, out var rect))
        {
            return;
        }
        var screen = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        var width = Math.Min(rect.Width, screen.Width);
        var height = Math.Min(rect.Height, screen.Height);
        var left = Math.Clamp(rect.Left, screen.Left, Math.Max(screen.Left, screen.Right - width));
        var top = Math.Clamp(rect.Top, screen.Top, Math.Max(screen.Top, screen.Bottom - height));
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = left;
        window.Top = top;
        window.Width = width;
        window.Height = height;
    }
}
