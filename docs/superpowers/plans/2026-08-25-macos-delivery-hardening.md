# macOS Delivery Hardening — Implementation Plan

Date: 2026-08-25
Design: `docs/superpowers/specs/2026-08-25-macos-delivery-hardening-design.md`
Worktree: `worktree-macos-delivery-hardening` (branch `worktree-macos-delivery-hardening`). All work happens here; original checkout and `windows/` are never touched.

Method: TDD — for every task, write/extend a failing test first, commit nothing until `swift test` passes. One commit per task using conventional commits. Never expose transcript/history contents in any artifact produced here.

## External blocker (recorded, non-blocking for code)

The five Apple secrets below are the **sole external launch blocker** for the first notarized release; no other external dependency exists. Real Developer ID signing + notarization requires Apple assets that do not exist yet:
`MACOS_CERTIFICATE` (base64 .p12), `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
All P0 code is implemented and tested via local/ad-hoc paths; the CI release gate fails loudly until the owner adds these secrets. Final notarized release is a manual smoke test (task T8) after credentials land.

## Baseline commands (run before and after every task)

```bash
cd macos
swift build -Xswiftc -warnings-as-errors
swift test
```

## P0 — Release signing, notarization, artifacts, CI, versioning

### T1. Entitlements + Info.plist hygiene
- Files: `macos/LCTMac/Info.plist`, `macos/LCTMac/LCTMac.entitlements`
- Remove misplaced `com.apple.security.device.audio-input` key from `Info.plist` (lines 34–36). Do **not** add `NSScreenCaptureUsageDescription`: the app's capture APIs (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, `SCShareableContent`) use system-managed TCC authorization that never reads a usage-description key on the macOS 15 target. Keep entitlements only in `LCTMac.entitlements` (audio-input, network.client, allow-unsigned-executable-memory, app-sandbox=false).
- Test first: add `Tests/LCTMacTests/InfoPlistTests.swift` — parse `LCTMac/Info.plist` and assert: no `com.apple.security.*` keys present, no `NSScreenCaptureUsageDescription` key present (guard against adding a dead key), `CFBundleIdentifier == "com.lct.mac"`.
- Accept: `swift test --filter InfoPlistTests`; `plutil -lint macos/LCTMac/Info.plist`.
- Commit: `fix(macos): clean Info.plist and entitlements for notarization`

### T2. Unified semantic version stamping
- Files: new `macos/Scripts/version-stamp.sh`; modify `macos/package-app.sh` (replace lines 19–23), `macos/Scripts/build-app.sh`, `macos/Scripts/build_signed.sh` (call the shared script).
- Rules: `CFBundleShortVersionString` = latest tag with `v` stripped, must match `^[0-9]+\.[0-9]+\.[0-9]+$`, else fail on tag-driven builds / fall back to `0.1.0` locally; `CFBundleVersion` = `git rev-list --count HEAD`.
- Test first: add `Tests/LCTMacTests/VersionStampTests.swift` — invoke `Scripts/version-stamp.sh` on a temp plist copy with tag `v1.2.3` and no-tag cases; assert semantic format and monotonic build number.
- Accept: `swift test --filter VersionStampTests`; manually `bash macos/Scripts/version-stamp.sh --check`.
- Commit: `feat(macos): unified semantic version stamping across build scripts`

### T3. Canonical signing path (hardened runtime)
- Files: `macos/package-app.sh` (replace signing block lines 30–37); delete or reduce `macos/Scripts/build-app.sh` and `macos/Scripts/build_signed.sh` to wrappers of the canonical path.
- Behavior: Developer ID identity from `LCT_SIGN_IDENTITY`/keychain when present ⇒ `codesign --force --options runtime --timestamp --entitlements LCTMac/LCTMac.entitlements --sign "$ID" "$APP"`. Otherwise ad-hoc `codesign --force --options runtime --entitlements ... --sign - "$APP"` (local dev parity). Also add `Contents/PkgInfo` and copy root `LICENSE` into `Contents/Resources/LICENSE.txt`.
- Test first: add `Tests/LCTMacTests/SigningTests.swift` (shell-driven): after `./package-app.sh`, assert `codesign -dv --verbose=4` output contains `flags=runtime`, entitlements applied, and `codesign --verify --strict --deep LCTMac.app` exits 0.
- Accept: `cd macos && ./package-app.sh && swift test --filter SigningTests`; `codesign --verify --strict --verbose=2 LCTMac.app`.
- Commit: `feat(macos): hardened-runtime signing with entitlements in canonical package path`

### T4. DMG artifact (not codesigned)
- Files: new `macos/Scripts/make-dmg.sh`; called from `package-app.sh` after the app is signed.
- Behavior: `hdiutil create` UDZO read-only DMG containing the signed `LCTMac.app` + `/Applications` symlink layout. The DMG is **not codesigned** — it is not a usual codesign target; Gatekeeper evaluates the Developer ID app inside. Output `LCTMac-{version}.dmg`.
- Test first: extend `SigningTests.swift` — DMG exists, `hdiutil verify` passes, mounted volume contains app + Applications symlink.
- Accept: `swift test --filter SigningTests`; `hdiutil verify macos/LCTMac-*.dmg`.
- Commit: `feat(macos): unsigned read-only DMG release artifact`

### T5. Notarization + stapling (DMG as submission carrier)
- Files: new `macos/Scripts/notarize.sh`; modify `macos/package-app.sh` to call it after the DMG is built, when `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` are all set (skip with clear message otherwise for local runs).
- Flow: `xcrun notarytool submit LCTMac-{version}.dmg --apple-id ... --password ... --team-id ... --wait` — the final DMG is the submission carrier (notarytool accepts `.zip`/`.dmg`/`.pkg`) ⇒ on failure fetch `xcrun notarytool log <submission-id>` ⇒ on success `xcrun stapler staple LCTMac-{version}.dmg` (DMG is a stapler-supported carrier) + `xcrun stapler validate` ⇒ then build `LCTMac-{version}-macOS.zip` containing a stapled app: extract the app from the stapled DMG, `xcrun stapler staple LCTMac.app`, zip with `ditto -c -k --sequesterRsrc --keepParent`. The ZIP carrier itself is **not** staplable — the stapled app travels inside it.
- Test first: add `Tests/LCTMacTests/NotarizeScriptTests.swift` — dry-run mode of `Scripts/notarize.sh --dry-run` asserts correct command construction (submit and staple target the DMG; ZIP is built afterwards from the stapled app; no `codesign` on the DMG) and that it aborts (non-zero) when any credential env var is missing.
- Accept: `swift test --filter NotarizeScriptTests`.
- Commit: `feat(macos): notarytool notarization and stapling with DMG carrier`

### T6. Gatekeeper validation script
- Files: new `macos/Scripts/verify-gatekeeper.sh`.
- Behavior: on the shipped carrier — `xcrun stapler validate LCTMac-{version}.dmg`; mount the DMG and assess the app inside (`spctl --assess --type execute --verbose=4`, `codesign --verify --strict`) since Gatekeeper evaluates the app, not the DMG; quarantine simulation of a fresh download: `xattr -w com.apple.quarantine` on the app copy, then `spctl --assess` again. Ad-hoc local runs skip `spctl` (it only passes Developer ID), assert `codesign --verify --strict` + entitlements instead, and print a warning.
- Test first: `Tests/LCTMacTests/GatekeeperTests.swift` drives the script in ad-hoc mode and asserts exit 0 plus expected output markers.
- Accept: `swift test --filter GatekeeperTests`; `bash macos/Scripts/verify-gatekeeper.sh`.
- Commit: `feat(macos): automated Gatekeeper validation script`

### T7. CI: tests before packaging, fail release tags without signing config
- Files: `.github/workflows/macos-build.yml`.
- Changes:
  1. Build job order: checkout → setup Swift 6.0 → `swift build -Xswiftc -warnings-as-errors` → `swift test` → package. Any test failure fails the workflow before packaging.
  2. On `v*` tags: step that fails (`exit 1` with message) unless `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` are all present. Import cert into temp keychain, run `package-app.sh` with signing env, notarize, staple, verify-gatekeeper.
  3. Release job uploads `LCTMac-{version}.dmg`, `LCTMac-{version}-macOS.zip`, and `LICENSE` as release notes attachment; keeps `softprops/action-gh-release@v2`.
  4. Branch/PR runs keep ad-hoc packaging + artifact upload.
- Test: workflow YAML lint **without undeclared dependencies** (PyYAML is neither declared nor guaranteed on runners): `ruby -ryaml -e 'YAML.load_file(ARGV[0])' .github/workflows/macos-build.yml` (Ruby stdlib ships on GitHub-hosted macos/ubuntu runners); dry-run tag behavior verified in T8 smoke test.
- Accept: YAML parses; local simulation `TAG=v0.0.1 bash macos/Scripts/ci-simulate.sh` (small helper added in this task) fails without secrets.
- Commit: `ci(macos): test before package; fail release tags without signing/notarization secrets`

### T8. Manual notarized-release smoke test (blocked on Apple credentials)
- No code. Owner adds the five secrets; push tag `v{next}`; verify: workflow passes; on the downloaded DMG (download so the browser sets the quarantine xattr) `xcrun stapler validate` passes — the stapled ticket travels with the carrier; after mounting, `spctl --assess --type execute` passes on the app inside and Gatekeeper opens it cleanly on a clean Mac, including offline (stapled ticket, no online lookup).
- Record outcome in the PR description. If secrets unavailable, this task stays open and is explicitly labeled blocked.
- No commit (or empty-note commit only if orchestrator requires).

## P1 — Privacy, correctness, docs

### T9. History recording defaults OFF
- Files: `macos/LCTMac/Models/AppSettings.swift` (add `var historyEnabled: Bool = false` near lines 178–179, persisted via existing `LCTMacSettings` JSON), `macos/LCTMac/ViewModels/TranscriptionVM.swift` (guard line 682 write + 683–688 prune behind `settings.historyEnabled`), `macos/LCTMac/Views/SettingsView.swift` (Toggle at top of History DisclosureGroup, lines 276–288).
- Test first: extend `Tests/LCTMacTests/HistoryServiceTests.swift` — fresh default settings have `historyEnabled == false`; VM-level test: with history disabled, `logTranslationAsync` is not invoked (assert DB row count stays 0); enabling the toggle persists across save/load.
- Accept: `swift test --filter HistoryServiceTests`.
- Commit: `feat(macos): history recording off by default with explicit opt-in`

### T10. Text-free logs and diagnostics
- Files: `macos/LCTMac/Services/SpeechAnalyzerService.swift` (line 236: log `isFinal` + character count only, never text), audit all `appLog(`/`print(` sites in `LCTMac/` for user content and strip; `macos/LCTMac/Views/SettingsView.swift` diagnostics (`buildDiagnosticsReport`, lines 369–441) — keep, now text-free by construction, plus add a redaction guard test.
- Test first: add `Tests/LCTMacTests/LogRedactionTests.swift` — run recognition-path logging with a synthetic result and assert `~/Library/Logs/LCTMac.log` (or injected log sink) contains no synthetic transcript substring; assert diagnostics report built from a seeded log excludes any seeded content markers.
- Accept: `swift test --filter LogRedactionTests`; manual `grep` of a real session log shows no spoken text.
- Commit: `fix(macos): remove transcribed text from logs and diagnostics export`

### T11. Remote Ollama HTTPS-only with opt-in
- Files: `macos/LCTMac/Models/AppSettings.swift` (lines 160–214: `ollamaURL` returns `http://` for loopback hosts, `https://` otherwise; add `var remoteOllamaOptIn: Bool = false`; add `var isLoopbackHost: Bool`), `macos/LCTMac/Views/SettingsView.swift` (lines 180–192: reject saving non-loopback host without opt-in checkbox + warning banner; show effective URL with scheme), `macos/LCTMac/Services/OllamaGuardian.swift:82` and `OllamaModelManager.swift:149` (take URL from settings instead of hardcoded `http://localhost:11434`).
- Test first: extend `Tests/LCTMacTests/OllamaServiceTests.swift` — `localhost`/`127.0.0.1`/`::1` ⇒ `http://`; any other host ⇒ `https://`; opt-in flag gates remote acceptance in the settings validator; model manager/guardian honor configured URL.
- Accept: `swift test --filter OllamaServiceTests`.
- Commit: `feat(macos): HTTPS-only remote Ollama behind explicit opt-in`

### T12. Docs, legal, onboarding, hotkey accuracy
- Files: `macos/QUICK_START.md`, `macos/USER_GUIDE.md`, `macos/USER_MANUAL.md`, root `docs/USER_GUIDE.md`, `macos/TESTING.md`, `macos/LCTMac/Views/WelcomeView.swift` (line 169 claim), new `docs/PRIVACY.md`.
- Changes: DMG install instructions match the real artifact names from T4/T5; correct "all processing on device" claim (document that ASR may use Apple network recognition); document history-off default, log text-freedom, remote-Ollama HTTPS opt-in; refresh `TESTING.md` coverage table to the real 9 test files; hotkey doc section lists the actual bindings from the global-hotkeys implementation; add `PRIVACY.md` linked from README and Settings diagnostics section; state that `LICENSE` ships in the app bundle and release assets.
- Test: link/file reference check script `bash macos/Scripts/check-docs.sh` (added here) fails on references to nonexistent files/artifacts.
- Commit: `docs(macos): align install, privacy, onboarding, and hotkey docs with shipping behavior`

## P2 — Accessibility, localization, update readiness

### T13. Accessibility pass
- Files: SwiftUI views in `macos/LCTMac/Views/` (SettingsView, HistoryView, WelcomeView, overlay views).
- Add `.accessibilityLabel`/`.accessibilityValue`/`.accessibilityHint` to all icon-only buttons, toggles, and the live-caption overlay; ensure hotkey actions are reachable/announced.
- Test first: `Tests/LCTMacTests/AccessibilityTests.swift` — instantiate key views, assert presence of accessibility modifiers via reflected view structure where feasible; remainder covered by a manual VoiceOver checklist appended to `TESTING.md`.
- Commit: `feat(macos): VoiceOver accessibility labels for key controls`

### T14. Localization readiness
- Files: introduce `macos/LCTMac/Resources/Localizable.xcstrings` (or `.strings`) with `en` base; migrate the highest-traffic user-facing strings (Settings, Welcome/onboarding, History) from hardcoded `String` to `LocalizedStringKey`; wire into `Package.swift` resources (currently `Resources` is excluded — adjust `Package.swift:19-25`).
- Test: build passes; `Tests/LCTMacTests/LocalizationTests.swift` asserts the string catalog contains all migrated keys. No second language added (readiness only).
- Commit: `feat(macos): string catalog foundation for localization`

### T15. Update readiness decision
- Deliverable: short section appended to the design doc (amendment commit allowed) evaluating Sparkle vs manual "check releases" given notarization now exists; include appcast signing requirements. Implementation explicitly deferred — this task only produces the decision record and, if Sparkle is chosen, a follow-up task list.
- Commit: `docs(macos): update-mechanism readiness decision record`

## Task ordering and dependencies

```
T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8(blocked on Apple credentials)
T9, T10, T11 independent of each other and of P0 (parallelizable)
T12 after T5 + T9 + T10 + T11 (docs must describe final behavior)
T13, T14, T15 after P1 merges; independent of each other
```

Each task = one PR-sized commit; tasks are independently testable via their named `swift test --filter` commands.

## Definition of done (program-level)

1. `v*` tag with secrets present ⇒ DMG + ZIP, Developer ID signed, hardened runtime, notarized, stapled DMG carrier (ZIP contains the stapled app; ZIP itself is not staplable), `spctl --assess` pass on the app; without secrets ⇒ workflow fails before any release asset exists.
2. `swift test` green with warnings-as-errors build; tests run before packaging in CI.
3. Fresh install has history recording OFF; logs and diagnostics contain zero spoken/translated text; remote Ollama impossible without HTTPS + opt-in.
4. All macOS docs match shipping artifacts and behavior; LICENSE in bundle and release.
5. P2 readiness items landed or explicitly deferred with a decision record.
