#!/usr/bin/env bash
# SessionStart hook (Claude Code and Codex). Stdout is injected into the session.
# Prints the few facts a session needs to start correctly and nothing else:
#   1. docs/STATUS.md header (theme + in flight) — the one place state lives
#   2. P0 / P1 counts from GitHub (if gh is available and fast)
#   3. Last night's lane results, one line each, only if red or missing
# No rituals, no questions, no digests. Replaces session_morning_hook.sh (2026-10-23).

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATUS="$REPO_ROOT/docs/STATUS.md"
LOGS="$HOME/Library/Logs/VideoScan"

echo "=== VideoScan session start — $(date '+%a %Y-%m-%d %H:%M') ==="
echo "Branch: $(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo '?')  ·  checkout: $REPO_ROOT"
echo

# 1. STATUS.md: theme + in-flight (up to the "## Next" heading)
if [ -f "$STATUS" ]; then
  awk '/^## Next/{exit} {print}' "$STATUS" | sed -n '1,40p'
else
  echo "(docs/STATUS.md missing — write it before doing anything else)"
fi
echo

# 1b. Swift 6 migration: the measured morning figure (docs/design/swift6_migration_2026_10_25.md)
if [ -f "$REPO_ROOT/scripts/warnings_baseline.tsv" ]; then
  python3 "$REPO_ROOT/scripts/warning_ratchet.py" progress 2>/dev/null || echo "Swift 6 progress: (warning_ratchet.py failed — run it by hand)"
  echo
fi

# 2. P0 / P1 counts (3 s budget; silent if gh is unavailable)
if command -v gh >/dev/null 2>&1; then
  p0=$(timeout 3 gh issue list -R musicalengineer/VideoScan --label P0 --state open --json number --jq 'length' 2>/dev/null || echo "?")
  p1=$(timeout 3 gh issue list -R musicalengineer/VideoScan --label P1 --state open --json number --jq 'length' 2>/dev/null || echo "?")
  dow=$(date +%u)
  line="Open P0: $p0 · P1: $p1"
  [ "$dow" = "5" ] && line="$line  — FRIDAY: zero P0 by noon"
  [ "$dow" = "1" ] && line="$line  — MONDAY: triage every P1"
  echo "$line"
fi

# 3. Overnight lanes: one line each, only when something needs a look
python3 - "$LOGS" "$(date +%Y-%m-%d)" <<'PY' 2>/dev/null || true
import json, os, sys
logs, today = sys.argv[1], sys.argv[2]
def latest(name):
    p = os.path.join(logs, name, "latest.json")
    try:
        return json.load(open(p))
    except Exception:
        return None
out = []
s = latest("adversarial-review")
if s is not None:
    if s.get("date") != today:
        out.append(f"🔴 adversarial review did not run last night (last: {s.get('date') or 'never'})")
    elif s.get("status") == "failed":
        out.append(f"🔴 adversarial review FAILED: {s.get('failure')}")
    else:
        n = s.get("newFindings") or {}
        p = ", ".join(f"{n[k]} {k}" for k in ("P0", "P1") if n.get(k))
        if p:
            out.append(f"🔴 adversarial review: {p} → {s.get('doc')}")
s = latest("hallie-voice")
if s and s.get("date") == today and s.get("alert"):
    out.append(f"🔴 {s.get('headline')}")
if out:
    print("\n".join(out))
PY

echo "=== end. Read docs/STATUS.md fully before changing code; park ideas in docs/BACKLOG.md. ==="
