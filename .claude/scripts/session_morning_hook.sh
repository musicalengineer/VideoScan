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
echo "=== end digest — surface this to Rick and flag anything marked 'Needs a look'."
echo "Then, per Rick's standing request: report how overnight tests went, and ASK him"
echo "whether yesterday's spot-testing passed — if yes, propose purging the merged"
echo "branches (local + origin) and triaging stale unmerged ones. He wants to make"
echo "this call first thing each day. ==="
