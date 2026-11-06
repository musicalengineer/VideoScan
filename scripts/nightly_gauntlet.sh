#!/usr/bin/env bash
# nightly_gauntlet.sh — the full testbed on one Mac: the nightly suite, then the
# deep gauntlet, both published to the metrics page, then ONE line saying it is
# done (Rick, 2026-11-05: "m4 full testbed done, see results here ...").
#
# Runs instead of nightly_local_tests.sh when scripts/nightly_rota.json lists
# this Mac under "gauntlet" (the M4 at 14:00: a read on main around midday;
# the M5 Ultra keeps its 02:00 nightly). scripts/nightly_guarded.sh picks it.
#
#   1. takes the testbed lock (~/m4run/lock, the one scripts/m4_run.sh uses),
#      so an on-demand m4_run cannot start in the middle; if a live on-demand
#      run holds it, the suite still runs but the gauntlet is skipped and the
#      done line says so;
#   2. runs scripts/nightly_local_tests.sh (pulls main, full suite, publishes
#      its row);
#   3. runs scripts/run_gauntlet.sh --away (published: no --queue-only, so the
#      row lands on the page's Speed & safety section);
#   4. writes the done line to ~/Library/Logs/VideoScan/testbed_latest.txt,
#      appends it to testbed_history.log, and posts it as a notification on
#      Rick's Mac (VIDEOSCAN_NOTIFY_HOST, default ricksultra.local; best
#      effort — a failed notification never changes the exit code).
#
# Exit: the nightly suite's exit code, or 1 when the gauntlet is RED.
# Tests: tests/test_nightly_gauntlet.py (fake suite, fake gauntlet, fake ssh).

set -u

REPO_ROOT="${VIDEOSCAN_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGDIR="$HOME/Library/Logs/VideoScan"
mkdir -p "$LOGDIR"
LOCK="${VIDEOSCAN_TESTBED_LOCK:-$HOME/m4run/lock}"
NOTIFY_HOST="${VIDEOSCAN_NOTIFY_HOST-ricksultra.local}"
PAGE_URL="https://musicalengineer.github.io/VideoScan/"
HOST="${VIDEOSCAN_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
LAB="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" label "$HOST")"
case "$LAB" in M4) MACHINE=m4 ;; Ultra) MACHINE=m5 ;; M1) MACHINE=m1 ;; *) MACHINE=m4 ;; esac
G_LOG="$LOGDIR/nightly_gauntlet.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$G_LOG"; }

LOCK_HELD=0
take_lock() {   # the same protocol as scripts/m4_run.sh take_lock
    mkdir -p "$(dirname "$LOCK")"
    if ! mkdir "$LOCK" 2>/dev/null; then
        local pid; pid="$(cat "$LOCK/pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            BUSY="$(cat "$LOCK/info" 2>/dev/null)"
            return 1
        fi
        rm -f "$LOCK/pid" "$LOCK/info"; rmdir "$LOCK" 2>/dev/null
        mkdir "$LOCK" 2>/dev/null || { BUSY="lost the lock race"; return 1; }
    fi
    echo "$$" >"$LOCK/pid"
    echo "nightly testbed (suite + gauntlet) since $(date '+%H:%M')" >"$LOCK/info"
    LOCK_HELD=1
}
drop_lock() {
    [ "$LOCK_HELD" = 1 ] || return 0
    rm -f "$LOCK/pid" "$LOCK/info"; rmdir "$LOCK" 2>/dev/null; LOCK_HELD=0
}
trap drop_lock EXIT

BUSY=""
take_lock || log "testbed lock held (${BUSY}) — the suite runs, the gauntlet is skipped"

# ── 1. the nightly suite ─────────────────────────────────────────────
log "suite: start"
SUITE_T0=$(date +%s)
bash "$REPO_ROOT/scripts/nightly_local_tests.sh"
SUITE_RC=$?
log "suite: exit $SUITE_RC"
if [ "$SUITE_RC" = 0 ]; then SUITE_WORD="GREEN"; else SUITE_WORD="RED"; fi
# The counts, from the "Results: 1234p / 0f / 5s (1239 total; …)" line of the
# log this run just wrote (nightly_local_tests.sh names it nightly_test_<stamp>.log).
SUITE_TOTAL="$(python3 - "$LOGDIR" "$SUITE_T0" <<'PY' 2>/dev/null
import pathlib, re, sys
logs = [p for p in pathlib.Path(sys.argv[1]).glob("nightly_test_*.log")
        if p.stat().st_mtime >= float(sys.argv[2])]
for p in sorted(logs, key=lambda p: p.stat().st_mtime, reverse=True):
    hits = re.findall(r"Results: (\d+)p / (\d+)f / \d+s \((\d+) total", p.read_text(errors="replace"))
    if hits:
        passed, failed, total = hits[-1]
        print(f"{passed}/{total} passed, {failed} failed")
        break
PY
)"

# ── 2. the deep gauntlet, published ─────────────────────────────────
G_RC=0
if [ "$LOCK_HELD" = 1 ]; then
    t0=$(date +%s)
    G_OUT="$LOGDIR/nightly_gauntlet_run.log"
    log "gauntlet: start (machine $MACHINE)"
    (cd "$REPO_ROOT" && bash scripts/run_gauntlet.sh --away --machine "$MACHINE") >"$G_OUT" 2>&1
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    line="$(grep -E '^GAUNTLET ' "$G_OUT" | tail -1)"
    result="${line##* results=}"; result="${result%% *}"
    [ -n "$line" ] || result=/nonexistent
    G_VERDICT="$(python3 "$REPO_ROOT/scripts/m4_run_summary.py" --gauntlet "$result" "$rc" "$secs")"
    vrc=$?
    log "gauntlet: exit $rc in ${secs}s — $G_VERDICT"
    # The summary prints "deep: AMBER <reasons> (sha=…, 5s, results=…)" and
    # exits 0 GREEN · 3 AMBER · 1 RED. The word comes from the exit code;
    # anything else (a crash, a usage error) is RED.
    case "$vrc" in 0) G_WORD=GREEN ;; 3) G_WORD=AMBER ;; *) G_WORD=RED; G_RC=1 ;; esac
    G_WHY="${G_VERDICT#deep: * }"; G_WHY="${G_WHY% (sha=*}"
    [ "$G_WHY" = "$G_VERDICT" ] && G_WHY=""
    G_TEXT="gauntlet ${G_WORD} ($((secs / 60)) min)${G_WHY:+ — $G_WHY}"
else
    G_TEXT="gauntlet skipped (testbed busy: ${BUSY:-unknown})"
fi
drop_lock

# ── 3. the done line ────────────────────────────────────────────────
SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
DONE="${LAB:-$HOST} full testbed done $(date '+%Y-%m-%d %H:%M') (main ${SHA}): nightly suite ${SUITE_WORD}${SUITE_TOTAL:+ ${SUITE_TOTAL}} · ${G_TEXT} · results ${PAGE_URL}"
printf '%s\n' "$DONE" >"$LOGDIR/testbed_latest.txt"
printf '%s\n' "$DONE" >>"$LOGDIR/testbed_history.log"
log "$DONE"

if [ -n "$NOTIFY_HOST" ]; then
    # Strip anything that could break the AppleScript string.
    MSG="$(printf '%s' "$DONE" | tr -d '"\\`$')"
    ssh -oBatchMode=yes -oConnectTimeout=10 "$NOTIFY_HOST" \
        "osascript -e 'display notification \"${MSG//\'/}\" with title \"VideoScan testbed\"'" \
        >>"$G_LOG" 2>&1 || log "notify: could not reach $NOTIFY_HOST (the line is in testbed_latest.txt)"
fi

[ "$SUITE_RC" = 0 ] || exit "$SUITE_RC"
exit "$G_RC"
