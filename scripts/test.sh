#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WATCHDOG="$PROJECT_DIR/bin/surge-watchdog"
PLIST_TEMPLATE="$PROJECT_DIR/launchd/com.shenhan.surge-watchdog.plist.in"
APP_PLIST_TEMPLATE="$PROJECT_DIR/launchd/com.shenhan.surge-watchdog.app.plist.in"
TEST_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/surge-watchdog-test.XXXXXX")

cleanup() {
    /bin/rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

/bin/sh -n "$WATCHDOG"
/bin/sh -n "$PROJECT_DIR/scripts/install.sh"
/bin/sh -n "$PROJECT_DIR/scripts/uninstall.sh"
/bin/sh -n "$PROJECT_DIR/scripts/build-ui-helper.sh"
/bin/sh -n "$PROJECT_DIR/scripts/package-release.sh"
"$PROJECT_DIR/scripts/build-ui-helper.sh" "$TEST_DIR/Surge Watchdog.app" >/dev/null
/usr/bin/codesign --verify --deep --strict "$TEST_DIR/Surge Watchdog.app"
helper_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$TEST_DIR/Surge Watchdog.app/Contents/Info.plist")
[ "$helper_bundle_id" = "com.shenhan.surge-watchdog.ui" ]
helper_display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
    "$TEST_DIR/Surge Watchdog.app/Contents/Info.plist")
[ "$helper_display_name" = "Surge Watchdog" ]
[ -x "$TEST_DIR/Surge Watchdog.app/Contents/MacOS/Surge Watchdog" ]
[ -r "$TEST_DIR/Surge Watchdog.app/Contents/Resources/AppIcon.icns" ]
[ -x "$TEST_DIR/Surge Watchdog.app/Contents/Resources/Runtime/bin/surge-watchdog" ]
[ -r "$TEST_DIR/Surge Watchdog.app/Contents/Resources/Runtime/config.example" ]
test_sdk=${SURGE_WATCHDOG_SWIFT_SDK:-$(/usr/bin/xcrun --show-sdk-path)}
/usr/bin/xcrun swiftc -sdk "$test_sdk" \
    "$PROJECT_DIR/app/SurgeWatchdogUI/RuntimeInstaller.swift" \
    "$PROJECT_DIR/tests/RuntimeInstallerTests.swift" -o "$TEST_DIR/runtime-tests"
"$TEST_DIR/runtime-tests" "$TEST_DIR/Surge Watchdog.app/Contents/Resources" \
    "$TEST_DIR/install with spaces & symbols"
minimum_macos=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$TEST_DIR/Surge Watchdog.app/Contents/Info.plist")
binary_macos=$(/usr/bin/otool -l "$TEST_DIR/Surge Watchdog.app/Contents/MacOS/Surge Watchdog" | \
    /usr/bin/awk '/ minos / {print $2; exit}')
[ "$minimum_macos" = "$binary_macos" ]
helper_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
    "$TEST_DIR/Surge Watchdog.app/Contents/Info.plist")
[ "$helper_icon_name" = "AppIcon" ]
/usr/bin/codesign -d --verbose=4 "$TEST_DIR/Surge Watchdog.app" 2>&1 | \
    /usr/bin/grep -q '^Signature=adhoc$'
/usr/bin/grep -q 'statusItem.menu = statusMenu' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"
/usr/bin/grep -q '完全退出 Surge Watchdog' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"
/usr/bin/grep -q 'tccutil' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"
/usr/bin/grep -q 'if windowController == nil' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"
/usr/bin/grep -q 'windowController = nil' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"
main_window_occurrences=$(/usr/bin/grep -c 'createMainWindow()' \
    "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift")
[ "$main_window_occurrences" -eq 2 ]
if /usr/bin/grep -q '\.pickerStyle(.segmented)' "$PROJECT_DIR/app/SurgeWatchdogUI/ProductApp.swift"; then
    printf '%s\n' "Native segmented Picker must not be used because it can enter a SwiftUI layout loop" >&2
    exit 1
fi
/usr/bin/plutil -lint "$PLIST_TEMPLATE" >/dev/null
/usr/bin/plutil -lint "$APP_PLIST_TEMPLATE" >/dev/null

rendered_app_plist="$TEST_DIR/com.shenhan.surge-watchdog.app.plist"
/usr/bin/sed \
    -e "s|__APP_BUNDLE__|$TEST_DIR/Surge Watchdog.app|g" \
    "$APP_PLIST_TEMPLATE" > "$rendered_app_plist"
/usr/bin/plutil -lint "$rendered_app_plist" >/dev/null

rendered_plist="$TEST_DIR/com.shenhan.surge-watchdog.plist"
/usr/bin/sed \
    -e "s|__WATCHDOG_BIN__|$TEST_DIR/bin/surge-watchdog|g" \
    -e "s|__CONFIG_FILE__|$TEST_DIR/config|g" \
    -e "s|__LOG_FILE__|$TEST_DIR/watchdog.log|g" \
    -e "s|__LOG_DIRECTORY__|$TEST_DIR/logs|g" \
    -e "s|__ERROR_LOG_FILE__|$TEST_DIR/watchdog.error.log|g" \
    "$PLIST_TEMPLATE" > "$rendered_plist"
/usr/bin/plutil -lint "$rendered_plist" >/dev/null

/usr/bin/install -m 0644 "$PROJECT_DIR/config.example" "$TEST_DIR/config"

for required_key in SURGE_CLI_PATH CLI_STOP_TIMEOUT_SECONDS PROCESS_STOP_TIMEOUT_SECONDS \
    RECOVERY_VERIFY_SECONDS RECOVERY_VERIFY_INTERVAL_SECONDS UI_HELPER_TIMEOUT_SECONDS \
    ENABLE_UI_FALLBACK MONITORING_ENABLED LOG_RETENTION_DAYS; do
    /usr/bin/grep -q "^${required_key}=" "$TEST_DIR/config"
done

SURGE_WATCHDOG_CONFIG="$TEST_DIR/config" \
SURGE_WATCHDOG_STATE_DIR="$TEST_DIR/state" \
SURGE_WATCHDOG_FORCE_HEALTH=healthy \
SURGE_WATCHDOG_DRY_RUN=1 \
    "$WATCHDOG" --status >/dev/null

if SURGE_WATCHDOG_CONFIG="$TEST_DIR/config" \
    SURGE_WATCHDOG_STATE_DIR="$TEST_DIR/state" \
    SURGE_WATCHDOG_FORCE_HEALTH=unhealthy \
    SURGE_WATCHDOG_DRY_RUN=1 \
        "$WATCHDOG" --status >/dev/null 2>&1; then
    printf '%s\n' "Expected unhealthy status to fail" >&2
    exit 1
fi

gateway_state="$TEST_DIR/server.json"
gateway_config="$TEST_DIR/gateway-config"
printf '%s\n' '{"useVMNET":true,"useDHCP":true,"vmnetIP":"192.168.10.88","interface":"en9"}' > "$gateway_state"
printf '%s\n' \
    "SURGE_GATEWAY_STATE_FILE=$gateway_state" \
    "SURGE_DHCP_PID_FILE=$TEST_DIR/dhcpd.pid" \
    'CHECK_PROCESS=0' \
    'CHECK_GATEWAY_MODE=1' \
    'CHECK_DNS=0' > "$gateway_config"

gateway_output=$(SURGE_WATCHDOG_CONFIG="$gateway_config" \
    SURGE_WATCHDOG_FORCE_DHCP_PROCESS=healthy \
    SURGE_WATCHDOG_SKIP_ARP=1 \
    "$WATCHDOG" --status)
printf '%s\n' "$gateway_output" | /usr/bin/grep -q 'Gateway VM 192.168.10.88 on en9'

printf '%s\n' '{"useVMNET":false,"useDHCP":true,"vmnetIP":"192.168.10.88","interface":"en9"}' > "$gateway_state"
if SURGE_WATCHDOG_CONFIG="$gateway_config" \
    SURGE_WATCHDOG_FORCE_DHCP_PROCESS=healthy \
    SURGE_WATCHDOG_SKIP_ARP=1 \
    "$WATCHDOG" --status >/dev/null 2>&1; then
    printf '%s\n' "Expected disabled Gateway VM to fail" >&2
    exit 1
fi

printf '%s\n' '{"useVMNET":true,"useDHCP":true,"vmnetIP":"192.168.10.89","interface":"en9"}' > "$gateway_state"
if SURGE_WATCHDOG_CONFIG="$gateway_config" \
    SURGE_WATCHDOG_FORCE_DHCP_PROCESS=unhealthy \
    SURGE_WATCHDOG_SKIP_ARP=1 \
    "$WATCHDOG" --status >/dev/null 2>&1; then
    printf '%s\n' "Expected stopped DHCP process to fail" >&2
    exit 1
fi

printf '%s\n' "All checks passed"
