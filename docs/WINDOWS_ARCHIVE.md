# Windows archive

As of 2026-11-04, LCT's default branch (`master`) is maintained for macOS.
The Windows source, installer scripts, tests, and documentation are preserved
in Git rather than maintained alongside the active macOS project.

## Preserved snapshots

| Snapshot | Reference | Contents |
| --- | --- | --- |
| Latest Windows development | [`windows-archive-2026-11-04`](https://github.com/PCcoding666/LCT/tree/windows-archive-2026-11-04/windows) | Commit `75fa1a3cd1a6bdff483c4f2ad079d72ddbf8ffa6`, including all four commits from [PR #24](https://github.com/PCcoding666/LCT/pull/24): native capture, on-device Whisper recognition, and the revised UI. |
| Last Windows release | [`v1.0.4`](https://github.com/PCcoding666/LCT/releases/tag/v1.0.4) | The released Windows 1.x implementation and downloadable release artifacts. |

The development snapshot is **not a released or fully validated Windows 2.0
build**. PR #24 records remaining manual Windows verification. Archiving it
does not merge or certify that implementation.

The existing `feat/windows-native-capture` branch is retained. Use the archive
tag above for a fixed snapshot; a development branch can change over time.
Earlier commits, tags, and releases are retained.

## Inspect or restore the source

Fetch the archive and open it in a separate worktree:

```bash
git fetch origin tag windows-archive-2026-11-04
git worktree add --detach ../LCT-windows-archive windows-archive-2026-11-04
```

The Windows project is under `../LCT-windows-archive/windows/`. Its README,
tests, and build/release instructions describe that archived version.
The archive also contains the original `.github/workflows/windows-build.yml`
for reference. That workflow is no longer present on the active default branch.

To resume development later, create a new branch from the archive tag and
review its CI and release settings before pushing changes. The historical
Windows workflow can build on branch pushes and publish on `v*` tags; the
archive tag deliberately does not use that release-tag prefix.
