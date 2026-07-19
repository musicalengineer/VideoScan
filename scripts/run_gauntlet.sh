#!/bin/bash
#
# run_gauntlet.sh — build and run the Gauntlet UI-regression flows
# (docs/gauntlet.md) with a bounded watchdog. Interactive/desktop use
# only: XCUITest drives the real screen and needs the Automation/
# Accessibility TCC grant on the invoking terminal.
#
#   ./scripts/run_gauntlet.sh              # all five flows
#   ./scripts/run_gauntlet.sh Gauntlet03SetDateUITests   # one flow
#
# MACHINE POLICY (docs/gauntlet.md): execute on the M1 first. The M4 only
# inside Rick-declared windows (midnight–10:00) — its testmanagerd
# bootstrap for UI-test runners has been flaky, and Rick is usually
# active on it. NEVER run this on a machine someone is using: the test
# owns keyboard/mouse while it runs.
#
# Environment overrides:
#   VS_GAUNTLET_DERIVED_DATA  derived data path (default: dedicated dir
#                             under $TMPDIR — never the shared default DD)
#   VS_GAUNTLET_TIMEOUT       watchdog seconds (default 3600 — flow 1's
#                             Vision scan dominates; cold build adds ~5min)
#   VS_GAUNTLET_FFMPEG        nonstandard ffmpeg path (fixture synthesis)
#
# Exit codes: 0 = passed, 1 = failed/build error, 2 = watchdog timeout,
#             3 = automation (TCC) not granted.
#
# Configuration: Debug, per the project build-mode policy — the Gauntlet
# validates UI FLOWS, not optimizer behavior; production-parity suites
# (TestDriver Smoke/Diagnostic, CI, perf) stay Release.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/VideoScan/VideoScan.xcodeproj"
DERIVED_DATA="${VS_GAUNTLET_DERIVED_DATA:-${TMPDIR:-/tmp}/videoscan-gauntlet-dd}"
TIMEOUT_S="${VS_GAUNTLET_TIMEOUT:-3600}"
LOG_FILE="$DERIVED_DATA/gauntlet_$(date +%Y%m%d_%H%M%S).log"
ONLY_CLASS="${1:-}"

mkdir -p "$DERIVED_DATA"

EXTRA_ARGS=()
if [ -n "$ONLY_CLASS" ]; then
    EXTRA_ARGS+=("-only-testing:VideoScanUITests/$ONLY_CLASS")
fi

echo "== VideoScan Gauntlet =="
echo "   project:      $PROJECT"
echo "   derived data: $DERIVED_DATA"
echo "   watchdog:     ${TIMEOUT_S}s"
echo "   selection:    ${ONLY_CLASS:-all five flows}"
echo "   log:          $LOG_FILE"
echo

xcodebuild test \
    -project "$PROJECT" \
    -scheme VideoScan \
    -testPlan VideoScan-Gauntlet \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${EXTRA_ARGS[@]}" \
    TEST_RUNNER_VS_GAUNTLET=1 \
    > "$LOG_FILE" 2>&1 &
XB_PID=$!

SECONDS_WAITED=0
while kill -0 "$XB_PID" 2>/dev/null; do
    if [ "$SECONDS_WAITED" -ge "$TIMEOUT_S" ]; then
        echo "✗ TIMEOUT after ${TIMEOUT_S}s — killing xcodebuild (pid $XB_PID)"
        kill -TERM "$XB_PID" 2>/dev/null
        sleep 5
        kill -KILL "$XB_PID" 2>/dev/null
        echo "  Last 20 log lines:"
        tail -20 "$LOG_FILE" | sed 's/^/  | /'
        exit 2
    fi
    sleep 5
    SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

wait "$XB_PID"
XB_STATUS=$?

if grep -q "Timed out while enabling automation mode" "$LOG_FILE"; then
    echo "✗ AUTOMATION PERMISSION NEEDED (not a code failure)."
    echo "  Grant Accessibility/Automation to this terminal in System"
    echo "  Settings › Privacy & Security, then rerun."
    exit 3
fi

if grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG_FILE"; then
    echo "✓ GAUNTLET PASSED"
    grep -E "Test case '.*' (passed|failed)|Test Suite 'Gauntlet" "$LOG_FILE" | sed 's/^/  | /'
    exit 0
fi

echo "✗ GAUNTLET FAILED (xcodebuild exit $XB_STATUS)"
echo "  Failures / errors:"
grep -E "error:|failed|Failing" "$LOG_FILE" | head -20 | sed 's/^/  | /'
echo "  Full log: $LOG_FILE"
echo "  Screenshots: in the .xcresult under $DERIVED_DATA/Logs/Test/"
exit 1
