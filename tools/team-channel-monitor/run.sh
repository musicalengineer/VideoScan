#!/bin/zsh
# Build (release) and launch the Team Channel monitor in the menu bar.
# Re-run after pulling changes; it replaces any running copy.
# Extra args go to the app: run.sh --demo cycles the badge colours once.
set -e -o pipefail
DIR="${0:A:h}"
swift build -c release --package-path "$DIR" 2>&1 | tail -3
LABEL="com.videoscan.team-channel-monitor"
if [[ $# -eq 0 && -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]]; then
  # install.sh registered a KeepAlive LaunchAgent: launching a second copy by
  # hand leaves two menu-bar icons and launchd respawning the one you quit
  # (Rick 9/13: "old version keeps respawning"). Restart through launchd so
  # there is exactly one instance and it is the binary just built.
  pkill -x TeamChannelMonitor 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || true
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
  echo "TeamChannelMonitor restarted via launchd ($LABEL) — one copy, fresh build."
else
  pkill -x TeamChannelMonitor 2>/dev/null || true
  nohup "$DIR/.build/release/TeamChannelMonitor" "$@" >/dev/null 2>&1 &
  disown
  echo "TeamChannelMonitor running — look for the speech-bubble icon in the menu bar."
fi
