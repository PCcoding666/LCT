# LCT for Windows — Architecture (2.0)

LCT 2.0 replaces the Live Captions scraper with the same pipeline the macOS app
uses: capture audio ourselves, recognize speech on-device, translate through a
local Ollama. Nothing in the pipeline depends on Windows 11 accessibility
features any more, so the app runs on Windows 10 1809 and later.

```
 WASAPI loopback ─┐                       ┌─ partial ──► live draft line ──► (optional) draft translation
                  ├─► 16 kHz mono ─► VAD ─┤
 WASAPI capture ──┘    per channel        └─ final ────► TranslationSegment ─► TranslationQueue ─► Ollama (stream)
                                                                     │
                                                                     ├─► SessionTranscript (export MD/TXT/SRT)
                                                                     └─► HistoryStore (opt-in SQLite)
```

## Projects

| Project | Target | Purpose |
|---------|--------|---------|
| `src/LCT.Core/LCT.Core.csproj` | `net8.0` | Every piece of logic that does not need WPF or a Windows API: settings model, VAD and utterance chunking, resampling, text/segment utilities, Ollama HTTP client, translation queue, model catalogs and recommender, recovery controller, detectors, exporter, history store, diagnostics. **Builds and tests on any OS.** |
| `LiveCaptionsTranslator.csproj` | `net8.0-windows` (WPF) | The app. Audio devices (NAudio WASAPI), Whisper.net inference, Ollama process management, tray icon, global hotkeys, windows and view models. References `LCT.Core`. The assembly name stays `LiveCaptionsTranslator.exe` so the NSIS installer and release pipeline are unchanged. |
| `Tests/LCT.Tests/LCT.Tests.csproj` | `net8.0` | xUnit tests for `LCT.Core`. Runs in CI on the Windows runner before the five `dotnet publish` variants; can also run on macOS/Linux. |

## Directory layout

```
windows/
├── LiveCaptionsTranslator.csproj       WPF app (assembly LiveCaptionsTranslator.exe)
├── LiveCaptionsTranslator.sln
├── src/
│   ├── LCT.Core/
│   │   ├── Models/        AppSettings, Languages, AudioSource, TranslationSegment, SessionTranscript, AppNotice …
│   │   ├── Audio/         PcmConvert, Resampler, EnergyVad, UtteranceChunker, LevelMeter
│   │   ├── Speech/        WhisperModelCatalog, RecognitionEvent, ISpeechRecognizer
│   │   ├── Translation/   OllamaEndpoint, OllamaClient, TranslationQueue, PromptTemplate, ModelCatalog,
│   │   │                  HardwareProfile, ModelRecommender, PullStreamAccumulator, OllamaRecoveryController
│   │   ├── Session/       TextUtils, LanguageLabel, SessionExporter, RecognitionStallDetector, SilenceDetector,
│   │   │                  DiagnosticsReport
│   │   └── History/       HistoryStore (Microsoft.Data.Sqlite)
│   ├── App.xaml(.cs)                   startup, single instance, logging, tray, hotkeys, lifetime
│   ├── Services/
│   │   ├── Audio/         WasapiChannel (loopback + capture → 16 kHz mono frames), AudioDevices
│   │   ├── Speech/        WhisperRecognizer (Whisper.net), WhisperModelStore (download/progress/cancel)
│   │   ├── Ollama/        OllamaGuardian (detect / start / stop only our own process), OllamaModelManager (pull),
│   │   │                  IpexOllamaDownloader (optional Intel GPU portable build)
│   │   ├── Platform/      GlobalHotKeys (RegisterHotKey), TrayIcon, WindowPlacement, ClickThrough, HardwareInfo
│   │   └── CaptureSession.cs           orchestrates channels → recognizers → segmenter → queue (the "view-model core")
│   ├── ViewModels/        MainViewModel, SettingsViewModel, WelcomeViewModel, HistoryViewModel
│   ├── Views/             MainWindow, OverlayWindow, SettingsWindow, WelcomeWindow, HistoryWindow, PromptEditorWindow
│   └── Themes/Hud.xaml    terminal-HUD resource dictionary (colors, fonts, control styles)
├── Tests/LCT.Tests/
├── scripts/               installer and build scripts (unchanged)
└── docs/
```

## Services

### Audio capture (`Services/Audio`)
One `WasapiChannel` per source. `AudioSource.System` opens a
`WasapiLoopbackCapture` on the default render device; `AudioSource.Microphone`
opens a `WasapiCapture` on the chosen input device (or the default). Each
channel converts the device format to float mono (`PcmConvert`), resamples to
16 kHz (`Resampler`, windowed-sinc low-pass + linear interpolation), computes a
level for the meters (`LevelMeter`, dBFS normalized to 0…1) and pushes frames
to its `UtteranceChunker`. Channels are independent: switching one channel's
language restarts only that channel.

### Speech recognition (`Services/Speech`, `LCT.Core/Audio`)
**Engine: Whisper.net 1.9 (whisper.cpp) with ggml models.** The alternative was
sherpa-onnx streaming Zipformer. Whisper was chosen because: one multilingual
model covers all 14 source languages (Zipformer needs a model per language, and
good streaming models exist for far fewer languages); whisper.cpp's quality on
Chinese/Japanese/Korean is well established; the NuGet package ships native
binaries for win-x64 and win-arm64 so both portable builds work; and the
model files are small (base 142 MB, small 466 MB). The cost is latency —
Whisper is not a streaming decoder — which the chunker hides:

- `EnergyVad` is an RMS-energy voice activity detector with attack/hangover
  hysteresis, operating on 20 ms frames.
- `UtteranceChunker` keeps the audio of the current utterance. While speech is
  active it emits a **partial** request every 1.2 s (the utterance so far,
  capped at the last 20 s); when the VAD sees 600 ms of silence, or the
  utterance exceeds 25 s, it emits a **final** request and starts a new
  utterance. Pure logic, fully unit-tested.
- `WhisperRecognizer` runs one `WhisperProcessor` per channel on a dedicated
  worker. Partial requests are coalesced: if the decoder is busy, only the
  newest partial is kept. Finals are never dropped. Each decode yields a
  `RecognitionEvent` (`IsFinal`, text, source, utterance id).

Models download on demand to `%LOCALAPPDATA%\LCT\models\whisper\` from the
Whisper.net mirror on Hugging Face with progress and cancellation
(`WhisperModelStore`). `WhisperModelCatalog` lists tiny/base/small/medium/
large-v3-turbo with sizes; the recommender picks `small` by default and `base`
on machines with fewer than 8 GB RAM or 4 cores.

### Translation (`LCT.Core/Translation`, `Services/Ollama`)
Ported from the macOS services with the same behaviour:

- `OllamaEndpoint` validates host/port; loopback uses HTTP, anything else needs
  the explicit remote opt-in and is HTTPS only.
- `OllamaClient` streams `/api/chat` (NDJSON), always sends `think: false`,
  `keep_alive` from settings and `options.num_ctx` (default 4096) so a 4B model
  does not get loaded with a 32K context. Also `/api/tags`, `/api/ps`,
  `/api/generate` load/unload, `/api/pull` with `PullStreamAccumulator`.
- `TranslationQueue` — debounced drafts, immediate finals, preemption of a
  running draft by a final, dedup, pending-limit, stale-task pruning, retries
  with backoff, generation counter against stale tokens.
- `PromptTemplate` — default prompt with `{TARGET_LANGUAGE}`, custom override.
- `ModelCatalog` / `ModelRecommender` — qwen3.5 GGUF builds and TranslateGemma,
  picked by RAM (40 % budget) and GPU class (`HardwareProfile`: CPU name,
  RAM, GPU vendor and VRAM from WMI).
- `OllamaRecoveryController` — the 10 s patrol's decision table: restart with
  10/20/40 s backoff up to three times, reload the model when `/api/ps` shows
  it unloaded, announce recovery.
- `OllamaGuardian` (app) finds Ollama in this order: a service already
  answering on the endpoint; `ollama.exe` in `%LOCALAPPDATA%\Programs\Ollama`,
  on `PATH`, or the IPEX-LLM portable build under `%LOCALAPPDATA%\LCT\ollama`.
  It starts `ollama serve` only when nothing answers, remembers the PID, and
  `StopService` terminates only that process. **It never kills Ollama processes
  it did not start.** The IPEX-LLM download is offered in the wizard only when
  an Intel GPU is detected and no Ollama is installed.

### Session orchestration (`Services/CaptureSession.cs`)
Owns the channels, recognizers, segment list, `SessionTranscript`,
`TranslationQueue`, draft translation, stall/silence detectors and the Ollama
patrol. Pause stops feeding audio and parks finals as `Pending`; resume
re-enqueues them. Exposes events the view models bind to; contains no WPF.

### UI (`Views`, `Themes/Hud.xaml`)
Forced dark terminal HUD: background `#141416`, accent emerald `#33D499`,
hairlines at 8 % white, monospace (`Cascadia Mono`, `Consolas`) for every HUD
label, `Segoe UI` for transcript text. All default WPF control styles are
overridden in `Hud.xaml`. Windows: main (HUD bar, feed, meters, controls),
overlay (borderless, topmost, drag/resize, click-through, hover controls),
settings (every `AppSettings` key), welcome wizard (first run only), history,
prompt editor.

### Settings (`LCT.Core/Models/AppSettings.cs`)
JSON at `%LOCALAPPDATA%\LCT\settings.json`, written atomically. Keys mirror
`macos/LCTMac/Models/AppSettings.swift` one to one, plus Windows-only keys
(`WhisperModel`, `MicrophoneDeviceId`, `OllamaNumCtx`, `IpexOllamaUrl`,
hotkey chords). Missing keys take defaults, so older files load. The 1.x
`setting.json` is not read.

## Data flow for one sentence

1. Loopback delivers 48 kHz stereo float frames → mono → 16 kHz → RMS level
   published to the meter → `UtteranceChunker`.
2. Speech starts; after 1.2 s the chunker emits a partial request;
   `WhisperRecognizer` decodes 1.2 s of audio and raises
   `RecognitionEvent(IsFinal=false, "The quick brown")`. `CaptureSession`
   updates the SYS draft line; if live draft translation is on, the queue gets
   a debounced draft task.
3. 600 ms of silence → final request → `RecognitionEvent(IsFinal=true, …)` →
   a `TranslationSegment` in state `Translating` is appended, written to
   `SessionTranscript`, and a final task preempts the running draft task.
4. Tokens stream back; the segment's text grows with a cursor; on `done` the
   segment is `Translated`, latency recorded, context updated, history
   written if enabled.

## What CI verifies and what it cannot

CI (`.github/workflows/windows-build.yml`) runs `dotnet test` on `LCT.Tests`
and then the five publishes. Audio devices, Whisper inference, tray, hotkeys
and window behaviour need a Windows machine; the PR carries the manual
checklist.
