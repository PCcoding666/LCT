# Repository Guidelines

## Project scope and layout

LCT's default branch (`master`) is the macOS project. Production Swift code is
under `macos/LCTMac/`, tests under `macos/Tests/LCTMacTests/`, and helper scripts
under `macos/Scripts/`. User documentation lives in `docs/` and `macos/`;
translation benchmark tooling and fixtures live in `benchmark/`.

Windows is archived at the `windows-archive-2026-11-04` tag. See
`docs/WINDOWS_ARCHIVE.md` for the source, release, and restoration references.
Do not reintroduce Windows code or its CI into the active branch as part of
routine macOS work.

## Build, run, and test

- `cd macos && swift build`: debug build.
- `cd macos && ./Scripts/dev-run.sh`: build, sign, and launch locally. Never
  use `swift run` or the raw `.build/.../LCTMac` executable to launch the app;
  macOS privacy permissions depend on the packaged app's signing identity.
- `cd macos && ./Scripts/run_tests.sh`: debug, release, warnings-as-errors,
  and XCTest validation; run before macOS PRs.
- `cd macos && ./package-app.sh`: package the app.
- `python3 benchmark/run_benchmark.py --models qwen3.5:4b-mlx`: translation
  benchmarks; requires Ollama at `http://localhost:11434`.

## Conventions and validation

Use 4-space indentation, PascalCase types, and lowerCamelCase properties and
methods. Keep files near their feature area (`Views`, `ViewModels`, `Services`,
`Models`, `Utils`). Prefer `@MainActor` for views and view models updating UI.
Use deterministic XCTest fixtures and names such as
`test<Feature>_<Scenario>_<ExpectedResult>()`.

Use scoped Conventional Commits, for example `fix(macos): ...` or
`refactor(repo): ...`. PRs should explain the resulting behavior, link an issue
when available, report validation, and include screenshots or recordings for
visible UI changes. State any required OS, permission, or Ollama setup.
Build and unit-test results do not establish live audio or GUI E2E acceptance.

## Delivery and local data

macOS CI builds and tests automatically; signing, notarization, and DMG upload
run only through the manual delivery job. Merging is not releasing.
Do not commit build outputs, logs, secrets, or machine-specific agent settings.
Treat captions, transcripts, and benchmark outputs as potentially sensitive.
Keep endpoints configurable and never hard-code credentials.
