#!/usr/bin/env bash
#
# Render a markdown test summary from an .xcresult bundle into
# GITHUB_STEP_SUMMARY. Designed for CI — but also runnable locally:
#
#   GITHUB_STEP_SUMMARY=/tmp/summary.md ./scripts/ci_test_summary.sh \
#     TestResults.xcresult
#
# Output: one big green line on a clean run; a count line + collapsible
# failure detail (with the assertion text) on a red run.

set -euo pipefail

XCRESULT="${1:-TestResults.xcresult}"
OUT="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ ! -d "$XCRESULT" ]; then
    {
        echo "## ⚠️ No test results found"
        echo ""
        echo "\`$XCRESULT\` does not exist — xcodebuild may have failed before tests ran."
    } >> "$OUT"
    exit 0
fi

# Parse xcresult into JSON. xcresulttool ships with Xcode.
SUMMARY_JSON=$(xcrun xcresulttool get test-results summary --path "$XCRESULT" --compact 2>/dev/null) || {
    echo "## ⚠️ xcresulttool failed to parse $XCRESULT" >> "$OUT"
    exit 0
}

PASSED=$(echo "$SUMMARY_JSON" | jq -r '.passedTests // 0')
FAILED=$(echo "$SUMMARY_JSON" | jq -r '.failedTests // 0')
SKIPPED=$(echo "$SUMMARY_JSON" | jq -r '.skippedTests // 0')
TOTAL=$(echo "$SUMMARY_JSON" | jq -r '.totalTestCount // 0')

{
    if [ "$FAILED" = "0" ]; then
        echo "## ✅ All $PASSED tests passed"
        if [ "$SKIPPED" != "0" ]; then
            echo ""
            echo "_($SKIPPED skipped)_"
        fi
    else
        echo "## ❌ $FAILED failed · ✅ $PASSED passed · total $TOTAL"
        if [ "$SKIPPED" != "0" ]; then
            echo ""
            echo "_($SKIPPED skipped)_"
        fi
        echo ""
        echo "### Failures"
        echo ""
        echo "$SUMMARY_JSON" | jq -r '
            .testFailures[]
            | "<details><summary>❌ <code>\(.testIdentifierString)</code></summary>\n\n```\n\(.failureText)\n```\n\n</details>\n"
        '
    fi
} >> "$OUT"
