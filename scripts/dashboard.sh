#!/usr/bin/env bash
# Local code-health dashboard launcher.
#
# Pulls the latest metrics/history.jsonl from the `metrics` branch on
# origin, drops it beside docs/index.html, and serves docs/ on
# http://localhost:8765 so the Chart.js fetch() works (file:// URLs
# can't fetch sibling files in most browsers).
#
# Usage:
#   scripts/dashboard.sh          — fetch, serve, open browser
#   scripts/dashboard.sh --no-open — same but don't auto-open browser
#
# Ctrl-C to stop the server.

set -eu

PORT=8765
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

OPEN_BROWSER=1
if [ "${1:-}" = "--no-open" ]; then OPEN_BROWSER=0; fi

# ---------- 1. Fetch the metrics branch ----------
echo "Fetching origin/metrics…"
if ! git fetch origin metrics 2>/dev/null; then
    echo "ERROR: 'metrics' branch does not exist on origin yet." >&2
    echo "       The first CI run after pushing the CI changes will create it." >&2
    exit 1
fi

# ---------- 2. Extract history.jsonl into docs/ ----------
# git show pulls a single file out of the remote ref without checking it
# out — leaves your working tree on whatever branch you're on.
if ! git show "origin/metrics:metrics/history.jsonl" > docs/history.jsonl 2>/dev/null; then
    echo "ERROR: metrics/history.jsonl not found on origin/metrics." >&2
    echo "       The metrics branch exists but is empty — wait for one more CI run." >&2
    exit 1
fi

ROWS=$(wc -l < docs/history.jsonl | tr -d ' ')
echo "Loaded $ROWS data point(s) into docs/history.jsonl"

# ---------- 3. Serve docs/ on localhost ----------
URL="http://localhost:$PORT/"
echo "Serving docs/ at $URL"
echo "Press Ctrl-C to stop."

if [ "$OPEN_BROWSER" = "1" ]; then
    # Open a moment after the server comes up. `open` returns immediately.
    ( sleep 1 && open "$URL" ) &
fi

# Foreground the server so Ctrl-C stops it cleanly.
cd docs
exec python3 -m http.server "$PORT" --bind 127.0.0.1
