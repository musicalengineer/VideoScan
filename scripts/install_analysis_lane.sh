#!/usr/bin/env bash
# Install the nightly Swift 6 analysis lane (scripts/nightly_analysis_lane.sh)
# as a launchd agent on a fleet Mac: com.videoscan.swift6-analysis.
#
# WHEN it fires is the rota's business: scripts/nightly_rota.json "analysis"
# gives each on-rota Mac its slot (M4 04:30 — after the 02:00 test nightly has
# published, ~03:30 ET; the lane also waits for any running xcodebuild). A Mac
# that is OFF the nightly rotation gets the job REMOVED, like install_nightly.sh.
# Which sanitizer runs on which weekday is the rota's "sanitizer" map, read by
# the lane's `--sanitizer auto`.
#
#   bash scripts/install_analysis_lane.sh              # install at the rota slot, --sanitizer auto
#   bash scripts/install_analysis_lane.sh --no-sanitizer   # the five analysis stages only
#
# The two weekly sanitizer agents (install_sanitizer_weekly.sh) are NOT touched
# here. Once this lane has run green with `auto` for a week, boot them out
# (Rick's call): launchctl bootout gui/$(id -u)/com.videoscan.sanitizer-{address,thread}.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LABEL="com.videoscan.swift6-analysis"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LANE="$REPO_ROOT/scripts/nightly_analysis_lane.sh"
LOGDIR="$HOME/Library/Logs/VideoScan/swift6-analysis"
SANITIZER_ARGS=(--sanitizer auto)
[ "${1:-}" = "--no-sanitizer" ] && SANITIZER_ARGS=()

SLOT="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" analysis "$HOST")"
case "$SLOT" in
    on\ *)
        read -r _ HOUR MIN <<<"$SLOT"
        ;;
    off\ *)
        echo "$HOST is OFF the nightly rotation (${SLOT#off }) — removing $LABEL."
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
        if [ -f "$PLIST" ]; then
            mv "$PLIST" "$PLIST.off-rota"
            echo "  moved $PLIST -> $PLIST.off-rota"
        fi
        exit 0
        ;;
    *)
        echo "ERROR: host '$HOST' has no \"analysis\" slot in scripts/nightly_rota.json (and is not off the rota)." >&2
        exit 1
        ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"
ARGS_XML=""
for a in "${SANITIZER_ARGS[@]+"${SANITIZER_ARGS[@]}"}"; do
    ARGS_XML="$ARGS_XML        <string>$a</string>
"
done

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
        <string>$LANE</string>
$ARGS_XML    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$HOUR</integer>
        <key>Minute</key>
        <integer>$MIN</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOGDIR/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>Nice</key>
    <integer>10</integer>
    <!-- Standard, not Background: Background pins builds to the efficiency
         cores (see install_nightly.sh, 2026-10-01). -->
    <key>ProcessType</key>
    <string>Standard</string>
</dict>
</plist>
PLIST

UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
    || { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"; }
printf 'Installed %s on %s — fires %02d:%02d daily → %s %s\n' "$LABEL" "$HOST" "$HOUR" "$MIN" "$LANE" "${SANITIZER_ARGS[*]-}"
echo "Done. Verify with: launchctl list | grep swift6-analysis"
