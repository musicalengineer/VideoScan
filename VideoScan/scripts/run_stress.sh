#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

FILE_COUNT="${1:-250}"
DURATION="${2:-2.0}"

echo "Running generated-media stress benchmark..."
echo "  Files:    $FILE_COUNT"
echo "  Duration: $DURATION seconds each"
echo

scripts/run_generated_media_perf.sh --file-count "$FILE_COUNT" --duration "$DURATION"
