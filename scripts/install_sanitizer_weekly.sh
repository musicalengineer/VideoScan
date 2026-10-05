#!/bin/bash
# Install the two weekly sanitizer runs (Rick 2026-10-04) as launchd agents:
#   com.videoscan.sanitizer-address  Saturday 07:00  (3 h cap)
#   com.videoscan.sanitizer-thread   Sunday   05:00  (4.5 h cap — TSan is slower)
# Both run scripts/weekly_sanitizer.py on the M4 inside its overnight window and
# finish before 10:00. Results: ~/Library/Logs/VideoScan/sanitizer/, surfaced in
# the morning digest by scripts/sanitizer_alert.py. Re-running this replaces
# both agents. Same shape as install_nightly.sh.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UID_NUM="$(id -u)"
LOGDIR="$HOME/Library/Logs/VideoScan/sanitizer"
mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents"

install_one() {
    local kind="$1" weekday="$2" hour="$3" hours="$4"
    local label="com.videoscan.sanitizer-$kind"
    local plist="$HOME/Library/LaunchAgents/$label.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$REPO/scripts/weekly_sanitizer.py</string>
        <string>--sanitizer</string>
        <string>$kind</string>
        <string>--timeout-hours</string>
        <string>$hours</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>$weekday</integer>
        <key>Hour</key>
        <integer>$hour</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOGDIR/launchd-$kind.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/launchd-$kind.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>Nice</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Standard</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null \
        || { launchctl unload "$plist" 2>/dev/null || true; launchctl load "$plist"; }
    echo "installed $label (weekday $weekday at $hour:00, cap ${hours}h)"
}

# launchd Weekday: 0 or 7 = Sunday, 6 = Saturday.
install_one address 6 7 3
install_one thread 0 5 4.5
echo "Done. Verify with: launchctl list | grep sanitizer"
