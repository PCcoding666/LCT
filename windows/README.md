# LCT (LiveCaptions Translator) for Windows

Real-time captions and translation, entirely on your PC. LCT listens to what
Windows plays and to your microphone, recognizes speech on-device with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp), and translates with a
local model through [Ollama](https://ollama.com). No cloud, no account, no
Windows Live Captions.

**Quick start:** download `LCT-vX.Y.Z-Setup.exe` from the
[latest release](https://github.com/PCcoding666/LCT/releases/latest) and run
it. Portable builds (x64 / ARM64, with or without the .NET runtime) and
SHA-256 checksums are attached to every release. The binaries are not
code-signed yet, so SmartScreen may ask you to confirm with
**More info ▸ Run anyway**.

> Version 2.0 is a new app under the same name. It replaces the 1.x
> Live Captions scraper: see [CHANGELOG.md](CHANGELOG.md) for what changed and
> [docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md) for how it works.

## What it does

- **Two capture channels.** System audio (anything the PC plays: videos,
  calls, meetings) and the microphone, each with its own recognition
  language. Switch languages live from the status bar; only the affected
  channel restarts.
- **On-device speech recognition.** whisper.cpp ggml models (tiny → large-v3-turbo),
  downloaded once on demand. Fourteen recognition languages.
- **Streaming local translation.** Ollama chat models (Qwen3.5 recommended,
  TranslateGemma supported) with live draft translation while people are still
  speaking, context from previous lines, an editable prompt, and a model
  catalog that picks a model for your CPU, GPU and memory.
- **Terminal-style HUD.** Recording timer, `SYS ZH · MIC EN → JA` language
  label, model and Ollama status, latency, per-channel level meters, SYS/MIC
  badges and timestamps on every line, a real pause.
- **Overlay, tray, hotkeys.** A floating always-on-top subtitle window
  (position, size, opacity, font size, click-through), a tray icon, and global
  hotkeys: `Ctrl+Alt+S` start/stop, `Ctrl+Alt+P` pause, `Ctrl+Alt+O` overlay.
- **Export and history.** Export the session as Markdown, text or SRT. History
  is off by default; when on, it stays in a local SQLite file with retention
  limits, search, delete and CSV export.
- **Ollama kept healthy.** LCT uses the Ollama you already have and never kills
  one you started yourself. It starts `ollama serve` only when nothing answers,
  restarts it with backoff if it dies mid-session, reloads the model if Ollama
  dropped it, and sends `num_ctx` with every request so a 4B model stays around
  3 GB.

## System requirements

| | |
|---|---|
| **Windows** | Windows 10 version 1809 or later, or Windows 11 — x64 or ARM64 |
| **Translation** | [Ollama for Windows](https://ollama.com/download/windows), or a remote Ollama reachable over HTTPS |
| **Memory** | 8 GB RAM minimum; 16 GB (or a GPU with 6 GB+ VRAM) for the 4B translation model |
| **Disk** | 2–4 GB for the translation model plus 150–500 MB for the speech model |
| **Network** | Only on first run, to download the models |

## First run

The wizard walks through everything:

1. **Audio & languages** — enable system audio and/or the microphone, pick the
   microphone device, the spoken language and the target language.
2. **Ollama** — LCT looks for a running service, then for an installed
   `ollama.exe`. If none is found it offers the download page, a remote server
   (HTTPS, explicit opt-in), or — on PCs with an Intel GPU — the optional
   IPEX-LLM portable build.
3. **Translation model** — downloads the model recommended for your hardware
   (with progress, cancel and a disk-space check), or lets you pick another.
4. **Speech model** — downloads the whisper model (`small` by default, `base`
   on low-end PCs).

Then press **start** (or `Ctrl+Alt+S`) and play some audio.

## Settings

Everything lives in **⚙ Settings** and in `%LOCALAPPDATA%\LCT\settings.json`:

- Audio capture: channels on/off, microphone device.
- Languages: system-audio language, microphone language (or "same"), target.
- Speech recognition: whisper model (download / size per model).
- Translation model: installed models, recommendation, in-app download,
  keep-alive (5 m … until quit), unload on quit.
- Ollama connection: host, port, remote opt-in (HTTPS only), timeout, `num_ctx`.
- Translation tuning: model type, temperature, live draft translation,
  context-aware translation and how many lines, custom prompt
  (`{TARGET_LANGUAGE}` placeholder, reset, preview).
- Display & overlay: latency, max cards, overlay opacity / font size / stay on
  top / click-through.
- History: on/off, retention days, max entries.
- Shortcuts & tray: global hotkeys, keep running in the tray on close.
- Diagnostics: export a metadata-only report (never transcripts) and open the
  log folder.

Logs: `%LOCALAPPDATA%\LCT\logs\`. Models: `%LOCALAPPDATA%\LCT\models\whisper\`
(speech) and Ollama's own store (translation).

## Troubleshooting

- **"receiving audio but nothing is being recognized"** — the channel's
  recognition language probably does not match what is being spoken. Change it
  from the language label in the status bar.
- **The microphone is completely silent** — check the selected device in
  Settings and Windows ▸ Privacy ▸ Microphone (desktop apps must be allowed).
- **Ollama indicator is red** — click it to start Ollama. If Ollama is not
  installed, the notice offers the download page.
- **Model not installed** — the notice offers an in-app download; or run
  `ollama pull qwen3.5:4b`.
- **Translation is slow on CPU** — pick `qwen3.5:2b` or `qwen3.5:0.8b` in
  Settings, or `base` as the speech model.

## Building

```bash
cd windows
dotnet test Tests/LCT.Tests/LCT.Tests.csproj
dotnet build LiveCaptionsTranslator.csproj
```

`LCT.Core` (all the logic without WPF) and its tests build on any OS; the WPF
app builds on Windows, or elsewhere with `-p:EnableWindowsTargeting=true`.
Releases are produced by `.github/workflows/windows-build.yml`; see
[docs/dev/RELEASE.md](docs/dev/RELEASE.md).

## Privacy

Audio never leaves the PC. Speech recognition runs in-process; translation goes
to the Ollama endpoint you configure (local by default; remote only with an
explicit opt-in and only over HTTPS). History is off unless you turn it on, and
the diagnostics export contains settings and status only.

## License

See [LICENSE](../LICENSE). Developed by Ai-All-You-Need-Platform Pte. Ltd.
