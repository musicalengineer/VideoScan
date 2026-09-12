#!/bin/zsh
# Build the monitor and register it as a LaunchAgent so it starts at login
# and is relaunched if it quits. Re-run after code changes.
set -e -o pipefail
DIR="${0:A:h}"
swift build -c release --package-path "$DIR" 2>&1 | tail -1
BIN="$DIR/.build/release/TeamChannelMonitor"
PLIST="$HOME/Library/LaunchAgents/com.videoscan.team-channel-monitor.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.videoscan.team-channel-monitor</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/com.videoscan.team-channel-monitor" 2>/dev/null || true
pkill -x TeamChannelMonitor 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "TeamChannelMonitor registered as a login item and started."
