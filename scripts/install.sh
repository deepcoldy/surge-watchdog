#!/bin/sh

set -eu

LABEL="com.shenhan.surge-watchdog"
APP_LABEL="com.shenhan.surge-watchdog.app"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_DIR="$HOME/Library/Application Support/surge-watchdog"
INSTALL_BIN="$INSTALL_DIR/bin/surge-watchdog"
BUILD_UI_APP="$PROJECT_DIR/build/Surge Watchdog.app"
INSTALL_UI_APP="$HOME/Applications/Surge Watchdog.app"
OLD_UI_APP="$HOME/Applications/Surge Watchdog UI.app"
CONFIG_FILE="$INSTALL_DIR/config"
LOG_DIR="$HOME/Library/Logs"
DAILY_LOG_DIR="$LOG_DIR/Surge Watchdog"
LOG_FILE="$LOG_DIR/surge-watchdog.log"
ERROR_LOG_FILE="$LOG_DIR/surge-watchdog.error.log"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/$LABEL.plist"
APP_LAUNCH_AGENT_FILE="$LAUNCH_AGENT_DIR/$APP_LABEL.plist"
LAUNCH_DOMAIN="gui/$(/usr/bin/id -u)"

/bin/mkdir -p "$INSTALL_DIR/bin" "$HOME/Applications" "$LOG_DIR" "$DAILY_LOG_DIR" "$LAUNCH_AGENT_DIR"
/usr/bin/install -m 0755 "$PROJECT_DIR/bin/surge-watchdog" "$INSTALL_BIN"

"$PROJECT_DIR/scripts/build-ui-helper.sh" "$BUILD_UI_APP"
built_ui_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$BUILD_UI_APP/Contents/Info.plist")
built_ui_cdhash=$(/usr/bin/codesign -d --verbose=4 "$BUILD_UI_APP" 2>&1 | \
    /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')
built_ui_team=$(/usr/bin/codesign -d --verbose=4 "$BUILD_UI_APP" 2>&1 | \
    /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
installed_ui_version=""
installed_ui_cdhash=""
installed_ui_team=""
app_was_updated=0
if [ -r "$INSTALL_UI_APP/Contents/Info.plist" ]; then
    installed_ui_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$INSTALL_UI_APP/Contents/Info.plist" 2>/dev/null || true)
    installed_ui_cdhash=$(/usr/bin/codesign -d --verbose=4 "$INSTALL_UI_APP" 2>&1 | \
        /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')
    installed_ui_team=$(/usr/bin/codesign -d --verbose=4 "$INSTALL_UI_APP" 2>&1 | \
        /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')
fi
if [ -n "$installed_ui_team" ] && [ "$installed_ui_team" != "not set" ] && \
   { [ -z "$built_ui_team" ] || [ "$built_ui_team" = "not set" ]; }; then
    printf '%s\n' "Refusing to replace a signed app with an ad-hoc build." >&2
    printf '%s\n' "Set SURGE_WATCHDOG_SIGN_IDENTITY to the installed signing identity." >&2
    exit 1
fi
if [ "$installed_ui_version" = "$built_ui_version" ] && \
   [ -n "$installed_ui_cdhash" ] && [ "$installed_ui_cdhash" = "$built_ui_cdhash" ]; then
    printf '%s\n' "Preserved authorized app version $installed_ui_version"
else
    app_was_updated=1
    temporary_ui_app="$HOME/Applications/.Surge Watchdog.app.tmp.$$"
    /bin/rm -rf "$temporary_ui_app"
    /usr/bin/ditto "$BUILD_UI_APP" "$temporary_ui_app"
    /usr/bin/codesign --verify --deep --strict "$temporary_ui_app"
    /bin/rm -rf "$INSTALL_UI_APP"
    /bin/mv "$temporary_ui_app" "$INSTALL_UI_APP"
    printf '%s\n' "Installed Surge Watchdog app: $INSTALL_UI_APP"
fi

if [ "$app_was_updated" = "1" ]; then
    /bin/rm -f "$INSTALL_DIR/state/ui_probe_success_epoch"
fi

# The product app replaces the old one-shot Helper name.
if [ -d "$OLD_UI_APP" ]; then
    /bin/rm -rf "$OLD_UI_APP"
    printf '%s\n' "Removed obsolete app: $OLD_UI_APP"
fi

# Remove the obsolete osascript-based helper from versions before 1.0.
/bin/rm -f "$INSTALL_DIR/lib/surge-ui-fallback.applescript"
/bin/rmdir "$INSTALL_DIR/lib" 2>/dev/null || true

if [ ! -f "$CONFIG_FILE" ]; then
    /usr/bin/install -m 0644 "$PROJECT_DIR/config.example" "$CONFIG_FILE"
    printf '%s\n' "Created configuration: $CONFIG_FILE"
else
    printf '%s\n' "Preserved existing configuration: $CONFIG_FILE"
fi

append_config_default() {
    config_key=$1
    config_value=$2
    if ! /usr/bin/grep -q "^${config_key}=" "$CONFIG_FILE"; then
        printf '%s\n' "${config_key}=${config_value}" >> "$CONFIG_FILE"
        printf '%s\n' "Added ${config_key}=${config_value} to the existing configuration"
    fi
}

append_config_default CHECK_GATEWAY_MODE 1
append_config_default SURGE_CLI_PATH /Applications/Surge.app/Contents/Applications/surge-cli
append_config_default CLI_STOP_TIMEOUT_SECONDS 8
append_config_default PROCESS_STOP_TIMEOUT_SECONDS 10
append_config_default RECOVERY_VERIFY_SECONDS 60
append_config_default RECOVERY_VERIFY_INTERVAL_SECONDS 5
append_config_default UI_HELPER_TIMEOUT_SECONDS 45
append_config_default ENABLE_UI_FALLBACK 0
append_config_default MONITORING_ENABLED 1
append_config_default LOG_RETENTION_DAYS 7
append_config_default LAUNCH_AT_LOGIN 1

if [ "$app_was_updated" = "1" ] && /usr/bin/grep -q '^ENABLE_UI_FALLBACK=1$' "$CONFIG_FILE"; then
    temporary_config="$CONFIG_FILE.tmp.$$"
    /usr/bin/sed 's/^ENABLE_UI_FALLBACK=1$/ENABLE_UI_FALLBACK=0/' \
        "$CONFIG_FILE" > "$temporary_config"
    /bin/mv "$temporary_config" "$CONFIG_FILE"
    /bin/chmod 0644 "$CONFIG_FILE"
    printf '%s\n' "Disabled UI fallback until the updated app passes a new safety probe"
fi

if /usr/bin/grep -q '^SURGE_UI_HELPER_APP=.*/Surge Watchdog UI.app$' "$CONFIG_FILE"; then
    temporary_config="$CONFIG_FILE.tmp.$$"
    /usr/bin/sed "s|^SURGE_UI_HELPER_APP=.*$|SURGE_UI_HELPER_APP=$INSTALL_UI_APP|" \
        "$CONFIG_FILE" > "$temporary_config"
    /bin/mv "$temporary_config" "$CONFIG_FILE"
    /bin/chmod 0644 "$CONFIG_FILE"
    printf '%s\n' "Migrated the UI app path to $INSTALL_UI_APP"
elif ! /usr/bin/grep -q '^SURGE_UI_HELPER_APP=' "$CONFIG_FILE"; then
    printf '%s\n' "SURGE_UI_HELPER_APP=$INSTALL_UI_APP" >> "$CONFIG_FILE"
fi

printf '%s\n' "Running a read-only health check before enabling the watchdog..."
if ! SURGE_WATCHDOG_CONFIG="$CONFIG_FILE" "$INSTALL_BIN" --status; then
    printf '%s\n' "Preflight failed; the LaunchAgent was not installed or changed." >&2
    printf '%s\n' "Keep Surge running, then adjust $CONFIG_FILE if a check is unsupported." >&2
    exit 1
fi

temporary_plist="$LAUNCH_AGENT_FILE.tmp.$$"
/usr/bin/sed \
    -e "s|__WATCHDOG_BIN__|$INSTALL_BIN|g" \
    -e "s|__CONFIG_FILE__|$CONFIG_FILE|g" \
    -e "s|__LOG_FILE__|$LOG_FILE|g" \
    -e "s|__LOG_DIRECTORY__|$DAILY_LOG_DIR|g" \
    -e "s|__ERROR_LOG_FILE__|$ERROR_LOG_FILE|g" \
    "$PROJECT_DIR/launchd/$LABEL.plist.in" > "$temporary_plist"
/usr/bin/plutil -lint "$temporary_plist" >/dev/null
/bin/mv "$temporary_plist" "$LAUNCH_AGENT_FILE"
/bin/chmod 0644 "$LAUNCH_AGENT_FILE"

/bin/launchctl bootout "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/sleep 1
if ! /bin/launchctl bootstrap "$LAUNCH_DOMAIN" "$LAUNCH_AGENT_FILE"; then
    printf '%s\n' "Initial LaunchAgent bootstrap failed; retrying once..." >&2
    /bin/sleep 2
    /bin/launchctl bootstrap "$LAUNCH_DOMAIN" "$LAUNCH_AGENT_FILE"
fi
/bin/launchctl kickstart -k "$LAUNCH_DOMAIN/$LABEL"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_UI_APP/Contents/Info.plist" \
    > "$INSTALL_DIR/runtime-version"

if /usr/bin/grep -q '^LAUNCH_AT_LOGIN=1$' "$CONFIG_FILE"; then
    temporary_app_plist="$APP_LAUNCH_AGENT_FILE.tmp.$$"
    /usr/bin/sed \
        -e "s|__APP_BUNDLE__|$INSTALL_UI_APP|g" \
        "$PROJECT_DIR/launchd/$APP_LABEL.plist.in" > "$temporary_app_plist"
    /usr/bin/plutil -lint "$temporary_app_plist" >/dev/null
    /bin/mv "$temporary_app_plist" "$APP_LAUNCH_AGENT_FILE"
    /bin/chmod 0644 "$APP_LAUNCH_AGENT_FILE"
    /bin/launchctl bootout "$LAUNCH_DOMAIN/$APP_LABEL" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "$LAUNCH_DOMAIN" "$APP_LAUNCH_AGENT_FILE"
else
    /bin/launchctl bootout "$LAUNCH_DOMAIN/$APP_LABEL" >/dev/null 2>&1 || true
    /bin/rm -f "$APP_LAUNCH_AGENT_FILE"
fi

printf '%s\n' "Installed and started $LABEL"
printf '%s\n' "Status: $INSTALL_BIN --status"
printf '%s\n' "App:    $INSTALL_UI_APP"
printf '%s\n' "Logs:   $DAILY_LOG_DIR"
