using System.Runtime.InteropServices;

namespace LiveCaptionsTranslator.Services.Platform;

internal static class NativeMethods
{
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    public const int WM_HOTKEY = 0x0312;
    public const uint MOD_ALT = 0x0001;
    public const uint MOD_CONTROL = 0x0002;
    public const uint MOD_SHIFT = 0x0004;
    public const uint MOD_WIN = 0x0008;
    public const uint MOD_NOREPEAT = 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(nint hWnd, int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(nint hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(nint hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(nint hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(nint hWnd);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetPhysicallyInstalledSystemMemory(out long totalMemoryInKilobytes);

    /// <summary>Add or remove extended window styles on an HWND.</summary>
    public static void SetExtendedStyle(nint hwnd, int flag, bool enabled)
    {
        var style = GetWindowLong(hwnd, GWL_EXSTYLE);
        var updated = enabled ? style | flag : style & ~flag;
        if (updated != style)
        {
            SetWindowLong(hwnd, GWL_EXSTYLE, updated);
        }
    }
}
