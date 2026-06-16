#!/bin/bash
# build-app.sh - Build LCTMac and package as a proper .app bundle
# This is necessary because macOS TCC requires Info.plist in a proper
# .app bundle structure to read privacy usage descriptions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="LCTMac"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
BUILD_CONFIG="${1:-debug}"

echo "🔨 Building ${APP_NAME} (${BUILD_CONFIG})..."

cd "$PROJECT_DIR"

if [ "$BUILD_CONFIG" = "release" ]; then
    swift build -c release 2>&1
    EXECUTABLE_PATH=".build/release/${APP_NAME}"
else
    swift build 2>&1
    EXECUTABLE_PATH=".build/debug/${APP_NAME}"
fi

if [ ! -f "$EXECUTABLE_PATH" ]; then
    echo "❌ Build failed: executable not found at ${EXECUTABLE_PATH}"
    exit 1
fi

echo "📦 Creating app bundle: ${APP_BUNDLE}"

# Clean previous bundle
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "$EXECUTABLE_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist
cp "${PROJECT_DIR}/LCTMac/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Copy entitlements (for reference, used during codesigning)
if [ -f "${PROJECT_DIR}/LCTMac/LCTMac.entitlements" ]; then
    cp "${PROJECT_DIR}/LCTMac/LCTMac.entitlements" "${APP_BUNDLE}/Contents/Resources/"
fi

# Create PkgInfo
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Ad-hoc code sign with entitlements to enable TCC permissions
echo "🔏 Code signing..."
if [ -f "${PROJECT_DIR}/LCTMac/LCTMac.entitlements" ]; then
    codesign --force --sign - \
        --entitlements "${PROJECT_DIR}/LCTMac/LCTMac.entitlements" \
        --deep \
        "${APP_BUNDLE}" 2>&1
else
    codesign --force --sign - --deep "${APP_BUNDLE}" 2>&1
fi

echo ""
echo "✅ Build complete: ${APP_BUNDLE}"
echo ""
echo "To run:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "Or from terminal:"
echo "  ${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
