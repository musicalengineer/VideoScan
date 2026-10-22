#!/usr/bin/env bash
# Failover guard for the nightly test run.
#
# The fleet runs this staggered so we ALWAYS have a green run to look at in
# the morning, even if the primary host is wedged:
#
#   M4 @ 02:00   (primary — most dev happens here)
#   M5 @ 03:15   (runs only if M4 didn't land a green run)
#   M1           OFF the rotation (GH #360, 2026-10-21: a travel laptop, often on
#                battery). scripts/nightly_rota.json is the one source; a Mac
#                that is off it never runs, even if its launchd job still fires.
#
# Logic: fetch origin/metrics; if a GREEN (status:ok, total>0) testdriver row
# dated *today* (UTC) already exists from any host, there's nothing to do —
# exit 0. Otherwise run the real nightly. A *failed* row does NOT count, so
# failover fires exactly when the primary is "weird" (build break, hang, etc).
#
# Idempotent and safe to run on every host — the guard collapses to a no-op
# once any host succeeds.

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

HAS_GREEN="$(TD_ROWS="$ROWS" TODAY="$TODAY" python3 - <<'PY'
import os, json
today = os.environ.get("TODAY","")
for line in os.environ.get("TD_ROWS","").splitlines():
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    if r.get("status") == "ok" and str(r.get("ts",""))[:10] == today and int(r.get("total") or 0) > 0:
        print("yes"); break
else:
    print("no")
PY
)"

if [ "$HAS_GREEN" = "yes" ]; then
    log "green run already present for $TODAY — skipping (no-op failover)."
    exit 0
fi

log "no green run for $TODAY yet — running nightly."
# caffeinate keeps the Mac awake for the duration; nightly_local_tests.sh does
# its own build/test/publish (with the push retry/backoff + pending queue).
exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_local_tests.sh"
