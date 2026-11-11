#!/usr/bin/env bash
# Guard for the nightly test run: one green run per on-rota Mac per day AND
# per commit of main (a green run of an older main does not excuse today's).
#
# Every Mac on the rotation (scripts/nightly_rota.json: the two Mac Studios,
# the M5 Ultra at 02:00 and the M4 at 14:00) runs its own nightly, because the metrics
# page shows one row per Studio (DECISIONS 2026-10-28). Off-rota Macs (the
# laptops) never run, even if their launchd job still fires.
#
# Logic: fetch origin/metrics and origin/main; if a GREEN (status:ok, total>0)
# testdriver row dated *today* (UTC) already exists from THIS host FOR THE
# COMMIT origin/main IS AT NOW, the suite is done — a second launch the same
# day on the same main (e.g. a kickstart) is a no-op, exit 0.
# Otherwise run the real nightly. A *failed* row does NOT count, so a re-run
# after a red night still goes ahead. Another host's green row never counts
# (until 2026-10-29 it did, and the Ultra skipped whenever the M4 was green).
#
# By commit, not by date alone (2026-11-10): a 01:40 manual run was green, the
# 14:00 scheduled run saw "green today" and skipped, and that day's merges
# were never run on the M4. The commit compared is origin/main after this
# script's own fetch: what nightly_local_tests.sh fast-forwards to and tests.
# A row's "commit" is a hex hash (the suite row a short one, the gauntlet row
# the full one) and matches when it is a prefix of origin/main's. It never
# counts when: the row has no hash (rows from before the field, "unknown"),
# the hash is another commit's, or main could not be fetched or resolved (a
# stale origin/main proves nothing about main now). Every doubt runs. A
# checkout that is ahead of origin/main or cannot fast-forward publishes its
# own HEAD, which is not origin/main: it runs again too.
#
# A Mac listed under "gauntlet" in the rota (the M4) is done only when BOTH
# are on the page for today and this commit: the green suite row AND a
# published gauntlet row (source "gauntlet", schemaVersion 1, this Mac's
# machine label, status passed or amber). Suite green but gauntlet missing,
# failed, incomplete, for another commit or skipped (testbed busy) → the
# retry runs the gauntlet only
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

# The commit a run started now would test: origin/main, freshly fetched. Empty
# = unknown, and unknown never skips (MAIN_WHY is the reason the run line gives).
MAIN_SHA=""
MAIN_WHY=""
if git fetch origin main --quiet 2>/dev/null; then
    MAIN_SHA="$(git rev-parse --verify --quiet 'origin/main^{commit}' 2>/dev/null || true)"
    case "$MAIN_SHA" in
        *[!0-9a-fA-F]*|"")
            MAIN_SHA=""
            MAIN_WHY="origin/main does not resolve to a commit, so no earlier run can be matched to it" ;;
    esac
else
    MAIN_WHY="could not fetch origin/main, so the commit main is at now is unknown"
fi
MAIN_SHORT="$(printf '%s' "$MAIN_SHA" | cut -c1-9)"

# Line 1: the words that are done for today AND this commit: "suite" (this
# host's LATEST suite row today is GREEN and for origin/main's commit) and
# "gauntlet" (this Mac's LATEST published gauntlet row today is passed/amber
# and for that commit). The latest row per kind decides — an earlier pass
# never outlives a later failure (Codex 2026-11-05 re-review, P1).
# Line 2 / line 3: one phrase each for the log, suite then gauntlet: the row
# that matched ("suite row <ts>") or why none did. Row text reaches the log
# only through a whitelist of characters. Anything unparseable is not a row.
VERDICT="$(TD_ROWS="$ROWS" TODAY="$TODAY" HOST="$HOST" MACHINE="$MACHINE" MAIN_SHA="$MAIN_SHA" python3 - <<'PY'
import os, json, re
today = os.environ.get("TODAY","")
host = os.environ.get("HOST","")
machine = os.environ.get("MACHINE","")
main = os.environ.get("MAIN_SHA","").lower()
latest = {}      # kind -> (ts, line index, row): the newest row of that kind for this Mac today
for n, line in enumerate(os.environ.get("TD_ROWS","").splitlines()):
    line = line.strip()
    if not line: continue
    try: r = json.loads(line)
    except Exception: continue
    if not isinstance(r, dict): continue
    ts = str(r.get("ts",""))
    if ts[:10] != today: continue
    if r.get("source") == "gauntlet":
        if r.get("schemaVersion") == 1 and machine and r.get("machine") == machine: kind = "gauntlet"
        else: continue
    elif r.get("host") == host: kind = "suite"
    else: continue
    if kind not in latest or (ts, n) > latest[kind][:2]:
        latest[kind] = (ts, n, r)

def commit_of(r):
    """The row's commit as lowercase hex (7 to 40 digits), or "" when it has none."""
    c = r.get("commit")
    c = c.strip().lower() if isinstance(c, str) else ""
    return c if re.fullmatch(r"[0-9a-f]{7,40}", c) else ""

def suite_green(r):
    try: return r.get("status") == "ok" and int(r.get("total") or 0) > 0
    except (TypeError, ValueError): return False

def gauntlet_green(r):
    return r.get("status") in ("passed", "amber")

def judge(kind, green, none_yet):
    """(done, phrase) for the latest row of this kind today."""
    if kind not in latest: return False, none_yet
    ts, _, r = latest[kind]
    what = "%s row %s" % (kind, re.sub(r"[^0-9A-Za-z:.+-]", "", ts)[:32])
    status = re.sub(r"[^a-z_]", "", str(r.get("status","")).lower())[:20] or "no status"
    if not green(r): return False, "the latest %s is %s, not green" % (what, status)
    c = commit_of(r)
    if not c: return False, "the latest %s is green but carries no commit hash" % what
    if not main: return False, "the latest %s is green for commit %s" % (what, c[:9])
    if not main.startswith(c):
        return False, "the latest %s is green for commit %s, and main is now at %s" % (what, c[:9], main[:9])
    return True, what + (" " + status if kind == "gauntlet" else "")

suite_done, suite_note = judge("suite", suite_green, "no suite row from this Mac today")
gauntlet_done, gauntlet_note = judge("gauntlet", gauntlet_green,
                                     "no gauntlet row for machine %s today" % (machine or "?"))
print(" ".join(w for w, d in (("gauntlet", gauntlet_done), ("suite", suite_done)) if d))
print(suite_note)
print(gauntlet_note)
PY
)"
DONE="$(printf '%s\n' "$VERDICT" | sed -n 1p)"
SUITE_NOTE="$(printf '%s\n' "$VERDICT" | sed -n 2p)"
GAUNTLET_NOTE="$(printf '%s\n' "$VERDICT" | sed -n 3p)"
case " $DONE " in *" suite "*) HAS_GREEN=yes ;; *) HAS_GREEN=no ;; esac
case " $DONE " in *" gauntlet "*) HAS_GAUNTLET=yes ;; *) HAS_GAUNTLET=no ;; esac

if [ "$HAS_GREEN" = "yes" ]; then
    if [ "$GAUNTLET_MAC" != "yes" ]; then
        log "green run from $HOST for main $MAIN_SHORT already present for $TODAY ($SUITE_NOTE) — skipping (no-op)."
        exit 0
    fi
    if [ "$HAS_GAUNTLET" = "yes" ]; then
        log "green run and a published gauntlet (machine $MACHINE) from $HOST for main $MAIN_SHORT already present for $TODAY ($SUITE_NOTE; $GAUNTLET_NOTE) — skipping (no-op)."
        exit 0
    fi
    log "green suite from $HOST for main $MAIN_SHORT on $TODAY ($SUITE_NOTE), but ${GAUNTLET_NOTE:-no passed/amber gauntlet row for machine ${MACHINE:-?}} — running the gauntlet only."
    exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_gauntlet.sh" --gauntlet-only
fi

# Why it runs, for the log: main unknown says so first, then what the page had.
WHY="${SUITE_NOTE:-no verdict on the rows of today}"
[ -z "$MAIN_WHY" ] || WHY="$MAIN_WHY; $WHY"

# caffeinate keeps the Mac awake for the duration; nightly_local_tests.sh does
# its own build/test/publish (with the push retry/backoff + pending queue).
# A Mac listed under "gauntlet" runs the full testbed instead: the same suite,
# then the deep gauntlet, then one done line (scripts/nightly_gauntlet.sh).
if [ "$GAUNTLET_MAC" = "yes" ]; then
    log "not done for $TODAY${MAIN_SHORT:+ at main $MAIN_SHORT}: $WHY — running the full testbed (suite + gauntlet)."
    exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_gauntlet.sh"
fi
log "not done for $TODAY${MAIN_SHORT:+ at main $MAIN_SHORT}: $WHY — running nightly."
exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_local_tests.sh"
