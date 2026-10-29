#!/usr/bin/env bash
# Guard for the nightly test run: one green run per on-rota Mac per day.
#
# Every Mac on the rotation (scripts/nightly_rota.json: the two Mac Studios,
# M4 and M5 Ultra, both at 02:00) runs its own nightly, because the metrics
# page shows one row per Studio (DECISIONS 2026-10-28). Off-rota Macs (the
# laptops) never run, even if their launchd job still fires.
#
# Logic: fetch origin/metrics; if a GREEN (status:ok, total>0) testdriver row
# dated *today* (UTC) already exists from THIS host, there's nothing to do —
# exit 0 (a second launch the same day, e.g. a kickstart, is a no-op).
# Otherwise run the real nightly. A *failed* row does NOT count, so a re-run
# after a red night still goes ahead. Another host's green row never counts
# (until 2026-10-29 it did, and the Ultra skipped whenever the M4 was green).

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

git fetch origin metrics --quiet 2>/dev/null || true
TODAY="$(date -u +%Y-%m-%d)"
ROWS="$(git show origin/metrics:metrics/testdriver.jsonl 2>/dev/null || true)"

HAS_GREEN="$(TD_ROWS="$ROWS" TODAY="$TODAY" HOST="$HOST" python3 - <<'PY'
import os, json
today = os.environ.get("TODAY","")
host = os.environ.get("HOST","")
for line in os.environ.get("TD_ROWS","").splitlines():
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    if (r.get("status") == "ok" and str(r.get("ts",""))[:10] == today
            and r.get("host") == host and int(r.get("total") or 0) > 0):
        print("yes"); break
else:
    print("no")
PY
)"

if [ "$HAS_GREEN" = "yes" ]; then
    log "green run from $HOST already present for $TODAY — skipping (no-op)."
    exit 0
fi

log "no green run for $TODAY yet — running nightly."
# caffeinate keeps the Mac awake for the duration; nightly_local_tests.sh does
# its own build/test/publish (with the push retry/backoff + pending queue).
exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_local_tests.sh"
