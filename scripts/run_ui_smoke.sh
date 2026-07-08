#!/bin/bash
#
# run_ui_smoke.sh — build and run ONLY the UI smoke test (SmokeUITests)
# with a bounded watchdog. Interactive/daytime use only — UI tests drive
# the real screen and need the Automation/Accessibility TCC grant.
#
#   ./scripts/run_ui_smoke.sh
#
# Environment overrides:
#   VS_UI_SMOKE_DERIVED_DATA  derived data path (default: a dedicated dir
#                             under $TMPDIR — never the shared default DD,
#                             never XcodeRAM, so parallel agent builds are
#                             unaffected)
#   VS_UI_SMOKE_TIMEOUT       overall watchdog seconds (default 900 — a
#                             cold Debug build of the app + both test
#                             bundles dominates; the test itself is <60s)
#
# Exit codes: 0 = test passed, 1 = test failed / build error,
#             2 = watchdog timeout, 3 = automation (TCC) not granted.
#
# Notes:
#  * -configuration Debug per the project build-mode policy (the scheme's
#    Test action defaults to Release, ~3 min whole-module rebuilds).
#  * The VideoScan-UI test plan selects only SmokeUITests and sets
#    VS_UI_SMOKE=1 on the runner; TEST_RUNNER_VS_UI_SMOKE=1 below is
#    belt-and-suspenders for the self-skip gate in SmokeUITests.setUp.
#  * If this fails with "Timed out while enabling automation mode", that
#    is NOT a code failure — macOS is waiting for you to approve the
#    Automation/Accessibility prompt (System Settings › Privacy &
#    Security) for the terminal/Xcode helper running the test.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/VideoScan/VideoScan.xcodeproj"
DERIVED_DATA="${VS_UI_SMOKE_DERIVED_DATA:-${TMPDIR:-/tmp}/videoscan-ui-smoke-dd}"
TIMEOUT_S="${VS_UI_SMOKE_TIMEOUT:-900}"
LOG_FILE="$DERIVED_DATA/ui_smoke_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "$DERIVED_DATA"

echo "== VideoScan UI smoke =="
echo "   project:      $PROJECT"
echo "   derived data: $DERIVED_DATA"
echo "   watchdog:     ${TIMEOUT_S}s"
echo "   log:          $LOG_FILE"
echo

xcodebuild test \
    -project "$PROJECT" \
    -scheme VideoScan \
    -testPlan VideoScan-UI \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    TEST_RUNNER_VS_UI_SMOKE=1 \
    > "$LOG_FILE" 2>&1 &
XB_PID=$!

# Watchdog — kill the whole xcodebuild process group on timeout so a hung
# automation handshake can't wedge the invoking shell forever.
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
    echo "  macOS blocked UI automation. Approve the pending prompt, or grant"
    echo "  Accessibility/Automation to your terminal in System Settings ›"
    echo "  Privacy & Security, then rerun this script."
    exit 3
fi

if grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG_FILE"; then
    echo "✓ UI SMOKE PASSED"
    grep -E "Test case '.*' (passed|failed)|Test Suite 'SmokeUITests'" "$LOG_FILE" | sed 's/^/  | /'
    exit 0
fi

echo "✗ UI SMOKE FAILED (xcodebuild exit $XB_STATUS)"
echo "  Failures / errors:"
grep -E "error:|failed|Failing" "$LOG_FILE" | head -20 | sed 's/^/  | /'
echo "  Full log: $LOG_FILE"
exit 1
