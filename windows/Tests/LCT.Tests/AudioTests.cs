using LCT.Core.Audio;
using Xunit;

namespace LCT.Tests;

public class AudioTests
{
    [Fact]
    public void testPcmConvert_Int16Stereo_MixesToMono()
    {
        var bytes = new byte[8];
        BitConverter.GetBytes((short)16384).CopyTo(bytes, 0);  // L 0.5
        BitConverter.GetBytes((short)-16384).CopyTo(bytes, 2); // R -0.5
        BitConverter.GetBytes((short)32767).CopyTo(bytes, 4);  // L ~1
        BitConverter.GetBytes((short)32767).CopyTo(bytes, 6);  // R ~1
        var mono = PcmConvert.ToMonoFloat(bytes, 16, 2, false);
        Assert.Equal(2, mono.Length);
        Assert.Equal(0f, mono[0], 3);
        Assert.Equal(1f, mono[1], 3);
    }

    [Fact]
    public void testPcmConvert_Float32_PassesThrough()
    {
        var bytes = new byte[8];
        BitConverter.GetBytes(0.25f).CopyTo(bytes, 0);
        BitConverter.GetBytes(-0.75f).CopyTo(bytes, 4);
        var mono = PcmConvert.ToMonoFloat(bytes, 32, 1, true);
        Assert.Equal(new[] { 0.25f, -0.75f }, mono);
    }

    [Fact]
    public void testPcmConvert_Int24_Decodes()
    {
        var bytes = new byte[] { 0x00, 0x00, 0x40, 0x00, 0x00, 0xC0 }; // +0.5, -0.5
        var mono = PcmConvert.ToMonoFloat(bytes, 24, 1, false);
        Assert.Equal(0.5f, mono[0], 3);
        Assert.Equal(-0.5f, mono[1], 3);
    }

    [Fact]
    public void testResampler_48kTo16k_PreservesToneAndLength()
    {
        var resampler = new Resampler(48000, 16000);
        var output = new List<float>();
        const double freq = 440;
        var phase = 0.0;
        for (var block = 0; block < 50; block++)
        {
            var input = new float[480];
            for (var i = 0; i < input.Length; i++)
            {
                input[i] = (float)Math.Sin(phase);
                phase += 2 * Math.PI * freq / 48000;
            }
            output.AddRange(resampler.Process(input));
        }
        // 50 blocks × 10 ms = 0.5 s → 8000 samples (±2 for filter/interp edges)
        Assert.InRange(output.Count, 7990, 8002);
        // Zero crossings of a 440 Hz tone in 0.5 s ≈ 440 (two per cycle × 220 cycles)
        var crossings = 0;
        for (var i = 200; i < output.Count; i++)
        {
            if (output[i - 1] < 0 && output[i] >= 0 || output[i - 1] >= 0 && output[i] < 0)
            {
                crossings++;
            }
        }
        Assert.InRange(crossings, 400, 460);
        // Amplitude survives the low-pass (440 Hz is far below the 7.2 kHz cutoff)
        Assert.InRange(output.Skip(200).Max(), 0.9, 1.05);
    }

    [Fact]
    public void testResampler_SameRate_IsIdentity()
    {
        var resampler = new Resampler(16000, 16000);
        var input = new float[] { 0.1f, 0.2f, 0.3f };
        Assert.Equal(input, resampler.Process(input));
    }

    [Fact]
    public void testResampler_44100To16k_RateIsCorrect()
    {
        var resampler = new Resampler(44100, 16000);
        var total = 0;
        for (var block = 0; block < 100; block++)
        {
            total += resampler.Process(new float[441]).Length;
        }
        Assert.InRange(total, 15990, 16002);
    }

    [Fact]
    public void testLevelMeter_Normalization()
    {
        Assert.Equal(0f, LevelMeter.Normalized(0));
        Assert.Equal(1f, LevelMeter.Normalized(1f), 3);
        Assert.Equal(0.5f, LevelMeter.Normalized(0.0316f), 2); // -30 dB
        Assert.Equal("-∞", LevelMeter.DbText(0));
        Assert.Equal("-30", LevelMeter.DbText(0.5f));
    }

    private static float[] Tone(int samples, float amplitude)
    {
        var frame = new float[samples];
        for (var i = 0; i < samples; i++)
        {
            frame[i] = amplitude * (float)Math.Sin(2 * Math.PI * 200 * i / 16000.0);
        }
        return frame;
    }

    [Fact]
    public void testEnergyVad_StartsAfterAttackAndEndsAfterHangover()
    {
        var vad = new EnergyVad(hangoverMs: 100, attackFrames: 2);
        var quiet = new float[vad.FrameSamples];
        var loud = Tone(vad.FrameSamples, 0.3f);

        Assert.Equal(VadEvent.None, vad.ProcessFrame(quiet));
        Assert.Equal(VadEvent.None, vad.ProcessFrame(loud));           // 1 loud frame: not yet
        Assert.Equal(VadEvent.SpeechStarted, vad.ProcessFrame(loud));  // 2nd: start
        Assert.True(vad.IsSpeech);
        for (var i = 0; i < 4; i++)
        {
            Assert.Equal(VadEvent.None, vad.ProcessFrame(quiet));      // 80 ms quiet: still speech
        }
        Assert.Equal(VadEvent.SpeechEnded, vad.ProcessFrame(quiet));   // 100 ms: end
        Assert.False(vad.IsSpeech);
    }

    [Fact]
    public void testEnergyVad_LoudFrameResetsHangover()
    {
        var vad = new EnergyVad(hangoverMs: 100, attackFrames: 1);
        var quiet = new float[vad.FrameSamples];
        var loud = Tone(vad.FrameSamples, 0.3f);
        Assert.Equal(VadEvent.SpeechStarted, vad.ProcessFrame(loud));
        for (var i = 0; i < 4; i++) vad.ProcessFrame(quiet);
        vad.ProcessFrame(loud);
        for (var i = 0; i < 4; i++) Assert.Equal(VadEvent.None, vad.ProcessFrame(quiet));
        Assert.Equal(VadEvent.SpeechEnded, vad.ProcessFrame(quiet));
    }

    [Fact]
    public void testEnergyVad_NoiseFloorAdaptsButThresholdHasMinimum()
    {
        var vad = new EnergyVad(minThreshold: 0.01f);
        var dither = Tone(vad.FrameSamples, 0.0005f);
        for (var i = 0; i < 100; i++)
        {
            Assert.Equal(VadEvent.None, vad.ProcessFrame(dither));
        }
        Assert.Equal(0.01f, vad.Threshold, 3);
    }

    [Fact]
    public void testEnergyVad_ConstantNoise_EventuallyReleasesAndStaysQuiet()
    {
        var vad = new EnergyVad(hangoverMs: 200);
        var noise = Tone(vad.FrameSamples, 0.04f); // steady hum above the 0.01 minimum
        var events = new List<VadEvent>();
        for (var i = 0; i < 3000; i++) // 60 s
        {
            var e = vad.ProcessFrame(noise);
            if (e != VadEvent.None) events.Add(e);
        }
        Assert.Equal(VadEvent.SpeechStarted, events[0]);
        Assert.Contains(VadEvent.SpeechEnded, events);
        Assert.False(vad.IsSpeech);
        Assert.True(vad.Threshold > 0.04f * 0.7f, "threshold adapted above the noise");
        // Real speech well above the hum still triggers
        var speech = Tone(vad.FrameSamples, 0.3f);
        vad.ProcessFrame(speech);
        Assert.Equal(VadEvent.SpeechStarted, vad.ProcessFrame(speech));
    }

    [Fact]
    public void testChunker_EmitsPartialsThenFinal()
    {
        var chunker = new UtteranceChunker(new EnergyVad(hangoverMs: 200), partialIntervalMs: 500, preRollMs: 100);
        var requests = new List<ChunkRequest>();
        // 1.3 s of speech
        requests.AddRange(chunker.Process(Tone(16000 * 13 / 10, 0.3f)));
        Assert.All(requests, r => Assert.False(r.IsFinal));
        Assert.InRange(requests.Count, 2, 3);
        Assert.True(requests.Select(r => r.UtteranceId).Distinct().Count() == 1);
        // 400 ms silence closes it
        var final = chunker.Process(new float[16000 * 4 / 10]);
        Assert.Single(final);
        Assert.True(final[0].IsFinal);
        Assert.Equal(requests[0].UtteranceId, final[0].UtteranceId);
        // Final includes pre-roll + speech + hangover ≈ 0.1 + 1.3 + 0.2 s
        Assert.InRange(final[0].Samples.Length, 16000 * 15 / 10, 16000 * 17 / 10);
    }

    [Fact]
    public void testChunker_SilenceOnly_EmitsNothing()
    {
        var chunker = new UtteranceChunker();
        Assert.Empty(chunker.Process(new float[16000 * 5]));
        Assert.Null(chunker.Flush());
    }

    [Fact]
    public void testChunker_ShortBlip_IsDropped()
    {
        var chunker = new UtteranceChunker(new EnergyVad(hangoverMs: 100, attackFrames: 1), minUtteranceMs: 600, preRollMs: 0);
        var requests = new List<ChunkRequest>();
        requests.AddRange(chunker.Process(Tone(16000 / 10, 0.3f)));   // 100 ms blip
        requests.AddRange(chunker.Process(new float[16000 / 2]));
        Assert.Empty(requests);
    }

    [Fact]
    public void testChunker_MaxUtterance_CutsAndContinues()
    {
        var chunker = new UtteranceChunker(new EnergyVad(hangoverMs: 200), partialIntervalMs: 100000, maxUtteranceMs: 2000, preRollMs: 0);
        var requests = chunker.Process(Tone(16000 * 5, 0.3f)).ToList();
        var finals = requests.Where(r => r.IsFinal).ToList();
        Assert.InRange(finals.Count, 2, 3);
        Assert.Equal(finals.Count, finals.Select(f => f.UtteranceId).Distinct().Count());
        Assert.True(chunker.IsSpeaking);
        var flushed = chunker.Flush();
        Assert.NotNull(flushed);
        Assert.True(flushed!.IsFinal);
    }

    [Fact]
    public void testChunker_PartialWindow_IsCapped()
    {
        var chunker = new UtteranceChunker(new EnergyVad(), partialIntervalMs: 1000, partialWindowMs: 1500, maxUtteranceMs: 60000, preRollMs: 0);
        var requests = chunker.Process(Tone(16000 * 4, 0.3f)).ToList();
        Assert.True(requests.Count >= 3);
        Assert.All(requests, r => Assert.True(r.Samples.Length <= 16000 * 15 / 10));
    }
}
