#!/usr/bin/env bash
# Failover guard for the nightly test run.
#
# The fleet runs this staggered so we ALWAYS have a green run to look at in
# the morning, even if the primary host is wedged:
#
#   M4 @ 02:00   (primary — most dev happens here)
#   M5 @ 03:15   (runs only if M4 didn't land a green run)
#   M1 @ 04:30   (last resort)
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
