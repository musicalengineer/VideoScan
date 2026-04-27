#!/usr/bin/env bash
# Collect metrics locally and push to the metrics branch on origin.
# No CI needed — just run: scripts/push_metrics.sh
#
# Prerequisites: xcodebuild test results in TestResults.xcresult (optional).
# Without it, coverage fields will be null but everything else works.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "Collecting metrics…"
ROW=$(bash scripts/collect_metrics.sh)
echo "$ROW" | python3 -m json.tool > /dev/null 2>&1 || { echo "ERROR: invalid JSON from collect_metrics.sh"; exit 1; }
echo "  $ROW"

# Fetch latest metrics branch
echo "Fetching origin/metrics…"
git fetch origin metrics 2>/dev/null || true

# Create a temp worktree for the metrics branch
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'" EXIT

if git rev-parse origin/metrics >/dev/null 2>&1; then
    git worktree add "$TMPDIR" origin/metrics --detach --quiet
    cd "$TMPDIR"
    git checkout -B metrics origin/metrics --quiet
else
    git worktree add "$TMPDIR" --detach --quiet
    cd "$TMPDIR"
    git checkout --orphan metrics --quiet
    git rm -rf . --quiet 2>/dev/null || true
    mkdir -p metrics
fi

# Append the new row
echo "$ROW" >> metrics/history.jsonl
git add metrics/history.jsonl

SHA=$(cd "$REPO_ROOT" && git rev-parse --short HEAD)
git commit -m "metrics: ${SHA} on main [skip ci]" --quiet

echo "Pushing to origin/metrics…"
git push origin metrics --quiet

cd "$REPO_ROOT"
git worktree remove "$TMPDIR" --force 2>/dev/null || true

echo "Done. Run scripts/dashboard.sh to view."
