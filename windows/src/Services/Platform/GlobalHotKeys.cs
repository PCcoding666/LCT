using System.Windows.Input;
using System.Windows.Interop;
using Serilog;

namespace LiveCaptionsTranslator.Services.Platform;

public enum HotKeyAction
{
    ToggleCapture = 1,
    TogglePause = 2,
    ToggleOverlay = 3,
}

/// <summary>
/// System-wide hotkeys via RegisterHotKey on a message-only window, so they
/// work while the main window is hidden in the tray. Default chords mirror the
/// macOS app: Ctrl+Alt+S start/stop, Ctrl+Alt+P pause, Ctrl+Alt+O overlay.
/// </summary>
public sealed class GlobalHotKeys : IDisposable
{
    private readonly HwndSource _source;
    private readonly HashSet<int> _registered = new();

    public event Action<HotKeyAction>? Pressed;

    public static string Describe(HotKeyAction action) => action switch
    {
        HotKeyAction.ToggleCapture => "Ctrl+Alt+S",
        HotKeyAction.TogglePause => "Ctrl+Alt+P",
        HotKeyAction.ToggleOverlay => "Ctrl+Alt+O",
        _ => "",
    };

    public GlobalHotKeys()
    {
        var parameters = new HwndSourceParameters("LCT hotkeys")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0,
            ParentWindow = new nint(-3), // HWND_MESSAGE
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);
    }

    public void RegisterDefaults()
    {
        Register(HotKeyAction.ToggleCapture, Key.S);
        Register(HotKeyAction.TogglePause, Key.P);
        Register(HotKeyAction.ToggleOverlay, Key.O);
    }

    public void UnregisterAll()
    {
        foreach (var id in _registered)
        {
            NativeMethods.UnregisterHotKey(_source.Handle, id);
        }
        _registered.Clear();
    }

    private void Register(HotKeyAction action, Key key)
    {
        var id = (int)action;
        var vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        if (NativeMethods.RegisterHotKey(_source.Handle, id, NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT | NativeMethods.MOD_NOREPEAT, vk))
        {
            _registered.Add(id);
        }
        else
        {
            Log.Warning("[Hotkeys] Could not register {Action} ({Chord}) — chord may be taken", action, Describe(action));
        }
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_HOTKEY && Enum.IsDefined(typeof(HotKeyAction), (int)wParam))
        {
            Pressed?.Invoke((HotKeyAction)(int)wParam);
            handled = true;
        }
        return nint.Zero;
    }

    public void Dispose()
    {
        UnregisterAll();
        _source.RemoveHook(WndProc);
        _source.Dispose();
    }
}
