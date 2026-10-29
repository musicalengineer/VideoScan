#!/usr/bin/env bash
# Toolchain update, one hour before the nightly (Rick 2026-10-29): take the
# latest Homebrew packages and Xcode, so the 02:00 nightly tests them and the
# morning report says whether the newest tools are safe.
#
#   bash scripts/update_toolchain.sh            (install: scripts/install_toolchain_update.sh)
#
# Unattended by construction: stdin is /dev/null, so brew never asks "Y/n" and
# sudo can never wait for a password (a cask that needs one fails and is
# listed). Holds $LOCK while it runs; nightly_guarded.sh waits for it, so a
# long Xcode download cannot overlap the nightly build.
#
# Writes ~/Library/Logs/VideoScan/toolchain_update.log (START/OUTCOME, one line
# per upgraded package) and toolchain_update_latest.json for the morning report.

set -u
exec < /dev/null

LOGDIR="$HOME/Library/Logs/VideoScan"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/toolchain_update.log"
LOCK="${TOOLCHAIN_UPDATE_LOCK:-$LOGDIR/toolchain_update.lock}"
SUMMARY="$LOGDIR/toolchain_update_latest.json"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
BREW="${TOOLCHAIN_BREW:-/opt/homebrew/bin/brew}"
MAS="${TOOLCHAIN_MAS:-/opt/homebrew/bin/mas}"
XCODE_APP_ID=497799835

export NONINTERACTIVE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$HOST] $*" >> "$LOG"; }

# A test run in flight must not have its tools swapped underneath it.
BUSY="${TOOLCHAIN_BUSY_PATTERN:-nightly_local_tests.sh|run_gauntlet.sh|m4_run.sh}"
if pgrep -f "$BUSY" >/dev/null 2>&1; then
    log "SKIPPED: a nightly or gauntlet run is in progress — no updates tonight."
    exit 0
fi
if ! mkdir "$LOCK" 2>/dev/null; then
    log "SKIPPED: another toolchain update holds $LOCK."
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

T0=$(date +%s)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-update.XXXXXX")"
xcode_version() { xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }
XCODE_BEFORE="$(xcode_version)"
log "START brew + Xcode update (Xcode: ${XCODE_BEFORE:-none})"

FAILED=""
"$BREW" list --versions > "$WORK/before.txt" 2>/dev/null
"$BREW" update --quiet >> "$LOG" 2>&1 || FAILED="$FAILED brew-update"
"$BREW" upgrade --formula >> "$LOG" 2>&1 || FAILED="$FAILED brew-upgrade-formula"
# No --greedy: casks that update themselves (VS Code, VLC, …) are left to do so.
"$BREW" upgrade --cask >> "$LOG" 2>&1 || FAILED="$FAILED brew-upgrade-cask"
"$BREW" cleanup --quiet >> "$LOG" 2>&1 || true
"$BREW" list --versions > "$WORK/after.txt" 2>/dev/null

# One line per package whose version changed, e.g. "ffmpeg 9.0.2 -> 9.0.3".
CHANGED="$(python3 - "$WORK/before.txt" "$WORK/after.txt" <<'PY'
import sys
def read(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if parts: d[parts[0]] = parts[-1]
    return d
b, a = read(sys.argv[1]), read(sys.argv[2])
for name in sorted(a):
    if name in b and b[name] != a[name]:
        print(f"{name} {b[name]} -> {a[name]}")
    elif name not in b:
        print(f"{name} (new) {a[name]}")
PY
)"
[ -n "$CHANGED" ] && printf '%s\n' "$CHANGED" | while read -r line; do log "  upgraded: $line"; done

# Xcode from the App Store, through mas (brew install mas). Then what a new
# Xcode needs before it can build: first launch (needs sudo — works only with
# the one-command sudoers rule, else it is named for Rick) and the Metal
# toolchain (no sudo).
XCODE_NOTE=""
if [ -x "$MAS" ]; then
    if "$MAS" outdated 2>/dev/null | grep -q "^$XCODE_APP_ID"; then
        log "  Xcode update available — mas upgrade $XCODE_APP_ID"
        "$MAS" upgrade "$XCODE_APP_ID" >> "$LOG" 2>&1 || FAILED="$FAILED xcode-upgrade"
    fi
else
    XCODE_NOTE="mas not installed; Xcode not checked (brew install mas)"
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    if sudo -n /usr/bin/xcodebuild -runFirstLaunch >> "$LOG" 2>&1; then
        log "  Xcode first launch done"
    else
        FAILED="$FAILED xcode-first-launch"
        XCODE_NOTE="Xcode needs first launch: sudo xcodebuild -runFirstLaunch (or add the sudoers rule)"
    fi
fi
if ! xcrun -f metal >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain >> "$LOG" 2>&1 || FAILED="$FAILED metal-toolchain"
fi
XCODE_AFTER="$(xcode_version)"
[ "$XCODE_BEFORE" != "$XCODE_AFTER" ] && log "  upgraded: Xcode $XCODE_BEFORE -> $XCODE_AFTER"
[ -n "$XCODE_NOTE" ] && log "  note: $XCODE_NOTE"

STATUS=ok; [ -n "$FAILED" ] && STATUS=partial
SECS=$(( $(date +%s) - T0 ))
CHANGED="$CHANGED" FAILED="$FAILED" XB="$XCODE_BEFORE" XA="$XCODE_AFTER" NOTE="$XCODE_NOTE" \
STATUS="$STATUS" SECS="$SECS" HOSTNAME_="$HOST" python3 - "$SUMMARY" <<'PY'
import json, os, sys, datetime
e = os.environ
json.dump({
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "host": e["HOSTNAME_"], "status": e["STATUS"], "elapsed_s": int(e["SECS"]),
    "upgraded": [l for l in e["CHANGED"].splitlines() if l],
    "failed_steps": e["FAILED"].split(),
    "xcode_before": e["XB"], "xcode_after": e["XA"], "note": e["NOTE"],
}, open(sys.argv[1], "w"), indent=2)
PY
rm -rf "$WORK"
log "OUTCOME $STATUS: $(printf '%s\n' "$CHANGED" | grep -c .) package(s) upgraded${FAILED:+; failed:$FAILED} in ${SECS}s"
exit 0
