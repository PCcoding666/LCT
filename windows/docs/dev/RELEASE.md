# Releasing the Windows app

One tag, one version number, one place for release notes.

## How the pieces fit

- `<VersionPrefix>` in `windows/LiveCaptionsTranslator.csproj` is the only place
  the version is typed. The executable's assembly, file and product versions are
  generated from it (`GenerateAssemblyInfo=true`); `src/AssemblyInfo.cs` holds
  only the WPF `ThemeInfo` attribute.
- `.github/workflows/windows-build.yml` builds every push or PR that touches
  `windows/` as `X.Y.Z-ci.N` and uploads installer, portable executables and
  checksums as a workflow artifact. A tag `vX.Y.Z` builds `X.Y.Z` and publishes
  the GitHub Release. The job fails before publishing when the tag does not
  equal `<VersionPrefix>`, or when `windows/CHANGELOG.md` has no `## [X.Y.Z]`
  section.
- Release notes = that changelog section + `docs/dev/release-notes-footer.md`
  (download table, requirements, SmartScreen note). `{{VERSION}}` in the footer
  is replaced at release time.

## Checklist

1. Bump `<VersionPrefix>` in `windows/LiveCaptionsTranslator.csproj`.
2. In `windows/CHANGELOG.md`, turn `## [X.Y.Z] - Unreleased` into the release
   date and write what changed for users.
3. Commit as `chore(windows): release vX.Y.Z`, open a PR and wait for
   "Windows Build and Release" to pass. Download the artifact and smoke-test the
   installer on a Windows machine when the change touches startup, Live Captions
   integration or the installer itself.
4. Merge to `master`, then tag the merge commit:

   ```bash
   git tag vX.Y.Z <merge-commit>
   git push origin vX.Y.Z
   ```

5. Check the release page: five executables plus `SHA256SUMS.txt`, marked
   Latest, notes rendered as intended.

## When something goes wrong

- Wrong number or missing changelog section: the workflow stops before
  publishing. Fix the files, delete the tag locally and on origin, tag again.
- A bad build got published: delete the GitHub release and the tag, bump the
  patch number and release again. Never reuse a version number.

## Not automated yet

- Code signing. The binaries are unsigned, so SmartScreen warns on first run.
  With a code-signing certificate, add `signtool` steps after `dotnet publish`
  and after `makensis`.
- Tags are shared with the macOS app in this monorepo. The macOS release job
  runs through `workflow_dispatch` only, so `v*` tags are Windows-only for now.

## Local installer build

`scripts\build\build-installer.bat --version X.Y.Z` publishes and packs the
installer with the NSIS compiler installed locally. The version defaults to the
csproj `<VersionPrefix>`; pass `--suffix beta` for a pre-release build.
