# Changelog: LCT for Windows

User-facing changes to the Windows app, newest first. The section whose heading
matches a release tag `vX.Y.Z` becomes the body of that GitHub Release (see
[docs/dev/RELEASE.md](docs/dev/RELEASE.md)), so write for the person installing
the app, not for the commit log.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.4] - Unreleased

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
