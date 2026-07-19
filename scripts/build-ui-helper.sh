#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE_DIR="$PROJECT_DIR/app/SurgeWatchdogUI"
ICON_SOURCE_B64="$SOURCE_DIR/Assets/AppIconMaster-v2.jpg.b64"
OUTPUT_APP=${1:-"$PROJECT_DIR/build/Surge Watchdog.app"}
SIGN_IDENTITY=${SURGE_WATCHDOG_SIGN_IDENTITY:-}
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
fi
TEMPORARY_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/surge-watchdog-ui.XXXXXX")

cleanup() {
    /bin/rm -rf "$TEMPORARY_DIR"
}
trap cleanup EXIT HUP INT TERM

TEMPORARY_APP="$TEMPORARY_DIR/Surge Watchdog.app"
/bin/mkdir -p "$TEMPORARY_APP/Contents/MacOS"
/bin/mkdir -p "$TEMPORARY_APP/Contents/Resources"
/usr/bin/install -m 0644 "$SOURCE_DIR/Info.plist" "$TEMPORARY_APP/Contents/Info.plist"

ICON_SOURCE="$TEMPORARY_DIR/AppIconMaster.jpg"
PREPARED_ICON="$TEMPORARY_DIR/AppIcon.png"
ICONSET="$TEMPORARY_DIR/AppIcon.iconset"
/usr/bin/base64 -D -i "$ICON_SOURCE_B64" -o "$ICON_SOURCE"
/usr/bin/xcrun swift "$PROJECT_DIR/scripts/prepare-app-icon.swift" "$ICON_SOURCE" "$PREPARED_ICON"
/bin/mkdir -p "$ICONSET"
for icon_spec in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'; do
    icon_size=${icon_spec%% *}
    icon_name=${icon_spec#* }
    /usr/bin/sips -z "$icon_size" "$icon_size" "$PREPARED_ICON" \
        --out "$ICONSET/$icon_name" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$TEMPORARY_APP/Contents/Resources/AppIcon.icns"

/usr/bin/xcrun swiftc -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework SwiftUI \
    "$SOURCE_DIR/main.swift" \
    "$SOURCE_DIR/ProductApp.swift" \
    -o "$TEMPORARY_APP/Contents/MacOS/Surge Watchdog"

/usr/bin/plutil -lint "$TEMPORARY_APP/Contents/Info.plist" >/dev/null
if [ "$SIGN_IDENTITY" = "-" ]; then
    /usr/bin/codesign --force --sign - \
        --identifier com.shenhan.surge-watchdog.ui "$TEMPORARY_APP" >/dev/null
    printf '%s\n' "Signed with an ad-hoc identity (local development only)"
else
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
        --identifier com.shenhan.surge-watchdog.ui \
        --options runtime \
        --timestamp \
        "$TEMPORARY_APP" >/dev/null
    printf '%s\n' "Signed with $SIGN_IDENTITY (Hardened Runtime enabled)"
fi
/usr/bin/codesign --verify --deep --strict "$TEMPORARY_APP"

/bin/mkdir -p "$(dirname -- "$OUTPUT_APP")"
/bin/rm -rf "$OUTPUT_APP"
/usr/bin/ditto "$TEMPORARY_APP" "$OUTPUT_APP"

printf '%s\n' "Built $OUTPUT_APP"
