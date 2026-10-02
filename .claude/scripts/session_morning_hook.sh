#!/usr/bin/env bash
# SessionStart hook: show the morning test-metrics digest the FIRST time a
# Claude session starts each day, then stay quiet for the rest of the day.
#
# Wired in .claude/settings.json under hooks.SessionStart. Its stdout is
# injected into the session context, so Claude sees the digest and can lead
# with it / flag anything that needs investigation.
#
# A date-stamped marker guarantees once-per-day: delete it to force a re-show.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAMP_DIR="$HOME/Library/Logs/VideoScan"
mkdir -p "$STAMP_DIR"
STAMP="$STAMP_DIR/.morning_shown_$(date +%Y%m%d)"

# Already shown today → emit nothing (keeps the session prompt clean).
[ -f "$STAMP" ] && exit 0

# Mark first so a slow/failed fetch still only tries once per day.
: > "$STAMP"
# Clean up yesterday's markers.
find "$STAMP_DIR" -maxdepth 1 -name '.morning_shown_*' ! -name "$(basename "$STAMP")" -delete 2>/dev/null || true

echo "=== Daily VideoScan test-metrics digest (first session of the day) ==="
bash "$REPO_ROOT/scripts/morning_metrics.sh" 2>/dev/null || echo "(morning_metrics.sh unavailable)"

# ── Branch hygiene (Rick 2026-07-08: decide purges first thing each day) ──
# Read-only; every git call tolerant so a weird repo state never kills the digest.
echo ""
echo "── Branch hygiene ──"
MERGED=$(git -C "$REPO_ROOT" branch --merged main 2>/dev/null \
    | sed 's/^ *[*+]* *//' | grep -vE '^(main|metrics|worktree-agent-)' || true)
UNMERGED=$(git -C "$REPO_ROOT" branch --no-merged main 2>/dev/null \
    | sed 's/^ *[*+]* *//' | grep -vE '^(main|metrics|worktree-agent-)' || true)
if [ -n "$MERGED" ]; then
    echo "Fully merged into main (purge candidates, local — check origin twins too):"
    echo "$MERGED" | sed 's/^/   • /'
else
    echo "No merged-and-undeleted local branches."
fi
if [ -n "$UNMERGED" ]; then
    echo "NOT merged (age = last commit):"
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        when=$(git -C "$REPO_ROOT" log -1 --format='%cr' "$b" 2>/dev/null || echo '?')
        echo "   • $b ($when)"
    done <<< "$UNMERGED"
fi
# ── Nightly adversarial review (tools/adversarial_nightly.py, shadow mode) ──
echo ""
echo "── Adversarial review (00:30 Tier A + 05:30 red tests) ──"
python3 - "$STAMP_DIR/adversarial-review/latest.json" "$(date +%Y-%m-%d)" <<'PY' 2>/dev/null || echo "🔴 adversarial review: latest.json unreadable"
import json, sys
path, today = sys.argv[1], sys.argv[2]
try: s = json.load(open(path))
except Exception: s = {}
st, n = s.get("status"), s.get("newFindings") or {}
p = ", ".join(f"{n[k]} {k}" for k in ("P0", "P1", "P2") if n.get(k))
cr = s.get("confirmedRed"); conf = f" ({cr} confirmed-red)" if cr is not None else (" (red tests: " + (s.get("confirmSkipped") or "pending") + ")")
nr = f"; {s['notReviewed']} NOT REVIEWED" if s.get("notReviewed") else ""
if st == "disabled" or s.get("disabled"): print(f"🔴 adversarial review DISABLED after 3 failed nights — `python3 tools/adversarial_nightly.py status`")
elif s.get("date") != today: print(f"🔴 adversarial review did not run last night (last: {s.get('date') or 'never'})")
elif st == "failed": print(f"🔴 adversarial review FAILED: {s.get('failure')} (baseline kept; next night retries)")
elif st == "findings" and p: print(f"🔴 adversarial review: {p}{conf}{nr} → {s.get('doc')}")
elif st in ("findings", "clean"): print(f"🟢 adversarial review clean, {s.get('filesReviewed')} files{nr} (${s.get('costUsd')}) → {s.get('doc')}")
elif st == "nothing": print("⚪ adversarial review: nothing in scope")
else: print(f"🔴 adversarial review: unknown state {st!r}")
PY

# ── Nightly local-model review (tools/model-fitness/nightly_review.sh, 04:30) ──
# One line from its latest.json (it posted to the team channel until the
# channel was retired, 2026-10-02). The path is the night's summary.md.
python3 - "$STAMP_DIR/model-review/latest.json" "$(date +%Y-%m-%d)" <<'PY' 2>/dev/null || echo "🔴 local review: latest.json unreadable"
import json, sys
path, today = sys.argv[1], sys.argv[2]
try: s = json.load(open(path))
except Exception: s = {}
st, where = s.get("status"), s.get("summary") or path
if s.get("date") != today: print(f"🔴 local review did not run last night (last: {s.get('date') or 'never'}) → {path}")
elif st == "skipped": print(f"🔴 local review SKIPPED: {s.get('reason')}; {s.get('unreviewed')} commit(s) pending → {where}")
elif st == "quiet": print(f"{'🟡' if (s.get('quietNights') or 0) >= 2 else '⚪'} local review: nothing new ({s.get('quietNights')} quiet night(s)) → {where}")
elif st == "reviewed":
    bad = (s.get("unreviewed") or 0) > 0 or (s.get("abandoned") or 0) > 0
    icon = "🔴" if bad else ("🟡" if (s.get("flagged") or 0) > 0 else "🟢")
    ab = f", {s['abandoned']} abandoned" if s.get("abandoned") else ""
    print(f"{icon} local review: {s.get('flagged')} flagged, {s.get('unreviewed')} unreviewed{ab} → {where}")
else: print(f"🔴 local review: unknown state {st!r} → {path}")
PY

# ── Hallie's voice (scripts/nightly_hallie_voice.py, in the 02:00 nightly) ──
# Silent unless last night's lane raised an alert.
python3 - "$STAMP_DIR/hallie-voice/latest.json" "$(date +%Y-%m-%d)" <<'PY' 2>/dev/null || true
import json, sys
path, today = sys.argv[1], sys.argv[2]
try: s = json.load(open(path))
except Exception: sys.exit(0)
if s.get("date") == today and s.get("alert"): print(f"🔴 {s.get('headline')} — {s.get('detail')} → {path}")
PY

echo "=== end digest — surface this to Rick and flag anything marked 'Needs a look'."
echo "Then, per Rick's standing request: report how overnight tests went, and ASK him"
echo "whether yesterday's spot-testing passed — if yes, propose purging the merged"
echo "branches (local + origin) and triaging stale unmerged ones. He wants to make"
echo "this call first thing each day. ==="
