#!/bin/bash
# Package LCTMac as a proper .app bundle.
# Running the bare SPM executable makes TCC attribute permission requests to the
# launching app (Terminal/Claude/etc.), which crashes with SIGABRT when that app
# lacks the usage descriptions. A real bundle owns its own TCC identity.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_PATH=$(swift build -c release --show-bin-path)

APP=LCTMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LCTMac" "$APP/Contents/MacOS/LCTMac"
cp LCTMac/Info.plist "$APP/Contents/Info.plist"
cp LCTMac/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Stamp version from the manually maintained VERSION file (or RELEASE_VERSION
# env var) plus integer BUILD_NUMBER, so builds are distinguishable.
RELEASE_VERSION="${RELEASE_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
Scripts/version-stamp.sh "$APP/Contents/Info.plist"

# Release signing goes exclusively through Scripts/sign-app.sh: Developer ID
# identity from LCT_SIGN_IDENTITY, hardened runtime, secure timestamp,
# canonical entitlements, and strict verification. No ad-hoc fallback.
Scripts/sign-app.sh "$APP"
echo "Packaged $APP $RELEASE_VERSION ($BUILD_NUMBER), signed as '$LCT_SIGN_IDENTITY' — launch with: open $APP"
