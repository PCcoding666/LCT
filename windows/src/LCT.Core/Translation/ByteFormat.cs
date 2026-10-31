using System.Globalization;

namespace LCT.Core.Translation;

/// <summary>Shared byte formatting for download sizes and progress ("3.97 GB").</summary>
public static class ByteFormat
{
    public static string Format(long bytes)
    {
        const double kb = 1024, mb = kb * 1024, gb = mb * 1024;
        if (bytes >= gb)
        {
            return (bytes / gb).ToString("0.##", CultureInfo.InvariantCulture) + " GB";
        }
        if (bytes >= mb)
        {
            return (bytes / mb).ToString("0.#", CultureInfo.InvariantCulture) + " MB";
        }
        if (bytes >= kb)
        {
            return (bytes / kb).ToString("0", CultureInfo.InvariantCulture) + " KB";
        }
        return bytes + " B";
    }
}
