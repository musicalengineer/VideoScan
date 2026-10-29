#!/usr/bin/env bash
# Install the toolchain update (scripts/update_toolchain.sh) one hour before
# this Mac's nightly slot in scripts/nightly_rota.json (02:00 -> 01:00).
# Off-rota Macs get nothing. Re-runnable:
#
#   bash scripts/install_toolchain_update.sh

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LABEL="com.videoscan.toolchain-update"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/VideoScan/toolchain_update_launchd.log"

SLOT="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" slot "$HOST")"
case "$SLOT" in
    on\ *) read -r _ HOUR MIN <<<"$SLOT" ;;
    *) echo "$HOST is not on the nightly rotation ($SLOT) — no toolchain update installed."; exit 0 ;;
esac
HOUR=$(( (10#$HOUR + 23) % 24 ))
MIN=$(( 10#$MIN ))

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO_ROOT/scripts/update_toolchain.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HOUR</integer>
        <key>Minute</key>
        <integer>$MIN</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
printf 'Installed %s on %s at %02d:%02d (one hour before the nightly).\n' "$LABEL" "$HOST" "$HOUR" "$MIN"
