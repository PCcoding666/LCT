#!/bin/sh
# Release-sign an app bundle with a Developer ID identity.
#
# Usage: sign-app.sh <path/to/App.app>
#
# Contract:
#   - LCT_SIGN_IDENTITY must be a non-empty signing identity (Developer ID).
#   - Signs with hardened runtime (--options runtime), a secure timestamp
#     (--timestamp), and the canonical LCTMac.entitlements.
#   - Strictly verifies the resulting signature.
#   - No ad-hoc fallback: any failure aborts with a non-zero exit.
set -eu

if [ "$#" -ne 1 ]; then
    echo "sign-app.sh: error: expected exactly one argument (app bundle path), got $#" >&2
    exit 1
fi

APP="$1"

if [ -z "${LCT_SIGN_IDENTITY:-}" ]; then
    echo "sign-app.sh: error: LCT_SIGN_IDENTITY must be set to a Developer ID signing identity" >&2
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "sign-app.sh: error: app bundle not found: $APP" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(dirname "$SCRIPT_DIR")
ENTITLEMENTS="$PACKAGE_DIR/LCTMac/LCTMac.entitlements"

if [ ! -f "$ENTITLEMENTS" ]; then
    echo "sign-app.sh: error: entitlements not found: $ENTITLEMENTS" >&2
    exit 1
fi

if ! codesign --force \
    --sign "$LCT_SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    "$APP"; then
    echo "sign-app.sh: error: codesign failed for $APP with identity '$LCT_SIGN_IDENTITY'" >&2
    exit 1
fi

if ! codesign --verify --strict --deep --verbose=2 "$APP"; then
    echo "sign-app.sh: error: strict signature verification failed for $APP" >&2
    exit 1
fi

echo "sign-app.sh: signed $APP with '$LCT_SIGN_IDENTITY' and verified"
