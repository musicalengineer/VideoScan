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
echo "=== end digest — surface this to Rick and flag anything marked 'Needs a look'. ==="
