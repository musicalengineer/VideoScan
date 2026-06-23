#!/usr/bin/env bash
# Install the staggered, guarded nightly on whichever fleet host this is.
#
#   M4 → 02:00 (primary)   M5 → 03:15 (failover)   M1 → 04:30 (failover)
#
# All hosts run scripts/nightly_guarded.sh, which no-ops if a green run for
# today already landed. Run once per machine (re-runnable / idempotent):
#
#   bash scripts/install_nightly.sh
#
# On M4 it also removes the stale 2 AM crontab job (nightly-testdriver.sh)
# that was colliding with the LaunchAgent and breaking the build.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LABEL="com.videoscan.nightly-tests"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUARD="$REPO_ROOT/scripts/nightly_guarded.sh"
LOG="$HOME/Library/Logs/VideoScan/nightly_launchd.log"

case "$HOST" in
    *M4*) HOUR=2;  MIN=0  ;;
    *M5*) HOUR=3;  MIN=15 ;;
    *M1*) HOUR=4;  MIN=30 ;;
    *)
        echo "ERROR: unrecognized host '$HOST' — expected RicksM4/M5/M1." >&2
        echo "       Edit the case statement if this is a new fleet member." >&2
        exit 1
        ;;
esac

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
        <string>$GUARD</string>
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
    <string>Background</string>
</dict>
</plist>
PLIST

# Reload (bootout old, bootstrap new) under the GUI domain.
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
    || { launchctl unload "$PLIST" 2>/dev/null || true; launchctl load "$PLIST"; }

printf 'Installed %s on %s — fires %02d:%02d daily → %s\n' "$LABEL" "$HOST" "$HOUR" "$MIN" "$GUARD"

# ── M4 only: retire the colliding 2 AM crontab job ───────────────────
if [ -n "$(crontab -l 2>/dev/null | grep -F 'nightly-testdriver.sh' || true)" ]; then
    echo "Removing stale crontab job (nightly-testdriver.sh) that collided at 02:00…"
    crontab -l 2>/dev/null | grep -vF 'nightly-testdriver.sh' | grep -vF 'Nightly VideoScan metrics' | crontab -
    echo "  crontab cleaned."
fi

echo "Done. Verify with: launchctl list | grep videoscan"
