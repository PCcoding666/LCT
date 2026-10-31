using System.Reflection;

namespace LiveCaptionsTranslator;

/// <summary>Version and build provenance, read from the attributes the csproj generates.</summary>
public static class AppInfo
{
    private static readonly Assembly Assembly = typeof(AppInfo).Assembly;

    /// <summary>"2.0.0-ci.57", "2.0.0-dev" or "2.0.0".</summary>
    public static string Version
    {
        get
        {
            var informational = Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";
            var plus = informational.IndexOf('+');
            return plus > 0 ? informational[..plus] : informational;
        }
    }

    public static string? CommitHash => Metadata("GitCommitHash");
    public static string? BuildTimestamp => Metadata("BuildTimestamp");
    public static string ProductName => Assembly.GetCustomAttribute<AssemblyProductAttribute>()?.Product ?? "LCT";
    public static string Copyright => Assembly.GetCustomAttribute<AssemblyCopyrightAttribute>()?.Copyright ?? "";

    public static string BuildInfo
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrEmpty(CommitHash))
            {
                parts.Add("commit " + (CommitHash.Length > 7 ? CommitHash[..7] : CommitHash));
            }
            if (!string.IsNullOrEmpty(BuildTimestamp))
            {
                parts.Add("built " + BuildTimestamp);
            }
            return string.Join(" · ", parts);
        }
    }

    private static string? Metadata(string key)
        => Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == key)?.Value;
}
