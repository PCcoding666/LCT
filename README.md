# LCT for macOS

LCT is a native macOS app for real-time captions and local AI translation.
It captures system audio or microphone input, transcribes speech, and streams
the translation alongside the original text.

The default branch (`master`) is maintained for **macOS**. The Windows app is
[archived](docs/WINDOWS_ARCHIVE.md), including its latest unmerged development
work. Its source and earlier releases remain available.

## Requirements

- macOS 15 or later; macOS 26 is recommended for concurrent system-audio and
  microphone recognition using `SpeechAnalyzer` / `SpeechTranscriber`.
- Xcode 16 / Swift 6 or later to build. Xcode 26 is needed to include the newer
  speech engine; older toolchains use `SFSpeechRecognizer`.
- [Ollama](https://ollama.com) and a local translation model.
- Microphone, speech recognition, and system-audio permissions as needed for
  the selected audio sources.

## Development

```bash
cd macos
./Scripts/dev-run.sh
```

Use `dev-run.sh` to build, sign, and launch the app with a consistent identity.
Do not launch it with `swift run` or the raw `.build/.../LCTMac` executable:
macOS privacy permissions would not match the packaged app.

```bash
cd macos
swift build                # Debug build
./Scripts/run_tests.sh     # Debug, release, warnings-as-errors, and XCTest
./package-app.sh           # Package the app
```

## Repository layout

```text
macos/LCTMac/              App, views, view models, services, and models
macos/Tests/LCTMacTests/   XCTest suite
macos/Scripts/             Development, packaging, and release tools
docs/                     User documentation and Windows archive reference
benchmark/                Ollama translation benchmarks and fixtures
.github/workflows/        macOS build, test, and manual delivery workflow
```

## Documentation and delivery

- [macOS development guide](macos/README.md)
- [User guide](macos/USER_GUIDE.md)
- [Testing](macos/TESTING.md)
- [Signing and release](macos/RELEASE.md)
- [Windows archive and recovery instructions](docs/WINDOWS_ARCHIVE.md)

Pull requests and mainline pushes run the macOS build and test workflow.
Signing, notarization, and DMG upload are a separate, manually triggered
delivery job requiring the configured Apple signing credentials. Merging a PR
does not publish a release.

## License

See [LICENSE](LICENSE).
