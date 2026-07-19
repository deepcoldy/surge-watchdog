#!/bin/sh

set -eu

LABEL="com.shenhan.surge-watchdog"
APP_LABEL="com.shenhan.surge-watchdog.app"
INSTALL_DIR="$HOME/Library/Application Support/surge-watchdog"
INSTALL_BIN="$INSTALL_DIR/bin/surge-watchdog"
INSTALL_UI_SCRIPT="$INSTALL_DIR/lib/surge-ui-fallback.applescript"
INSTALL_UI_APP="$HOME/Applications/Surge Watchdog.app"
OLD_UI_APP="$HOME/Applications/Surge Watchdog UI.app"
LAUNCH_AGENT_FILE="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_LAUNCH_AGENT_FILE="$HOME/Library/LaunchAgents/$APP_LABEL.plist"
LAUNCH_DOMAIN="gui/$(/usr/bin/id -u)"

/bin/launchctl bootout "$LAUNCH_DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "$LAUNCH_DOMAIN/$APP_LABEL" >/dev/null 2>&1 || true
/bin/rm -f "$LAUNCH_AGENT_FILE" "$APP_LAUNCH_AGENT_FILE" "$INSTALL_BIN" "$INSTALL_UI_SCRIPT"
/bin/rm -rf "$INSTALL_UI_APP" "$OLD_UI_APP"
/bin/rmdir "$INSTALL_DIR/bin" 2>/dev/null || true
/bin/rmdir "$INSTALL_DIR/lib" 2>/dev/null || true

printf '%s\n' "Uninstalled $LABEL"
printf '%s\n' "Configuration, state, and logs were kept for recovery or inspection."
printf '%s\n' "To remove them, delete:"
printf '  %s\n' "$INSTALL_DIR"
printf '  %s\n' "$HOME/Library/Logs/surge-watchdog.log"
printf '  %s\n' "$HOME/Library/Logs/surge-watchdog.error.log"
