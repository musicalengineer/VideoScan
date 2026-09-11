#!/bin/zsh
# Build (release) and launch the Team Channel monitor in the menu bar.
# Re-run after pulling changes; it replaces any running copy.
set -e
DIR="${0:A:h}"
swift build -c release --package-path "$DIR" 2>&1 | tail -3
pkill -x TeamChannelMonitor 2>/dev/null || true
nohup "$DIR/.build/release/TeamChannelMonitor" >/dev/null 2>&1 &
disown
echo "TeamChannelMonitor running — look for the speech-bubble icon in the menu bar."
