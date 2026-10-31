using NAudio.CoreAudioApi;
using Serilog;

namespace LiveCaptionsTranslator.Services.Audio;

public sealed record AudioInputDevice(string Id, string Name, bool IsDefault)
{
    /// <summary>Virtual cables (VB-Cable, Voicemeeter, …) are silent unless something routes into them.</summary>
    public bool IsVirtual => Name.Contains("cable", StringComparison.OrdinalIgnoreCase)
        || Name.Contains("virtual", StringComparison.OrdinalIgnoreCase)
        || Name.Contains("voicemeeter", StringComparison.OrdinalIgnoreCase);
}

public static class AudioDevices
{
    public static IReadOnlyList<AudioInputDevice> ListInputDevices()
    {
        var result = new List<AudioInputDevice>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            string? defaultId = null;
            try
            {
                using var def = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
                defaultId = def.ID;
            }
            catch (Exception)
            {
                // No default input device.
            }
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                using (device)
                {
                    result.Add(new AudioInputDevice(device.ID, device.FriendlyName, device.ID == defaultId));
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Audio] Could not enumerate input devices");
        }
        return result.OrderByDescending(d => d.IsDefault).ThenBy(d => d.Name).ToList();
    }

    public static string? DefaultRenderDeviceName()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return device.FriendlyName;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
