#!/usr/bin/env bash
# Emit one JSON row for metrics/history.jsonl. Missing optional observations
# (TestResults.xcresult, SWIFTLINT_OUTPUT, PERIPHERY_OUTPUT, gh) are null.
# Uses Python 3's standard library; no pip packages are required.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/collect_metrics.py"
