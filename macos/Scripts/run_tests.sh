#!/bin/bash
# LCT macOS test runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cd "$PROJECT_DIR"

if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

echo "LCT macOS test runner"
echo "===================="
echo "Project: $PROJECT_DIR"
echo "Developer dir: ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo unknown)}"
echo ""

run_step() {
    local name="$1"
    shift

    echo -e "${YELLOW}==>${NC} $name"
    "$@"
    echo -e "${GREEN}✓${NC} $name"
    echo ""
}

run_step "swift build" swift build
run_step "swift build -c release" swift build -c release
run_step "swift build with warnings as errors" swift build -Xswiftc -warnings-as-errors
run_step "swift test" swift test

if curl -fsS --max-time 3 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Ollama service reachable at http://localhost:11434"
else
    echo -e "${YELLOW}!${NC} Ollama service not reachable. App can auto-start it, but live integration tests were skipped."
fi
