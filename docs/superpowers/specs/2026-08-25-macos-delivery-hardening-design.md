# macOS Delivery Hardening — Design

Date: 2026-08-25
Status: Approved for planning
Scope: `macos/` app, `macos/Scripts/`, `.github/workflows/macos-build.yml`, macOS-facing docs. The `windows/` project and its workflows are out of scope.

## 1. Problem statement

Today the macOS app ships (via `v*` tag → `.github/workflows/macos-build.yml`) as a ZIP of an **ad-hoc-signed, un-notarized** `.app`. Gatekeeper quarantines it for every end user. CI never runs tests before packaging, docs promise a `.dmg` that is never built, versioning is inconsistent across three divergent packaging scripts, and the app leaks spoken content into plaintext logs and diagnostics exports while history recording is always on.

## 2. Evidence summary (repository, 2026-08-25)

Signing/packaging:
- `macos/package-app.sh:30-37` signs with local identity `LCT Dev` or falls back to ad-hoc; **no `--options runtime`, no `--entitlements`**.
- `macos/Scripts/build-app.sh:56-63` ad-hoc with entitlements; `macos/Scripts/build_signed.sh:33-55` signs the bare executable (not the bundle) — three divergent paths.
- No `notarytool`/`stapler`/notarization anywhere in the repo. No DMG (`hdiutil`/`create-dmg`) anywhere, yet `macos/QUICK_START.md`, `USER_MANUAL.md`, `USER_GUIDE.md` promise a `.dmg`.
- `macos/LCTMac/Info.plist:34-36` contains a misplaced entitlement key (`com.apple.security.device.audio-input`). No screen-capture usage-description key is required: the app's capture APIs (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `SCShareableContent`) use system-managed TCC authorization; `NSScreenCaptureUsageDescription` is not consulted for them on the macOS 15 target.
- Versioning: only `package-app.sh:19-23` stamps `CFBundleShortVersionString` (`git describe --tags`, fallback `0.1.0` — non-semver, can carry dirty suffixes) and `CFBundleVersion` (commit count). `SettingsView.swift:371-372` reads both at runtime.

CI:
- `macos-build.yml` (macos-14, Swift 6.0): no `swift test` step; packages then zips; release job on `v*` tags uploads the ad-hoc zip via `softprops/action-gh-release@v2`. Only secret referenced in any workflow is `GITHUB_TOKEN` — a release tag succeeds with zero signing/notarization configuration.

Privacy:
- History: SQLite at `~/Library/Application Support/LCT/history.sqlite` (`HistoryService.swift:44-48`); every translation persisted unconditionally (`TranscriptionVM.swift:682`); **no enable toggle**; defaults `historyRetentionDays = 30`, `historyMaxEntries = 5000` (`AppSettings.swift:178-179`).
- Logging: `appLog()` → `~/Library/Logs/LCTMac.log` (`AppDelegate.swift:26-33`). `SpeechAnalyzerService.swift:236` writes first 80 chars of every transcription result into the log. Diagnostics export bundles the last 50 log lines (`SettingsView.swift:369-409, 431-441`) and instructs users to attach it.
- Ollama: scheme hardcoded `http://` (`AppSettings.swift:197-203`); any remote host accepted with no validation or auth; transcripts travel cleartext off-machine. `OllamaGuardian.swift:82` and `OllamaModelManager.swift:149` hardcode `http://localhost:11434`.
- `SpeechAnalyzerService.swift:162` sets `requiresOnDeviceRecognition = false`, contradicting the "all processing on your device" claim in `WelcomeView.swift:169`.

Docs/legal:
- `LICENSE` exists at repo root (not bundled in the app or release assets). Onboarding/permission views exist (Typeless-style), hotkeys documented loosely; coverage table in `macos/TESTING.md` lists only 3 of 9 test files.

## 3. Required outcomes

**P0 (release-blocking):**
1. Developer ID signing with hardened runtime + entitlements on the shipping bundle.
2. Notarization via `notarytool`, stapling via `stapler`, automated Gatekeeper validation (`spctl --assess`, `codesign --verify --strict`).
3. Release artifacts: DMG **and** ZIP, plus license notice in bundle and release.
4. Semantic `CFBundleShortVersionString` (X.Y.Z) and monotonic `CFBundleVersion`, stamped in one place.
5. CI runs tests **before** packaging; release tags **fail** without signing/notarization configuration.

**P1 (privacy and correctness):**
6. History recording defaults **OFF** (explicit opt-in toggle).
7. Text-free logs and diagnostics: no transcribed/translated content in `LCTMac.log` or the diagnostics export.
8. Remote (non-loopback) Ollama only via HTTPS, with a clear opt-in; loopback stays HTTP.
9. Docs, legal notices, onboarding copy, and hotkey documentation are accurate.

**P2 (quality):**
10. Accessibility (VoiceOver labels/values on key controls), localization readiness (string extraction foundation), update readiness (versioned update channel groundwork, e.g. Sparkle evaluation — decision only).

## 4. Key design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Canonical packaging path | Single `macos/package-app.sh` pipeline; `Scripts/build-app.sh` and `Scripts/build_signed.sh` reduced to thin wrappers or deleted | Eliminates the three divergent sign paths that caused the ad-hoc release |
| Signing model | Release: Developer ID Application identity + `--options runtime` + `--entitlements LCTMac/LCTMac.entitlements`. Local dev: keep ad-hoc with `--options runtime --entitlements` so local Gatekeeper behavior matches release | Hardened runtime is mandatory for notarization |
| Notarization | Sign the `.app`, build the DMG, then submit the **final DMG** (`xcrun notarytool submit --wait`; accepted carriers are `.zip`/`.dmg`/`.pkg`) and `xcrun stapler staple` the **DMG** — the carrier that ships. A ZIP carrier cannot be stapled; for the ZIP artifact the app is stapled inside it instead | Apple's flow staples the distributed installer; stapling lets offline Gatekeeper pass |
| DMG | `hdiutil create` (read-only, UDZO) with symlink-to-/Applications layout; **not codesigned** (the DMG is not a usual codesign target — Gatekeeper evaluates the Developer ID app inside); notarized and stapled as the submission carrier | No third-party tooling needed |
| Versioning | `CFBundleShortVersionString` from latest semver tag (must match `^[0-9]+\.[0-9]+\.[0-9]+$`; strip `v`); `CFBundleVersion` = `git rev-list --count HEAD`. Fallback for no tag: `0.1.0`. One shared `macos/Scripts/version-stamp.sh` used by all build scripts | Deterministic, semantic, monotonic; fixes non-semver `git describe` output |
| CI gate | On `v*` tags: require `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` — missing any ⇒ workflow fails before release. Branch/PR runs: test + ad-hoc package only | A release must never ship unsigned/un-notarized again |
| Test ordering | `swift test` (and warnings-as-errors build) runs **before** any packaging step in CI and in `Scripts/run_tests.sh` (already does) | Required outcome 5 |
| History default | New `AppSettings.historyEnabled: Bool = false`; `TranscriptionVM` skips `logTranslationAsync` when disabled; Settings UI toggle under existing History group | Privacy-safe default; existing retention/pruning/delete/clear/export remain |
| Log redaction | Remove transcript text from `SpeechAnalyzerService.swift:236` (log length/isFinal only); audit all `appLog`/`print` sites for content; diagnostics export then text-free by construction | Simpler and safer than redaction filters |
| Remote Ollama | `ollamaURL` computed property picks scheme: loopback ⇒ `http://`; non-loopback ⇒ `https://` only. New `remoteOllamaOptIn: Bool = false`; non-loopback host rejected in Settings validation unless opt-in checked; warning banner explains HTTPS requirement | Required outcome 8; no cleartext off-machine traffic |
| ASR claim | Fix `WelcomeView.swift:169` copy to describe on-device-by-default-with-optional-network, or set `requiresOnDeviceRecognition = true` — decide in docs task; default: correct the copy and document | Docs/legal accuracy |
| Entitlements/plist | Remove misplaced entitlement key from `Info.plist`; do **not** add `NSScreenCaptureUsageDescription` — the app's capture APIs (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `SCShareableContent`) use system-managed TCC authorization that never reads a usage-description key on the macOS 15 target | Correctness; avoids shipping a dead/unused key |

## 5. External blocker (Apple credentials)

The items below are the **sole external launch blocker** for the first notarized release; everything else in this program is implementable and testable in-repo. Signing/notarization cannot be validated end-to-end without Apple-side assets that do not exist yet:
1. Apple Developer Program membership with a **Developer ID Application** certificate (exported as `.p12` → `MACOS_CERTIFICATE` base64 secret + `MACOS_CERTIFICATE_PASSWORD`).
2. App-specific password for the Apple ID → `APPLE_APP_SPECIFIC_PASSWORD`.
3. `APPLE_ID` and `APPLE_TEAM_ID`.

Until these exist, P0 tasks must still be fully implementable and testable locally with the dev/ad-hoc paths; the CI release path is written to fail loudly on missing secrets, and the first real notarized release is a manual smoke test gated on the owner supplying credentials. This blocker is recorded in the plan and does not block merging P0 code.

## 6. Out of scope

- Windows project (`windows/`, `build-and-release.yml`, `dotnet-build.yml`) — untouched.
- Windows code signing (separate program).
- ASR engine changes, model changes, feature work beyond the listed outcomes.
- Auto-update implementation (P2 is readiness/decision only).

## 7. Risks

| Risk | Mitigation |
|---|---|
| Entitlements too broad ⇒ notarization rejection (e.g. `allow-unsigned-executable-memory`) | Keep only what the runtime needs; notarization log review in the smoke-test task |
| `swift test` requires mic/permission on runners | Existing 9 test files are unit-level; Ollama integration tests already skip when `localhost:11434` unreachable (`Scripts/run_tests.sh:41-45`) |
| Three release writers contend on the same `v*` tag (macos-build, build-and-release, dotnet-build) | macOS release assets get distinct names (`LCTMac-{version}.dmg/.zip`); do not touch Windows workflows in this program |
| History default flip surprises existing users | Settings toggle + one-time note in release notes/docs |
