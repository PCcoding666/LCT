# LCT — LiveCaptions Translator

Real-time speech-to-text captioning with on-the-fly AI translation, available as
native apps for **Windows** and **macOS**.

LCT listens to live audio (system playback or microphone), transcribes it, and
streams a translation alongside the original — useful for following talks,
meetings, videos, or calls across a language barrier.

## Platforms

| Platform | Stack | Status | Docs |
|----------|-------|--------|------|
| [Windows](windows/) | C# / .NET 8 (WPF) + LiveCaptions | Stable | [windows/README.md](windows/README.md) |
| [macOS](macos/) | SwiftUI + `SFSpeechRecognizer` + local LLM (Ollama) | Active development | [macos/README.md](macos/README.md) |

The two apps are independent codebases tuned to each platform's native speech and
UI frameworks. They share this repository for common documentation, translation
benchmarks, and a single issue/release home.

## Repository layout

```
.
├── windows/      # Windows app (.NET solution, source, installer scripts)
├── macos/        # macOS app (Swift Package, SwiftUI)
├── benchmark/    # Cross-platform translation-quality benchmarks
├── docs/         # Shared / macOS user documentation
└── .github/      # CI workflows (per-platform, path-filtered)
```

## Building

- **Windows** — open `windows/LiveCaptionsTranslator.sln` in Visual Studio, or
  `dotnet build` inside `windows/`. See [windows/README.md](windows/README.md).
- **macOS** — `cd macos && ./package-app.sh` (or `swift build`). Requires macOS 15+
  and a local [Ollama](https://ollama.com) install. See [macos/README.md](macos/README.md).

## License

See [LICENSE](LICENSE). Applies to both platform apps.
