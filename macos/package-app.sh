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

# Stamp version from git so builds are distinguishable
VERSION=$(git describe --tags 2>/dev/null || echo "0.1.0")
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo "1")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Packaged $APP $VERSION ($BUILD) — launch with: open $APP"
