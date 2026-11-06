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
#      its row) — unless --gauntlet-only (below);
#   3. runs scripts/run_gauntlet.sh --away (published: no --queue-only, so the
#      row lands on the page's Speed & safety section);
#   4. writes the done line to ~/Library/Logs/VideoScan/testbed_latest.txt,
#      appends it to testbed_history.log, and posts it as a notification on
#      Rick's Mac (VIDEOSCAN_NOTIFY_HOST, default ricksultra.local; best
#      effort — a failed notification never changes the exit code).
#
# --gauntlet-only: the guard's same-day retry when the suite already published
# GREEN but the gauntlet did not publish passed/amber (failed, skipped because
# the testbed was busy, or never ran). The suite is not re-run; the done line
# says so; the exit code is the gauntlet's.
#
# Exit: the nightly suite's exit code, or 1 when the gauntlet is RED.
# Tests: tests/test_nightly_gauntlet.py (fake suite, fake gauntlet, fake ssh).

set -u

MODE=full
case "${1:-}" in
    --gauntlet-only) MODE=gauntlet-only ;;
    "") ;;
    *) echo "usage: nightly_gauntlet.sh [--gauntlet-only]" >&2; exit 2 ;;
esac

REPO_ROOT="${VIDEOSCAN_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGDIR="$HOME/Library/Logs/VideoScan"
mkdir -p "$LOGDIR"
LOCK="${VIDEOSCAN_TESTBED_LOCK:-$HOME/m4run/lock}"
NOTIFY_HOST="${VIDEOSCAN_NOTIFY_HOST-ricksultra.local}"
PAGE_URL="https://musicalengineer.github.io/VideoScan/"
HOST="${VIDEOSCAN_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
LAB="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" label "$HOST")"
# The runner's machine label, from the one table (nightly_rota.py MACHINES);
# the guard matches the published row on the same label.
MACHINE="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" machine "$HOST")"
[ -n "$MACHINE" ] || MACHINE=m4
G_LOG="$LOGDIR/nightly_gauntlet.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$G_LOG"; }
lock_note() { log "$*"; }

# ── The testbed lock: ONE protocol, the same text as scripts/m4_run.sh (tests/test_m4_run.py pins them equal) ──
# $LOCK is a directory holding pid + info. Codex 2026-11-05 (P1): mkdir-then-write-pid let a contender see a
# pid-less directory, reclaim it and own the lock beside the first owner. Now:
#   • pid and info are written to a private staging directory and PUBLISHED by rename(2) — atomic, and it
#     fails (ENOTEMPTY) while another owner's files are there — so a visible lock always carries its pid;
#   • a stale lock (dead pid, or no pid at all: nothing in this protocol creates one) is reclaimed by first
#     renaming it aside — one contender wins that rename, the other retries and meets the winner's live pid;
#   • the lock is dropped only when its pid is ours.
# rename(2) is python's os.rename: the mv utility would nest the staging dir INSIDE an existing lock.
# VIDEOSCAN_TESTBED_LOCK_PAUSE (tests): a path; while it exists, pause after staging and before publishing,
# the only point where a contender can act between this run's decision and its claim.
lock_rename() { python3 -c 'import os, sys; os.rename(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null; }
take_lock() {   # take_lock <info>: LOCK_HELD=1, or BUSY="…" and return 1
    local stage="$LOCK.$$.staging" pid attempt
    mkdir -p "$(dirname "$LOCK")"
    rm -rf "$stage"; mkdir "$stage" || { BUSY="cannot stage the lock at $stage"; return 1; }
    echo "$$" >"$stage/pid"; echo "$1" >"$stage/info"
    if [ -n "${VIDEOSCAN_TESTBED_LOCK_PAUSE:-}" ]; then
        : >"$VIDEOSCAN_TESTBED_LOCK_PAUSE.paused"
        while [ -e "$VIDEOSCAN_TESTBED_LOCK_PAUSE" ]; do sleep 0.05; done
    fi
    for attempt in 1 2 3; do
        if lock_rename "$stage" "$LOCK"; then LOCK_HELD=1; return 0; fi
        pid="$(cat "$LOCK/pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            BUSY="busy: $(cat "$LOCK/info" 2>/dev/null)"; rm -rf "$stage"; return 1
        fi
        if lock_rename "$LOCK" "$LOCK.stale.$$"; then
            lock_note "reclaiming a stale lock (holder ${pid:-unknown} is gone)"
            rm -rf "$LOCK.stale.$$"
        fi
    done
    rm -rf "$stage"; BUSY="lost the lock race"; return 1
}
drop_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
    LOCK_HELD=0
}
# ── end of the shared lock text ──
LOCK_HELD=0
trap drop_lock EXIT

BUSY=""
take_lock "nightly testbed (suite + gauntlet) since $(date '+%H:%M')" \
    || log "testbed lock held (${BUSY}) — the suite runs, the gauntlet is skipped"

# ── 1. the nightly suite ─────────────────────────────────────────────
SUITE_TOTAL=""
if [ "$MODE" = gauntlet-only ]; then
    log "suite: skipped (--gauntlet-only: its green row is already on the page for today)"
    SUITE_RC=0
    SUITE_WORD="GREEN (earlier today, not re-run)"
else
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
fi

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
    G_TEXT="gauntlet skipped (testbed ${BUSY:-busy: unknown})"
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
