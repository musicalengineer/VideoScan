#!/usr/bin/env bash
# Collect code-quality metrics for a single CI run and emit one JSON row
# on stdout. Designed to be redirected into metrics/history.jsonl on the
# dedicated `metrics` branch so time-series charts can plot the trend.
#
# Inputs (all optional — missing inputs produce null values):
#   TestResults.xcresult           — produced by `xcodebuild test`
#   $SWIFTLINT_OUTPUT              — file with raw swiftlint output
#   $PERIPHERY_OUTPUT              — file with raw periphery output
#   $GITHUB_SHA, $GITHUB_REF_NAME  — set by GitHub Actions
#
# Zero external deps beyond xcrun, awk, wc, grep, find — the tools the CI
# runner already has. JSON is hand-assembled; we don't even need jq.

set -u

# ---------- git/run identity ----------
SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
SHORT_SHA="${SHA:0:8}"
BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
TS="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# ---------- coverage (from xccov) ----------
# We want TWO numbers: overall app coverage (xccov's own number) and
# "logic-only" coverage (excluding pure SwiftUI view files). The view files
# are matched by filename suffix.
COV_OVERALL="null"
COV_LOGIC="null"
LOGIC_LINES="null"
LOGIC_COVERED="null"

if [ -d "TestResults.xcresult" ]; then
    # Overall %  (e.g. "6.69% (2107/31493)") — extract the percentage only.
    COV_OVERALL=$(xcrun xccov view --report --only-targets TestResults.xcresult 2>/dev/null \
        | awk '/VideoScan\.app/ { gsub("%",""); print $(NF-2); exit }')
    COV_OVERALL="${COV_OVERALL:-null}"

    # Logic-only: sum covered/total across files that do NOT match view patterns.
    # xccov per-file output:  <path>   <pct>%   (covered/total)
    LOGIC_NUMS=$(xcrun xccov view --report --files-for-target VideoScan.app TestResults.xcresult 2>/dev/null \
        | awk '
            # Skip header lines and separator dashes
            NF < 3 { next }
            $0 ~ /^--/ { next }
            $0 ~ /^ID/ { next }
            # Filter out pure SwiftUI view files — match by filename suffix.
            # Anything ending in View, Window, Sheet, Dashboard, App, or Bar
            # before .swift is considered a view file and excluded.
            $2 ~ /(View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\.swift$/ { next }
            # Field 3 is "pct%", field 4 is "(covered/total)"
            {
                match($4, /\(([0-9]+)\/([0-9]+)\)/, parts)
                if (parts[1] != "" && parts[2] != "") {
                    cov += parts[1]
                    tot += parts[2]
                }
            }
            END {
                if (tot > 0) printf "%d %d %.2f", cov, tot, (cov/tot)*100
                else         printf "0 0 0"
            }')
    LOGIC_COVERED=$(echo "$LOGIC_NUMS" | awk '{print $1}')
    LOGIC_LINES=$(echo "$LOGIC_NUMS"   | awk '{print $2}')
    COV_LOGIC=$(echo "$LOGIC_NUMS"     | awk '{print $3}')
fi

# ---------- SwiftLint ----------
SWIFTLINT_WARN="null"
SWIFTLINT_ERR="null"
if [ -n "${SWIFTLINT_OUTPUT:-}" ] && [ -f "$SWIFTLINT_OUTPUT" ]; then
    SWIFTLINT_WARN=$(grep -c ": warning:" "$SWIFTLINT_OUTPUT" || true)
    SWIFTLINT_ERR=$(grep -c ": error:"   "$SWIFTLINT_OUTPUT" || true)
fi

# ---------- Periphery ----------
PERIPHERY_FINDINGS="null"
if [ -n "${PERIPHERY_OUTPUT:-}" ] && [ -f "$PERIPHERY_OUTPUT" ]; then
    # Periphery's Xcode-format output is one finding per line starting with
    # an absolute path. Filter out progress/info lines.
    PERIPHERY_FINDINGS=$(grep -c "^/" "$PERIPHERY_OUTPUT" || true)
fi

# ---------- LOC + fat-file / fat-function counts ----------
# Pure file/line math — no parsing, so fast and stable.
TOTAL_LINES=0
FILES_OVER_1000=0
WORST_FILE="none"
WORST_FILE_LINES=0

# Scan source trees we care about: app target + tests + swift CLI.
while IFS= read -r f; do
    lines=$(wc -l < "$f" | tr -d ' ')
    TOTAL_LINES=$((TOTAL_LINES + lines))
    if [ "$lines" -gt 1000 ]; then
        FILES_OVER_1000=$((FILES_OVER_1000 + 1))
    fi
    if [ "$lines" -gt "$WORST_FILE_LINES" ]; then
        WORST_FILE_LINES=$lines
        WORST_FILE="$(basename "$f"):$lines"
    fi
done < <(find VideoScan/VideoScan VideoScan/VideoScanTests swift_cli \
             -name '*.swift' -not -path '*/build/*' -not -path '*/.build/*' 2>/dev/null)

# ---------- Test count ----------
# Test count is cheap to derive from the xcresult bundle — but xcrun xcresulttool
# requires knowing the schema, and we don't need it to be perfectly precise
# (a trend is what matters). Count @Test + func testX in the test sources.
TEST_COUNT=$(grep -rEh '^\s*@Test[[:space:](]|^\s*func test[A-Z_]' \
                 VideoScan/VideoScanTests 2>/dev/null | wc -l | tr -d ' ')
TEST_COUNT="${TEST_COUNT:-0}"

# ---------- Emit JSON row ----------
# All numeric fields come from variables that are either a number or the
# literal string "null" — both safely interpolate into JSON.
cat <<JSON
{"ts":"$TS","sha":"$SHORT_SHA","branch":"$BRANCH","coverage_overall_pct":$COV_OVERALL,"coverage_logic_pct":$COV_LOGIC,"logic_lines":$LOGIC_LINES,"logic_covered":$LOGIC_COVERED,"swiftlint_warnings":$SWIFTLINT_WARN,"swiftlint_errors":$SWIFTLINT_ERR,"periphery_findings":$PERIPHERY_FINDINGS,"total_swift_lines":$TOTAL_LINES,"files_over_1000":$FILES_OVER_1000,"worst_file":"$WORST_FILE","test_count":$TEST_COUNT}
JSON
