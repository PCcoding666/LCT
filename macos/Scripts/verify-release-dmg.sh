#!/bin/sh
# Verify a release DMG is stapled and passes Gatekeeper assessment.
#
# Usage: verify-release-dmg.sh <path/to/LCT.dmg>
#
# Contract:
#   - Exactly one argument: an existing .dmg file.
#   - `stapler validate` checks the notarization staple on the DMG.
#   - `spctl --assess --type open --verbose=4` performs the Gatekeeper
#     assessment as an opened disk image with verbose diagnostics.
#   - Verification only: never mounts, extracts, modifies, signs, notarizes,
#     or uses the network.
set -eu

if [ "$#" -ne 1 ]; then
    echo "verify-release-dmg.sh: error: expected exactly one argument (<path/to/App.dmg>), got $#" >&2
    exit 1
fi

DMG="$1"

case "$DMG" in
    *.dmg) ;;
    *)
        echo "verify-release-dmg.sh: error: expected a .dmg path, got: $DMG" >&2
        exit 1
        ;;
esac

if [ ! -f "$DMG" ]; then
    echo "verify-release-dmg.sh: error: DMG not found: $DMG" >&2
    exit 1
fi

if ! xcrun stapler validate "$DMG"; then
    echo "verify-release-dmg.sh: error: staple validation failed for $DMG" >&2
    exit 1
fi

if ! spctl --assess --type open --verbose=4 "$DMG"; then
    echo "verify-release-dmg.sh: error: Gatekeeper assessment failed for $DMG" >&2
    exit 1
fi

echo "verify-release-dmg.sh: $DMG is stapled and passes Gatekeeper assessment"
