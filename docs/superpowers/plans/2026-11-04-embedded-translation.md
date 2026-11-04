# Embedded Translation Implementation Plan

> Agentic execution: independent owners implement the capture boundary, embedded runtime, and UI; root integrates and verifies the packaged app.

**Goal:** Address Issue #25: make captions usable without Ollama or LLM weights, then provide app-managed offline translation.

**Architecture:** Keep native speech/capture and session storage. TranslationQueue targets a TranslationEngine protocol. A shared EmbeddedTranslationService owns a pinned llama.cpp runtime and a verified app-local Qwen GGUF; its state never gates caption start.

**Tech Stack:** Swift 6 / macOS 15+, llama.cpp official b11960 XCFramework, Qwen2.5-1.5B-Instruct Q4_K_M.

**Spec:** https://github.com/PCcoding666/LCT/issues/25

## Constraints

- No Ollama install probes, health checks, launches, model requests, or fallback in production flows.
- Captions, pause/resume, stop, and source export work before translation download.
- Default to system audio; microphone permission is needed only when selected.
- Existing transcript/history consent survives settings migration.
- Model download is explicit, cancellable, resumable/retryable, verified before load.
- Models stay in Application Support/LCT, not Git or an external service.
- Signing/notarized public release remains a separate approval/credential boundary.

## Shared interfaces

`@MainActor protocol TranslationEngine: AnyObject`:
- `updateSettings(_ settings: AppSettings)`
- `translate(text: String, context: [TranslationEntry]) async throws -> (String, Int)`
- `translateStreaming(text: String, context: [TranslationEntry], onToken: @escaping @MainActor (String) -> Void) async throws -> Int`

`@MainActor final class EmbeddedTranslationService: ObservableObject, TranslationEngine`:
- `static let shared`
- `@Published private(set) var state: EmbeddedTranslationState`
- `@Published private(set) var downloadProgress: Double`
- `@Published private(set) var downloadedBytes: Int64`
- `static let modelName: String`; `static let modelSizeBytes: Int64`
- `var isReady: Bool`; `var isModelDownloaded: Bool`
- `func downloadModel() async throws`
- `func cancelDownload()`
- `func loadModel() async throws`
- `func unloadModel() async`

State cases: `notDownloaded`, `downloading`, `verifying`, `downloaded`, `loading`, `ready`, `failed(String)`; Equatable.

`AppSettings.translationEnabled: Bool` defaults false. VM exposes `translationStatusText` and `isTranslationReady` and uses the shared service for UI transitions. Final segments without translation use `.captionOnly`.

## Tasks

### 1. Capture lifecycle and queue (VM owner)

- [x] Add failing isolated tests using fake capture/speech: no engine/HTTP required; source export; no-microphone system lane; pause/resume preserving session; readiness changes do not reset captions.
- [x] Add protocol, queue injection, optional translation setting and caption-only segment state. Migrate tests that relied on invalid Ollama endpoints preventing real capture.
- [x] Remove production Ollama init/start/patrol/stop/settings/quit paths in VM, AppCoordinator, and AppDelegate.
- [x] Preserve ordered final-token delivery and stale-generation guards. Retain old provider types only for legacy test compatibility, never the production default.
- [x] Run targeted lifecycle and queue tests, report obsolete behavior tests migrated.

### 2. Runtime and model download (runtime owner)

- [x] Pin official runtime URL/checksum and official model revision/size/SHA-256/license.
- [x] Add failing tests for absent/corrupt model, cancellation, retry/resume, HTTP validation and offline load behavior using deterministic transport fixtures.
- [x] Implement the shared interfaces above; keep C pointers and inference off MainActor and serialize load/generate/unload.
- [x] Add Package.swift binary target, runtime framework copying/rpath/nested signing, license inclusion, and packaged-app verification.
- [ ] Verify generation and cancellation with the real packaged runtime, without Ollama.

### 3. UI and first-run validation (root)

- [x] Capture old missing-Ollama failure from a reset installation.
- [x] Replace service setup/remote host flows with captions-first onboarding and optional in-app translation model preparation.
- [x] Replace model/server settings and status with independent audio/speech/translation states; expose download, cancel, retry, enable translation while capturing.
- [x] Keep history/export and user audio/language controls available in caption-only mode.
- [x] Update docs and run complete repository checks.
- [ ] Test signed packaged app from reset state: initial permissions, system/mic/dual capture, source-only pause/export, model download/cancel/retry, live enable, offline translation, failure isolation, relaunch/quit. Record screenshots/logs and exact limitations.

## Review focus

- Failed/partial/cancelled model downloads cannot be loaded or destroy a valid model.
- A slow generation or unload cannot freeze GUI or mix token streams across sessions.
- Permission denial/missing microphone cannot block a system-only caption session.
- Missing speech assets are shown separately from missing translation weights.
- App bundle must resolve/sign the actual embedded framework, not rely on build-tree paths.

## Completion evidence

Run `cd macos && ./Scripts/run_tests.sh`. Run the packaged app through `Scripts/dev-run.sh`, never the raw executable. Record every Issue #25 acceptance item as passed, failed, or blocked; do not close the issue or claim official distribution without a verified signed/notarized deliverable.

## Additional verified fixes

Review and regression tests found and fixed source-only history persistence,
stop-time partial-caption loss, repeated text across independent segments,
corrupt-model replacement, and normal-quit download resume persistence.
History stores the original caption before translation, then updates the same
ID on success; a failed translation keeps the original. Consent remains off by
default. Runtime and capture checks use isolated fixtures; actual GUI/audio,
model download, inference and distribution remain separate acceptance steps.

## Local validation checkpoint (2026-11-04)

- `Scripts/run_tests.sh`: debug, release, warnings-as-errors and 555 XCTest
  cases passed, zero failures.
- `Scripts/dev-run.sh --no-launch`: development-signed bundle built; nested
  framework and strict signature verification passed.
- Bundle copied outside the build tree to Applications and launched through
  the GUI. The captions-first welcome screen and system-only default were
  observed. No Ollama or LLM model was installed.
- Live capture is pending the first-run privacy authorizations. Actual model
  download/inference/offline validation and signed/notarized distribution are
  not yet claimed. A command-line probe of the official model host timed out;
  the application's own download path remains to be exercised.
