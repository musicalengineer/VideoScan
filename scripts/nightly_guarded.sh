#!/usr/bin/env bash
# Guard for the nightly test run: one green run per on-rota Mac per day.
#
# Every Mac on the rotation (scripts/nightly_rota.json: the two Mac Studios,
# the M5 Ultra at 02:00 and the M4 at 14:00) runs its own nightly, because the metrics
# page shows one row per Studio (DECISIONS 2026-10-28). Off-rota Macs (the
# laptops) never run, even if their launchd job still fires.
#
# Logic: fetch origin/metrics; if a GREEN (status:ok, total>0) testdriver row
# dated *today* (UTC) already exists from THIS host, the suite is done —
# a second launch the same day (e.g. a kickstart) is a no-op, exit 0.
# Otherwise run the real nightly. A *failed* row does NOT count, so a re-run
# after a red night still goes ahead. Another host's green row never counts
# (until 2026-10-29 it did, and the Ultra skipped whenever the M4 was green).
#
# A Mac listed under "gauntlet" in the rota (the M4) is done only when BOTH
# are on the page for today: the green suite row AND a published gauntlet row
# (source "gauntlet", schemaVersion 1, this Mac's machine label, status
# passed or amber). Suite green but gauntlet missing, failed, incomplete or
# skipped (testbed busy) → the retry runs the gauntlet only
# (scripts/nightly_gauntlet.sh --gauntlet-only). Codex 2026-11-05 (P1): the
# suite's green row alone used to make the retry a no-op, so a failed or
# never-published gauntlet stayed that way for the day.
#
# Tests: tests/test_nightly_gauntlet.py GuardRetryTests (real shell run with
# a fake git / scutil / caffeinate on PATH).

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LOGDIR="$HOME/Library/Logs/VideoScan"
mkdir -p "$LOGDIR"
GUARD_LOG="$LOGDIR/nightly_guard.log"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$HOST] $*" >> "$GUARD_LOG"; }

# Off the rotation = never run, publish nothing (the page lists it as "off the
# rota", not as a failure). Unknown = run as before: never silently drop a Mac.
SLOT="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" slot "$HOST" 2>/dev/null || echo unknown)"
case "$SLOT" in
    off\ *)
        log "off the nightly rotation (${SLOT#off }) — not running. To remove the job: bash scripts/install_nightly.sh"
        exit 0
        ;;
esac

# The toolchain update (scripts/update_toolchain.sh, an hour earlier) may
# still be installing brew packages or Xcode: wait for it, never build on a
# half-installed toolchain. Capped, so a stuck update cannot cost the night.
TOOLCHAIN_LOCK="${TOOLCHAIN_UPDATE_LOCK:-$LOGDIR/toolchain_update.lock}"
WAIT_MAX="${NIGHTLY_TOOLCHAIN_WAIT_SECONDS:-5400}"
waited=0
while [ -d "$TOOLCHAIN_LOCK" ] && [ "$waited" -lt "$WAIT_MAX" ]; do
    sleep 1; waited=$((waited + 1))
done
if [ -d "$TOOLCHAIN_LOCK" ]; then
    log "toolchain update still running after ${waited}s — running the nightly anyway."
elif [ "$waited" -gt 0 ]; then
    log "waited ${waited}s for the toolchain update to finish."
fi

git fetch origin metrics --quiet 2>/dev/null || true
TODAY="$(date -u +%Y-%m-%d)"
ROWS="$(git show origin/metrics:metrics/testdriver.jsonl 2>/dev/null || true)"
GAUNTLET_MAC="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" gauntlet "$HOST" 2>/dev/null || echo no)"
MACHINE="$(python3 "$REPO_ROOT/scripts/nightly_rota.py" machine "$HOST" 2>/dev/null || true)"

# Prints the words that are done for today: "suite" (a GREEN suite row from
# this host) and "gauntlet" (a published passed/amber gauntlet row for this
# Mac's machine label). Anything unparseable is simply not done.
DONE="$(TD_ROWS="$ROWS" TODAY="$TODAY" HOST="$HOST" MACHINE="$MACHINE" python3 - <<'PY'
import os, json
today = os.environ.get("TODAY","")
host = os.environ.get("HOST","")
machine = os.environ.get("MACHINE","")
done = set()
for line in os.environ.get("TD_ROWS","").splitlines():
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    if str(r.get("ts",""))[:10] != today: continue
    if (r.get("status") == "ok" and r.get("host") == host and int(r.get("total") or 0) > 0):
        done.add("suite")
    if (r.get("source") == "gauntlet" and r.get("schemaVersion") == 1 and machine
            and r.get("machine") == machine and r.get("status") in ("passed", "amber")):
        done.add("gauntlet")
print(" ".join(sorted(done)))
PY
)"
case " $DONE " in *" suite "*) HAS_GREEN=yes ;; *) HAS_GREEN=no ;; esac
case " $DONE " in *" gauntlet "*) HAS_GAUNTLET=yes ;; *) HAS_GAUNTLET=no ;; esac

if [ "$HAS_GREEN" = "yes" ]; then
    if [ "$GAUNTLET_MAC" != "yes" ]; then
        log "green run from $HOST already present for $TODAY — skipping (no-op)."
        exit 0
    fi
    if [ "$HAS_GAUNTLET" = "yes" ]; then
        log "green run and a published gauntlet (machine $MACHINE) from $HOST already present for $TODAY — skipping (no-op)."
        exit 0
    fi
    log "green suite from $HOST for $TODAY, but no passed/amber gauntlet row for machine ${MACHINE:-?} — running the gauntlet only."
    exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_gauntlet.sh" --gauntlet-only
fi

# caffeinate keeps the Mac awake for the duration; nightly_local_tests.sh does
# its own build/test/publish (with the push retry/backoff + pending queue).
# A Mac listed under "gauntlet" runs the full testbed instead: the same suite,
# then the deep gauntlet, then one done line (scripts/nightly_gauntlet.sh).
if [ "$GAUNTLET_MAC" = "yes" ]; then
    log "no green run for $TODAY yet — running the full testbed (suite + gauntlet)."
    exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_gauntlet.sh"
fi
log "no green run for $TODAY yet — running nightly."
exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_local_tests.sh"
