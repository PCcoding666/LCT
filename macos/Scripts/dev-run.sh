#!/bin/bash
# dev-run.sh - the one supported way to build & run LCT during development:
# pick a stable signing identity, quit any running instance, package the app
# via package-app.sh, and launch it.
#
# Why this path is mandatory: macOS TCC ties permissions (screen recording,
# microphone, speech recognition) to the app's code signature. Running the
# bare SPM executable (swift run LCTMac / .build/.../LCTMac) attributes
# permissions to the terminal instead of LCT, and ad-hoc signatures change on
# every build — both make previously granted permissions silently stop
# matching. Only a .app signed with a stable identity keeps permissions valid
# across rebuilds and relaunches.
#
# Usage: Scripts/dev-run.sh [--no-launch] [--log]
#   --no-launch   build & sign only, do not start the app
#   --log         after launching, tail -f ~/Library/Logs/LCTMac.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="$PROJECT_DIR/LCTMac.app"
LOG_FILE="$HOME/Library/Logs/LCTMac.log"
# Overridable for tests; production packaging always goes through package-app.sh.
PACKAGE_SCRIPT="${LCT_PACKAGE_SCRIPT:-$PROJECT_DIR/package-app.sh}"

LAUNCH=1
TAIL_LOG=0
for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        --log) TAIL_LOG=1 ;;
        -h|--help)
            echo "Usage: Scripts/dev-run.sh [--no-launch] [--log]"
            exit 0
            ;;
        *)
            echo "dev-run.sh: error: unknown argument: $arg" >&2
            echo "Usage: Scripts/dev-run.sh [--no-launch] [--log]" >&2
            exit 1
            ;;
    esac
done

# --- 1. Signing identity ---------------------------------------------------

if [ "${LCT_SIGN_IDENTITY:-}" = "-" ]; then
    {
        echo "dev-run.sh: error: LCT_SIGN_IDENTITY is '-', i.e. ad-hoc signing."
        echo
        echo "  Ad-hoc signatures change on every build, so permissions granted to"
        echo "  LCT stop matching after each rebuild. Use a stable identity instead"
        echo "  (an Apple Development certificate, or run Scripts/dev-cert.sh once)."
    } >&2
    exit 1
fi

if [ -z "${LCT_SIGN_IDENTITY:-}" ]; then
    # Multiple certificates can share the same name, so pin the SHA-1 hash.
    LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 || true)
    if [ -z "$LINE" ]; then
        {
            echo "dev-run.sh: error: no Apple Development signing identity found, and LCT_SIGN_IDENTITY is not set."
            echo
            echo "  LCT needs a stable signing identity so granted permissions survive"
            echo "  rebuilds. Create an Apple Development certificate in Xcode"
            echo "  (Settings → Accounts → Manage Certificates… → + → Apple Development),"
            echo "  or run Scripts/dev-cert.sh once to create a local self-signed identity."
            echo
            echo "  Then either re-run this script (it auto-detects Apple Development"
            echo "  certificates) or pin an identity explicitly:"
            echo "    export LCT_SIGN_IDENTITY=<SHA-1 or identity name>"
            echo
            echo "Available signing identities:"
            security find-identity -v -p codesigning >&2 || true
        } >&2
        exit 1
    fi
    HASH=$(printf '%s\n' "$LINE" | awk '{print $2}')
    NAME=$(printf '%s\n' "$LINE" | awk -F'"' '{print $2}')
    export LCT_SIGN_IDENTITY="$HASH"
    echo "dev-run.sh: using signing identity $HASH ($NAME)"
    echo "  To pin it, add to ~/.zshrc:  export LCT_SIGN_IDENTITY=$HASH"
fi

# --- 2. Quit a running instance so the new build can take over --------------

if pgrep -x LCTMac >/dev/null 2>&1; then
    echo "dev-run.sh: quitting the running LCTMac…"
    osascript -e 'quit app id "com.lct.mac"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x LCTMac >/dev/null 2>&1 || break
        sleep 0.5
    done
    if pgrep -x LCTMac >/dev/null 2>&1; then
        echo "dev-run.sh: still running after 5s, force quitting…"
        pkill -x LCTMac || true
    fi
fi

# --- 3. Build + sign the .app (the only supported build path) ---------------

"$PACKAGE_SCRIPT"

# --- 4. Launch ---------------------------------------------------------------

if [ "$LAUNCH" -eq 1 ]; then
    open "$APP_BUNDLE"
    echo "dev-run.sh: launched $APP_BUNDLE"
    if [ "$TAIL_LOG" -eq 1 ]; then
        echo "dev-run.sh: tailing $LOG_FILE (Ctrl-C to stop)"
        tail -f "$LOG_FILE"
    fi
else
    echo "dev-run.sh: build complete (--no-launch): $APP_BUNDLE"
fi
