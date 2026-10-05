#!/bin/sh
# Notarize and staple a final release DMG.
#
# Usage: notarize-dmg.sh <path/to/LCT.dmg>
#
# Contract:
#   - Exactly one argument: an existing .dmg file (never a ZIP).
#   - LCT_NOTARY_PROFILE must name a `notarytool store-credentials` keychain
#     profile; Apple credentials never appear on the command line.
#   - Submit the DMG with --wait, then staple and validate the same DMG.
#   - Never codesign the DMG; signing happens earlier (see sign-app.sh).
set -eu

if [ "$#" -ne 1 ]; then
    echo "notarize-dmg.sh: error: expected exactly one argument (<path/to/App.dmg>), got $#" >&2
    exit 1
fi

if [ -z "${LCT_NOTARY_PROFILE:-}" ]; then
    echo "notarize-dmg.sh: error: LCT_NOTARY_PROFILE must be set to a notarytool keychain profile name" >&2
    exit 1
fi

DMG="$1"

case "$DMG" in
    *.dmg) ;;
    *)
        echo "notarize-dmg.sh: error: expected a .dmg path, got: $DMG" >&2
        exit 1
        ;;
esac

if [ ! -f "$DMG" ]; then
    echo "notarize-dmg.sh: error: DMG not found: $DMG" >&2
    exit 1
fi

if ! xcrun notarytool submit "$DMG" --wait --keychain-profile "$LCT_NOTARY_PROFILE"; then
    echo "notarize-dmg.sh: error: notarization failed for $DMG" >&2
    exit 1
fi

if ! xcrun stapler staple "$DMG"; then
    echo "notarize-dmg.sh: error: stapling failed for $DMG" >&2
    exit 1
fi

if ! xcrun stapler validate "$DMG"; then
    echo "notarize-dmg.sh: error: staple validation failed for $DMG" >&2
    exit 1
fi

echo "notarize-dmg.sh: notarized, stapled, and validated $DMG"
