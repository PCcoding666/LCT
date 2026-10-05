#!/bin/sh
# Stamp version placeholders in an Info.plist with the release version and build number.
#
# Usage: version-stamp.sh <path/to/Info.plist>
#
# Version source: RELEASE_VERSION env var if set, otherwise the manually
# maintained VERSION file at the package root.
# Build number:   BUILD_NUMBER env var (must be an integer, defaults to 0).
set -eu

PLIST="${1:?usage: version-stamp.sh <path/to/Info.plist>}"

if [ ! -f "$PLIST" ]; then
    echo "error: Info.plist not found: $PLIST" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PACKAGE_DIR=$(dirname "$SCRIPT_DIR")

if [ -n "${RELEASE_VERSION:-}" ]; then
    VERSION=$RELEASE_VERSION
else
    VERSION=$(tr -d '[:space:]' < "$PACKAGE_DIR/VERSION")
fi

if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: version must be strict x.y.z semver, got '$VERSION'" >&2
    exit 1
fi

BUILD_NUMBER="${BUILD_NUMBER:-0}"
case "$BUILD_NUMBER" in
    ''|*[!0-9]*)
        echo "error: BUILD_NUMBER must be an integer, got '$BUILD_NUMBER'" >&2
        exit 1
        ;;
esac

sed -i '' \
    -e "s/__LCT_VERSION__/$VERSION/" \
    -e "s/__LCT_BUILD__/$BUILD_NUMBER/" \
    "$PLIST"
