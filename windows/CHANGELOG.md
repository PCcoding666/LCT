# Changelog: LCT for Windows

User-facing changes to the Windows app, newest first. The section whose heading
matches a release tag `vX.Y.Z` becomes the body of that GitHub Release (see
[docs/dev/RELEASE.md](docs/dev/RELEASE.md)), so write for the person installing
the app, not for the commit log.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0] - Unreleased

LCT 2.0 is a new app under the same name. It no longer reads Windows Live
Captions: it captures audio itself, recognizes speech on your PC and
translates with a local Ollama model, the same way the macOS app does.

### Added
- Own audio capture: system audio (WASAPI loopback) and the microphone are two
  independent channels, each with its own recognition language, that you can
  switch live. Pick the microphone device in Settings.
- On-device speech recognition with whisper.cpp (ggml models, downloaded on
  demand with progress and cancel). Fourteen recognition languages, no Live
  Captions language pack needed.
- Streaming translation with live drafts while people are still speaking,
  context-aware prompts, an editable prompt with `{TARGET_LANGUAGE}`, and a
  model catalog that recommends a model for your CPU, GPU and memory.
- In-app model download (progress, cancel, disk-space check), configurable
  keep-alive, and unloading the model when LCT quits.
- Ollama health patrol: restarts the service with backoff (up to three times)
  and reloads the model if Ollama dropped it.
- New terminal-style dark interface: status bar with recording timer,
  per-channel language label, model and Ollama indicator, latency; SYS/MIC
  badges and timestamps on every line; level meters for both channels; a real
  pause that resumes where it left off.
- Floating overlay (always on top, remembers position and size, opacity, font
  size, click-through), tray icon, and global hotkeys (Ctrl+Alt+S start/stop,
  Ctrl+Alt+P pause, Ctrl+Alt+O overlay).
- Export the current session as Markdown, text or SRT subtitles.
- Optional history (off by default) with retention days, maximum entries,
  search, delete one entry, clear all, CSV export.
- Diagnostics export (settings and status only, never transcripts) and a
  "Show Log Folder" button.
- Warnings when a channel hears audio but recognizes nothing (wrong language?)
  and when the microphone is completely silent.
- First-run wizard: audio devices and languages, Ollama detection or remote
  server, translation model download, speech model download.
- Remote Ollama servers are supported only with an explicit opt-in and only
  over HTTPS.

### Changed
- Runs on Windows 10 (1809) and later; Windows 11 is no longer required.
- LCT uses the Ollama you already have. It starts `ollama serve` only when
  nothing is running and stops only the process it started — it never kills
  an Ollama you launched yourself. The Intel GPU (IPEX-LLM) portable build is
  now an optional download in the wizard for PCs with an Intel GPU and no
  Ollama, instead of being forced on every PC.
- Every Ollama request sets `num_ctx` (4096 by default, adjustable) so a 4B
  model stays around 3 GB instead of being loaded with a 32K context.
- Default translation model is Qwen3.5 (4B, 2B or 0.8B depending on the PC).
- Settings moved to `%LOCALAPPDATA%\LCT\settings.json`; 1.x settings are not
  migrated.

### Removed
- The Live Captions integration and everything that depended on it: the
  "Show Live Captions" toggle, the sync interval and the 25 ms polling loop.
- The in-app updater, telemetry, data migration and enterprise welcome
  screens. Updates are published on the GitHub Releases page.

## [1.0.4] - 2026-11-01

Puts the Windows app back on the 1.0.x version line and rebuilds the release
pipeline. The application itself is the same as 0.1.4.

### Changed
- Version numbering is back on the 1.0.x line. 0.1.4 was published with a
  number lower than 1.0.3 by mistake; 1.0.4 supersedes both.
- The installer and the portable executables are built together from one
  pipeline and carry the same version as the release tag. The executable's own
  version information no longer reports 1.0.2.
- Release notes are written for users (this file) instead of being generated
  from commit messages.
- SHA-256 checksums (`SHA256SUMS.txt`) are published with every release.
- The in-app update check looks at this repository's releases instead of an
  older repository.

### Fixed
- The in-app updater could never find the installer: it required "x64" in the
  file name, which `LCT-vX.Y.Z-Setup.exe` never had, so installing an update
  always failed with "No suitable installer found for this platform".

## [0.1.4] - 2026-01-27

Published out of sequence: the number is lower than 1.0.3 although the build is
newer. Contains 1.0.3 plus internal CI/CD changes; no user-facing changes.

## [1.0.3] - 2025-11-13

### Changed
- Updated company information in the About page.

### Fixed
- The Info page scrolls again.

## [1.0.2] - 2025-11-10

### Added
- Translation history: delete single entries or all entries, with a
  confirmation dialog.
