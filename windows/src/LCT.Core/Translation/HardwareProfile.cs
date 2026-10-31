namespace LCT.Core.Translation;

public enum GpuVendor
{
    None,
    Intel,
    Nvidia,
    Amd,
    Other,
}

/// <summary>
/// Snapshot of the PC used to pick models it can run. Built by the app from
/// WMI and the registry; a plain record here so the recommenders are testable.
/// </summary>
public sealed record HardwareProfile(
    string CpuName,
    int LogicalCores,
    long PhysicalMemoryBytes,
    GpuVendor GpuVendor,
    string GpuName,
    long DedicatedVideoMemoryBytes,
    bool IsArm64)
{
    public int MemoryGB => (int)Math.Round(PhysicalMemoryBytes / 1_073_741_824.0);
    public int VideoMemoryGB => (int)Math.Round(DedicatedVideoMemoryBytes / 1_073_741_824.0);

    /// <summary>A discrete GPU with 6 GB+ of its own memory runs 4B models comfortably.</summary>
    public bool HasCapableGpu => (GpuVendor is GpuVendor.Nvidia or GpuVendor.Amd) && DedicatedVideoMemoryBytes >= 6L * 1024 * 1024 * 1024;

    public bool HasIntelGpu => GpuVendor == GpuVendor.Intel;

    public string Summary => $"{CpuName}, {MemoryGB} GB RAM" + (GpuVendor == GpuVendor.None ? "" : $", {GpuName}");
}
