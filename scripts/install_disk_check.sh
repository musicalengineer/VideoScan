#!/usr/bin/env bash
# Install the weekly live disk check (scripts/disk_check.py, read-only, no
# sudo): Mondays 10:30, before the working day. A Mac asleep at 10:30 runs it
# on wake. Failures post a notification; the log is
# ~/Library/Logs/VideoScan/disk_check.log. Re-runnable:
#
#   bash scripts/install_disk_check.sh

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.videoscan.disk-check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/VideoScan/disk_check_launchd.log"

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
        <string>/usr/bin/python3</string>
        <string>$REPO_ROOT/scripts/disk_check.py</string>
        <string>--quiet</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>10</integer>
        <key>Minute</key>
        <integer>30</integer>
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
echo "Installed $LABEL: live disk check, Mondays 10:30."
