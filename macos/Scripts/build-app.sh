#!/bin/bash
# Deprecated: this script used to build an ad-hoc-signed LCTMac.app. Ad-hoc
# signatures change on every build, which silently invalidates TCC
# permissions. It is kept only as a thin wrapper around the supported path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "build-app.sh: deprecated: use Scripts/dev-run.sh (any release/debug argument is ignored)" >&2
exec "$SCRIPT_DIR/dev-run.sh"
