#!/bin/bash
# Deprecated: this script used to sign the bare .build/debug/LCTMac
# executable. Running a bare executable makes TCC attribute permissions to the
# terminal instead of LCT. It is kept only as a thin wrapper around the
# supported path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "build_signed.sh: deprecated: use Scripts/dev-run.sh" >&2
exec "$SCRIPT_DIR/dev-run.sh"
