using System.Management;
using System.Runtime.InteropServices;
using LCT.Core.Translation;
using Microsoft.Win32;
using Serilog;

namespace LiveCaptionsTranslator.Services.Platform;

/// <summary>Builds the HardwareProfile the model recommenders use, from WMI and the registry.</summary>
public static class HardwareInfo
{
    private static HardwareProfile? _cached;

    public static HardwareProfile Current => _cached ??= Probe();

    private static HardwareProfile Probe()
    {
        var cpuName = "Unknown CPU";
        var cores = Environment.ProcessorCount;
        var gpuVendor = GpuVendor.None;
        var gpuName = "";
        long vram = 0;

        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT Name FROM Win32_Processor");
            foreach (var item in searcher.Get())
            {
                cpuName = (item["Name"] as string)?.Trim() ?? cpuName;
                break;
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Hardware] CPU query failed");
        }

        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT Name, AdapterRAM, PNPDeviceID FROM Win32_VideoController");
            foreach (var item in searcher.Get())
            {
                var name = (item["Name"] as string)?.Trim() ?? "";
                var vendor = ClassifyGpu(name);
                var memory = ReadDedicatedMemory(item["PNPDeviceID"] as string) ?? Convert.ToInt64(item["AdapterRAM"] ?? 0L);
                // Prefer the most capable adapter when several are present (laptop iGPU + dGPU).
                if (Rank(vendor, memory) > Rank(gpuVendor, vram))
                {
                    gpuVendor = vendor;
                    gpuName = name;
                    vram = memory;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Warning(ex, "[Hardware] GPU query failed");
        }

        long ram = 0;
        try
        {
            if (NativeMethods.GetPhysicallyInstalledSystemMemory(out var kb))
            {
                ram = kb * 1024;
            }
        }
        catch (Exception)
        {
            // fall through
        }
        if (ram <= 0)
        {
            ram = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
        }

        var profile = new HardwareProfile(cpuName, cores, ram, gpuVendor, gpuName, vram, RuntimeInformation.OSArchitecture == Architecture.Arm64);
        Log.Information("[Hardware] {Summary}", profile.Summary);
        return profile;
    }

    private static int Rank(GpuVendor vendor, long memory) => vendor switch
    {
        GpuVendor.Nvidia => 3_000 + (int)(memory >> 30),
        GpuVendor.Amd => 2_000 + (int)(memory >> 30),
        GpuVendor.Intel => 1_000 + (int)(memory >> 30),
        GpuVendor.Other => 500,
        _ => 0,
    };

    private static GpuVendor ClassifyGpu(string name)
    {
        var n = name.ToLowerInvariant();
        if (n.Contains("nvidia") || n.Contains("geforce") || n.Contains("quadro") || n.Contains("rtx"))
        {
            return GpuVendor.Nvidia;
        }
        if (n.Contains("amd") || n.Contains("radeon"))
        {
            return GpuVendor.Amd;
        }
        if (n.Contains("intel") || n.Contains("arc") || n.Contains("iris") || n.Contains("uhd"))
        {
            return GpuVendor.Intel;
        }
        return string.IsNullOrEmpty(n) ? GpuVendor.None : GpuVendor.Other;
    }

    /// <summary>
    /// Win32_VideoController.AdapterRAM is a 32-bit field (caps at 4 GB). The
    /// display class registry key carries the real size as qwMemorySize.
    /// </summary>
    private static long? ReadDedicatedMemory(string? pnpDeviceId)
    {
        if (string.IsNullOrEmpty(pnpDeviceId))
        {
            return null;
        }
        try
        {
            using var classKey = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}");
            if (classKey == null)
            {
                return null;
            }
            foreach (var sub in classKey.GetSubKeyNames())
            {
                using var key = classKey.OpenSubKey(sub);
                var matching = key?.GetValue("MatchingDeviceId") as string;
                if (matching == null || !pnpDeviceId.StartsWith(matching, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                var value = key!.GetValue("HardwareInformation.qwMemorySize");
                if (value is long l)
                {
                    return l;
                }
                if (value is byte[] bytes && bytes.Length >= 8)
                {
                    return BitConverter.ToInt64(bytes, 0);
                }
            }
        }
        catch (Exception)
        {
            // Registry layout varies; AdapterRAM remains the fallback.
        }
        return null;
    }
}
