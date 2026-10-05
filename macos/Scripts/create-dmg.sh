#!/bin/sh
# Package a signed .app bundle into a compressed UDZO disk image.
#
# Usage: create-dmg.sh <path/to/signed App.app> <output.dmg>
#
# Contract:
#   - Exactly two arguments: an existing app bundle and an output DMG path.
#   - Strict-verify the app signature before packaging.
#   - Stage a user-friendly volume: the app plus an Applications symlink.
#   - Create the image with hdiutil as compressed UDZO.
#   - Clean up the temporary staging directory on any exit path.
#   - Never sign the DMG; signing is the app's concern (see sign-app.sh).
set -eu

if [ "$#" -ne 2 ]; then
    echo "create-dmg.sh: error: expected exactly two arguments (<signed App.app> <output.dmg>), got $#" >&2
    exit 1
fi

APP="$1"
DMG="$2"

if [ -e "$DMG" ]; then
    echo "create-dmg.sh: error: output path already exists, refusing to overwrite: $DMG" >&2
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "create-dmg.sh: error: app bundle not found: $APP" >&2
    exit 1
fi

if ! codesign --verify --strict --deep --verbose=2 "$APP"; then
    echo "create-dmg.sh: error: app signature verification failed: $APP" >&2
    exit 1
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/create-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT INT TERM

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if ! hdiutil create -volname "LCT" -srcfolder "$STAGING" -format UDZO "$DMG"; then
    echo "create-dmg.sh: error: hdiutil failed to create $DMG" >&2
    exit 1
fi

echo "create-dmg.sh: created $DMG from $APP"
