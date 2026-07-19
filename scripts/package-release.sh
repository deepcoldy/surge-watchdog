#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SIGN_IDENTITY=${SURGE_WATCHDOG_SIGN_IDENTITY:-}
NOTARY_PROFILE=${SURGE_WATCHDOG_NOTARY_PROFILE:-}
RELEASE_DIR=${SURGE_WATCHDOG_RELEASE_DIR:-"$PROJECT_DIR/build/release"}
RELEASE_APP="$RELEASE_DIR/Surge Watchdog.app"

if [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = "-" ]; then
    printf '%s\n' "SURGE_WATCHDOG_SIGN_IDENTITY must name a Developer ID Application identity." >&2
    exit 2
fi

/bin/mkdir -p "$RELEASE_DIR"
SURGE_WATCHDOG_SIGN_IDENTITY="$SIGN_IDENTITY" \
    "$SCRIPT_DIR/build-ui-helper.sh" "$RELEASE_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$RELEASE_APP"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$RELEASE_APP/Contents/Info.plist")
RELEASE_ZIP="$RELEASE_DIR/Surge-Watchdog-$version.zip"
/bin/rm -f "$RELEASE_ZIP"
/usr/bin/ditto -c -k --keepParent "$RELEASE_APP" "$RELEASE_ZIP"

if [ -z "$NOTARY_PROFILE" ]; then
    printf '%s\n' "Created signed archive: $RELEASE_ZIP"
    printf '%s\n' "Set SURGE_WATCHDOG_NOTARY_PROFILE to submit and staple it automatically."
    exit 0
fi

/usr/bin/xcrun notarytool submit "$RELEASE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$RELEASE_APP"
/usr/bin/xcrun stapler validate "$RELEASE_APP"

# The ticket is stapled to the app, not to the submitted ZIP. Recreate the
# distribution archive so offline Gatekeeper checks can see the ticket.
/bin/rm -f "$RELEASE_ZIP"
/usr/bin/ditto -c -k --keepParent "$RELEASE_APP" "$RELEASE_ZIP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$RELEASE_APP"
printf '%s\n' "Created signed and notarized archive: $RELEASE_ZIP"
