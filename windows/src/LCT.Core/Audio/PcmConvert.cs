using System.Buffers.Binary;

namespace LCT.Core.Audio;

/// <summary>Converts interleaved PCM buffers from WASAPI into mono float samples in -1…1.</summary>
public static class PcmConvert
{
    /// <summary>
    /// Mix interleaved PCM down to mono floats. Supports 16/24/32-bit integer
    /// and 32-bit IEEE float, any channel count. Trailing partial frames are ignored.
    /// </summary>
    public static float[] ToMonoFloat(ReadOnlySpan<byte> buffer, int bitsPerSample, int channels, bool isFloat)
    {
        if (channels <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(channels));
        }
        var bytesPerSample = bitsPerSample / 8;
        if (bytesPerSample is not (2 or 3 or 4))
        {
            throw new ArgumentOutOfRangeException(nameof(bitsPerSample), "Only 16, 24 and 32-bit PCM are supported");
        }
        if (isFloat && bitsPerSample != 32)
        {
            throw new ArgumentOutOfRangeException(nameof(bitsPerSample), "Float PCM must be 32-bit");
        }

        var frameBytes = bytesPerSample * channels;
        var frames = buffer.Length / frameBytes;
        var output = new float[frames];
        var inverseChannels = 1f / channels;

        for (var frame = 0; frame < frames; frame++)
        {
            float sum = 0;
            var offset = frame * frameBytes;
            for (var channel = 0; channel < channels; channel++)
            {
                var sampleBytes = buffer.Slice(offset + channel * bytesPerSample, bytesPerSample);
                sum += ReadSample(sampleBytes, bytesPerSample, isFloat);
            }
            output[frame] = sum * inverseChannels;
        }
        return output;
    }

    private static float ReadSample(ReadOnlySpan<byte> bytes, int bytesPerSample, bool isFloat)
    {
        switch (bytesPerSample)
        {
            case 2:
                return BinaryPrimitives.ReadInt16LittleEndian(bytes) / 32768f;
            case 3:
            {
                var value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
                if ((value & 0x800000) != 0)
                {
                    value |= unchecked((int)0xFF000000);
                }
                return value / 8388608f;
            }
            default:
                return isFloat
                    ? BinaryPrimitives.ReadSingleLittleEndian(bytes)
                    : BinaryPrimitives.ReadInt32LittleEndian(bytes) / 2147483648f;
        }
    }
}
