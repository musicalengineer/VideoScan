#!/usr/bin/env bash
# test_nightly_analysis_lane.sh — the Swift 6 nightly analysis lane's failure
# modes, end to end, with fake tools (stage 2, 2026-10-25). Precedent:
# scripts/test_nightly_failure_modes.sh.
#
# The REAL scripts/nightly_analysis_lane.sh runs in a sandbox LOGDIR against
# this checkout, with fake xcodebuild / swift / swiftlint / periphery / xcrun
# on PATH and existing "clean build" logs reused (VIDEOSCAN_ANALYSIS_SKIP_BUILD).
# Nothing compiles. Pins (CLAUDE.md rule 9 and the 2026-10-25 decision):
#   1. a green night: every stage prints one line with a number, latest.json
#      says ok, runs.jsonl grows by one, the report carries the numbers, and
#      the baseline file is NEVER written — the lane says "can be lowered"
#   2. a missing build log → red
#   3. a warning regression overnight → red, the file named
#   4. a sanitizer finding → red (Core half red, app half green)
#   5. a stage whose tool printed nothing → red ("printed no number")
#   6. an unsupported -strict-memory-safety toolchain → 🟡, not red
#   7. --sanitizer auto resolves from the rota's weekday map
#   8. the installer honours the rota: M4 at its slot, M1 removed, unknown refused
#
# Usage:  scripts/test_nightly_analysis_lane.sh      Exit 0 = all pass.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX="${TMPDIR:-/tmp}/analysis-lane-harness-$$"
mkdir -p "$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT
FAILS=0; PASSES=0; RESULTS=()
pass() { PASSES=$((PASSES + 1)); RESULTS+=("PASS: $*"); echo "  PASS: $*"; }
fail() { FAILS=$((FAILS + 1));  RESULTS+=("FAIL: $*"); echo "  FAIL: $*"; }

# ── fakes ────────────────────────────────────────────────────────────
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
# swiftlint: `lint --only-rule force_unwrapping` (census) and `analyze` both answer "[]".
printf '%s\n' '#!/bin/sh' 'echo "[]"' > "$BIN/swiftlint"
# periphery: "[]" unless FAKE_PERIPHERY_SILENT is set (test 5: a tool that prints nothing).
printf '%s\n' '#!/bin/sh' '[ -n "${FAKE_PERIPHERY_SILENT:-}" ] && exit 0' 'echo "[]"' > "$BIN/periphery"
# xcrun swiftc --version / -typecheck -strict-memory-safety: supported unless FAKE_MEMSAFE_UNSUPPORTED.
printf '%s\n' '#!/bin/sh' \
    'case "$*" in *--version*) echo "Apple Swift version 6.4 (fake)"; exit 0;; esac' \
    'if [ -n "${FAKE_MEMSAFE_UNSUPPORTED:-}" ]; then echo "error: unknown argument: -strict-memory-safety" >&2; exit 1; fi' \
    'echo "probe.swift:1:45: warning: expression uses unsafe constructs but is not marked with '"'"'unsafe'"'"' [#StrictMemorySafety]"' > "$BIN/xcrun"
# xcodebuild: `build` (memsafe) prints a log with one StrictMemorySafety warning in a REAL repo file;
# `test` (sanitizer app half) prints a green Swift Testing run.
A_SWIFT="$REPO/VideoScan/VideoScan/App/VideoScanApp.swift"
[ -f "$A_SWIFT" ] || A_SWIFT="$(find "$REPO/VideoScan/VideoScan" -name '*.swift' | head -1)"
cat > "$BIN/xcodebuild" <<EOF
#!/bin/sh
case "\$1" in
  build) echo "SwiftCompile normal arm64 Compiling\\\\ x.swift $A_SWIFT (in target 'VideoScan' from project 'VideoScan')"
         echo "$A_SWIFT:12:9: warning: expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]"
         echo "** BUILD SUCCEEDED **" ;;
  test)  echo "✔ Test run with 12 tests in 2 suites passed after 1.0 seconds."; echo "** TEST SUCCEEDED **" ;;
esac
exit 0
EOF
# swift: `build` (memsafe Core) clean; `test` (sanitizer Core half) carries a TSan race when FAKE_TSAN_RACE.
cat > "$BIN/swift" <<'EOF'
#!/bin/sh
case "$1" in
  test) if [ -n "${FAKE_TSAN_RACE:-}" ]; then
          echo "WARNING: ThreadSanitizer: data race (pid=7)"; echo "SUMMARY: ThreadSanitizer: data race Store.swift:9 in commit"
        fi
        printf '\t Executed 5 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n' ;;
  build) echo "Compile X.swift" ;;
esac
exit 0
EOF
chmod +x "$BIN"/*

# ── fixtures: a tiny baseline and "clean build" logs around one real file ──
B_SWIFT="$A_SWIFT"
B_REL="${B_SWIFT#$REPO/}"
BASE2="$SANDBOX/baseline-2.tsv"
printf '# start_total 2\n# recorded 2026-10-25\n# total 2\n# count<TAB>category<TAB>path\n2\tdeprecated\t%s\n' "$B_REL" > "$BASE2"
COMPILE_LINE="SwiftCompile normal arm64 Compiling\\ x.swift $B_SWIFT (in target 'VideoScan' from project 'VideoScan')"
APP_LOG_1="$SANDBOX/app-1-warning.log"
printf '%s\n%s:10:5: warning: '"'"'foo'"'"' is deprecated\n** BUILD SUCCEEDED **\n' "$COMPILE_LINE" "$B_SWIFT" > "$APP_LOG_1"
APP_LOG_3="$SANDBOX/app-3-warnings.log"
printf '%s\n%s:10:5: warning: '"'"'foo'"'"' is deprecated\n%s:11:5: warning: '"'"'foo'"'"' is deprecated\n%s:12:5: warning: '"'"'foo'"'"' is deprecated\n' \
    "$COMPILE_LINE" "$B_SWIFT" "$B_SWIFT" "$B_SWIFT" > "$APP_LOG_3"
CORE_LOG="$SANDBOX/core.log"
printf 'Compile RollCallTests.swift\n' > "$CORE_LOG"

run_lane() {   # run_lane <logdir> <args…>; env from the caller; output in <logdir>/harness-stdout.txt
    local logdir="$1"; shift
    mkdir -p "$logdir"
    ( export PATH="$BIN:$PATH"
      export VIDEOSCAN_ANALYSIS_REPO="$REPO" VIDEOSCAN_ANALYSIS_LOGDIR="$logdir" VIDEOSCAN_ANALYSIS_DD_ROOT="$logdir/dd"
      export VIDEOSCAN_ANALYSIS_SKIP_BUILD=1 VIDEOSCAN_ANALYSIS_DD="$logdir/dd/ratchet"
      export VIDEOSCAN_ANALYSIS_SANITIZER_LOGDIR="$logdir/sanitizer"
      export VIDEOSCAN_ANALYSIS_BUILD_TIMEOUT_SECONDS=60 VIDEOSCAN_ANALYSIS_TOOL_TIMEOUT_SECONDS=60
      bash "$SCRIPT_DIR/nightly_analysis_lane.sh" --no-wait "$@" ) > "$logdir/harness-stdout.txt" 2>&1
}
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2" 2>/dev/null; }
# periphery needs an index store directory to run at all
mk_index() { mkdir -p "$1/dd/ratchet/Index.noindex/DataStore"; }

# ── Test 1: a green night ───────────────────────────────────────────
echo "== Test 1: green night — numbers, latest.json, runs.jsonl, report, baseline untouched =="
L1="$SANDBOX/run1"; mk_index "$L1"
BASE_BEFORE="$(cat "$BASE2")"
VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L1" --stages ratchet,census,lint,periphery,memsafe
RC1=$?
OUT1="$L1/harness-stdout.txt"
if [ "$RC1" -eq 0 ] && [ "$(field "$L1/latest.json" 'd["status"]')" = "ok" ]; then
    pass "green night exits 0 and latest.json says ok"
else
    fail "green night: rc=$RC1 status=$(field "$L1/latest.json" 'd["status"]') — $(tail -5 "$OUT1" | tr '\n' ' ')"
fi
for stage in ratchet census lint periphery memsafe; do
    n=$(field "$L1/latest.json" "d['stages']['$stage']['number']")
    case "$n" in ''|None|*[!0-9]*) fail "$stage printed no integer number (got '$n')" ;; *) pass "$stage printed a number ($n)" ;; esac
done
grep -q 'baseline can be lowered: 2 → 1' "$OUT1" && pass "a clean build below the baseline says 'baseline can be lowered: 2 → 1'" \
    || fail "lowerable message missing: $(grep '^ratchet:' "$OUT1")"
[ "$(cat "$BASE2")" = "$BASE_BEFORE" ] && pass "the baseline file was not written (the nightly reports; the merging session lowers)" \
    || fail "the lane WROTE the baseline"
[ "$(wc -l < "$L1/runs.jsonl" | tr -d ' ')" = "1" ] && pass "runs.jsonl has one row" || fail "runs.jsonl rows: $(wc -l < "$L1/runs.jsonl")"
REPORT="$(ls "$L1"/*-report.md 2>/dev/null | head -1)"
if [ -n "$REPORT" ] && grep -q '^- ratchet: 1 warning' "$REPORT" && grep -q '^- escape hatches:' "$REPORT" \
   && grep -q '^- memsafe: 1 -strict-memory-safety' "$REPORT" && grep -q 'Swift 6 progress' "$REPORT"; then
    pass "the markdown report carries every stage line and the progress block"
else
    fail "report incomplete: $REPORT"
fi
ALERT="$(python3 "$SCRIPT_DIR/analysis_lane.py" alert --latest "$L1/latest.json")"
case "$ALERT" in 🟢*"ratchet 1"*) pass "alert prints the green headline with the numbers" ;; *) fail "alert: '$ALERT'" ;; esac
[ -s "$L1/census.json" ] && pass "the census was persisted for tomorrow's deltas" || fail "census.json missing"

# ── Test 2: a missing build log ─────────────────────────────────────
echo "== Test 2: missing Core build log → red =="
L2="$SANDBOX/run2"; mk_index "$L2"
VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$SANDBOX/absent-core.log" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L2" --stages ratchet
RC2=$?
if [ "$RC2" -ne 0 ] && [ "$(field "$L2/latest.json" 'd["status"]')" = "red" ] && grep -q 'Core log missing' "$L2/harness-stdout.txt"; then
    pass "missing Core log → lane red, reason names the log"
else
    fail "missing log: rc=$RC2 $(grep -E '^ratchet|✘' "$L2/harness-stdout.txt" | tr '\n' ' ')"
fi

# ── Test 3: a regression overnight ──────────────────────────────────
echo "== Test 3: warning regression → red, file named =="
L3="$SANDBOX/run3"; mk_index "$L3"
VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_3" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L3" --stages ratchet
RC3=$?
if [ "$RC3" -ne 0 ] && grep -q 'ratchet: 3 warning(s) in 1 file(s) — RED' "$L3/harness-stdout.txt" \
   && grep -q "$B_REL \[deprecated\]: 3 warning(s), baseline 2 (+1)" "$L3/harness-stdout.txt"; then
    pass "3 warnings against a baseline of 2 → red with the file and category"
else
    fail "regression: rc=$RC3 $(grep -E '^ratchet|baseline' "$L3/harness-stdout.txt" | tr '\n' ' ')"
fi

# ── Test 4: a sanitizer finding ─────────────────────────────────────
echo "== Test 4: TSan finding in the Core half → red stage, lane red =="
L4="$SANDBOX/run4"; mk_index "$L4"
FAKE_TSAN_RACE=1 VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L4" --stages census --sanitizer thread
RC4=$?
ROW="$L4/sanitizer/latest-thread.json"
if [ "$RC4" -ne 0 ] && [ "$(field "$ROW" 'd["status"]')" = "findings" ] \
   && [ "$(field "$ROW" 'd["per_target"]["app"]["status"]')" = "ok" ] \
   && [ "$(field "$ROW" 'd["configuration"]+":"+",".join(d["targets"])')" = "Release:app,core" ] \
   && grep -q 'sanitizer thread: 1 unique finding(s), 17 tests (app,core, Release, full) — RED: findings' "$L4/harness-stdout.txt"; then
    pass "TSan race → Release Core+app row with findings; stage line red; lane red"
else
    fail "sanitizer: rc=$RC4 $(grep -E '^sanitizer' "$L4/harness-stdout.txt" | tr '\n' ' ') row=$(cat "$ROW" 2>/dev/null | head -c 300)"
fi
L4b="$SANDBOX/run4b"; mk_index "$L4b"
VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L4b" --stages census --sanitizer thread --subset catalog
RC4b=$?
SEL=$(field "$L4b/sanitizer/latest-thread.json" 'd.get("selected_suites")')
if [ "$RC4b" -eq 0 ] && [ "${SEL:-0}" -ge 200 ] 2>/dev/null; then
    pass "no race → green; --subset catalog selected $SEL app suites from the gauntlet manifest"
else
    fail "clean sanitizer / subset: rc=$RC4b selected=$SEL $(grep -E '^sanitizer' "$L4b/harness-stdout.txt" | tr '\n' ' ')"
fi

# ── Test 5: a tool that prints nothing ──────────────────────────────
echo "== Test 5: periphery prints nothing → 'printed no number' → red =="
L5="$SANDBOX/run5"; mk_index "$L5"
FAKE_PERIPHERY_SILENT=1 VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L5" --stages periphery
RC5=$?
if [ "$RC5" -ne 0 ] && grep -q 'periphery: printed no number' "$L5/harness-stdout.txt"; then
    pass "a stage with no number is red, by name"
else
    fail "silent tool: rc=$RC5 $(grep -E 'periphery' "$L5/harness-stdout.txt" | tr '\n' ' ')"
fi

# ── Test 6: unsupported -strict-memory-safety ───────────────────────
echo "== Test 6: toolchain rejects -strict-memory-safety → 🟡, lane not red =="
L6="$SANDBOX/run6"; mk_index "$L6"
FAKE_MEMSAFE_UNSUPPORTED=1 VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L6" --stages memsafe
RC6=$?
if [ "$RC6" -eq 0 ] && [ "$(field "$L6/latest.json" 'd["status"]')" = "yellow" ] && grep -q 'memsafe: n/a — this swiftc rejects' "$L6/harness-stdout.txt"; then
    pass "unsupported flag reads 🟡 with the measured reason, never green, never red"
else
    fail "memsafe unsupported: rc=$RC6 status=$(field "$L6/latest.json" 'd["status"]') $(grep '^memsafe' "$L6/harness-stdout.txt")"
fi

# ── Test 7: --sanitizer auto from the rota ──────────────────────────
echo "== Test 7: --sanitizer auto resolves the weekday from nightly_rota.json =="
EXPECT_KIND=$(python3 -c 'import json,sys,datetime; print((json.load(open(sys.argv[1])).get("sanitizer") or {}).get(datetime.date.today().strftime("%a"), ""))' "$REPO/scripts/nightly_rota.json")
L7="$SANDBOX/run7"; mk_index "$L7"
VIDEOSCAN_ANALYSIS_APP_LOG="$APP_LOG_1" VIDEOSCAN_ANALYSIS_CORE_LOG="$CORE_LOG" VIDEOSCAN_ANALYSIS_BASELINE="$BASE2" \
    run_lane "$L7" --stages census --sanitizer auto
HAS=$(field "$L7/latest.json" '",".join(k for k in d["stages"] if k.startswith("sanitizer-"))')
if [ -z "$EXPECT_KIND" ] && [ -z "$HAS" ]; then
    pass "today ($(date +%a)) has no sanitizer in the rota → no sanitizer stage"
elif [ -n "$EXPECT_KIND" ] && [ "$HAS" = "sanitizer-$EXPECT_KIND" ]; then
    pass "today ($(date +%a)) → sanitizer-$EXPECT_KIND from the rota"
else
    fail "auto resolution: expected '$EXPECT_KIND', stages '$HAS'"
fi
[ "$(python3 "$SCRIPT_DIR/nightly_rota.py" analysis RicksM4)" = "on 4 30" ] && [ "$(python3 "$SCRIPT_DIR/nightly_rota.py" analysis RicksM1 | cut -c1-4)" = "off " ] \
    && [ "$(python3 "$SCRIPT_DIR/nightly_rota.py" analysis Nobody)" = "unknown" ] \
    && pass "nightly_rota.py analysis: M4 04:30, M1 off, unknown otherwise" || fail "nightly_rota.py analysis slots"

# ── Test 8: the installer ───────────────────────────────────────────
echo "== Test 8: install_analysis_lane.sh honours the rota =="
RT="$SANDBOX/rota"; mkdir -p "$RT/scripts" "$RT/bin" "$RT/home/Library/LaunchAgents"
cp "$SCRIPT_DIR/install_analysis_lane.sh" "$SCRIPT_DIR/nightly_rota.py" "$SCRIPT_DIR/nightly_rota.json" "$SCRIPT_DIR/nightly_analysis_lane.sh" "$RT/scripts/"
printf '%s\n' '#!/bin/sh' 'echo "$FAKE_HOST"' > "$RT/bin/scutil"
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_LAUNCHCTL_LOG"' > "$RT/bin/launchctl"
chmod +x "$RT/bin"/*
inst() { : > "$RT/launchctl.log"; HOME="$RT/home" FAKE_HOST="$1" FAKE_LAUNCHCTL_LOG="$RT/launchctl.log" PATH="$RT/bin:$PATH" \
         bash "$RT/scripts/install_analysis_lane.sh" ${2:+"$2"} > "$RT/out.log" 2>&1; }
PL="$RT/home/Library/LaunchAgents/com.videoscan.swift6-analysis.plist"
inst RicksM4; IRC=$?
if [ "$IRC" -eq 0 ] && [ "$(plutil -extract StartCalendarInterval.Hour raw "$PL" 2>/dev/null)" = "4" ] \
   && [ "$(plutil -extract StartCalendarInterval.Minute raw "$PL" 2>/dev/null)" = "30" ] && grep -q '<string>auto</string>' "$PL"; then
    pass "M4 installed at 04:30 with --sanitizer auto"
else
    fail "M4 install: rc=$IRC $(cat "$RT/out.log" | tr '\n' ' ')"
fi
inst RicksM4 --no-sanitizer
grep -q '<string>auto</string>' "$PL" && fail "--no-sanitizer still passes auto" || pass "--no-sanitizer installs the five stages only"
inst RicksM1; IRC=$?
if [ "$IRC" -eq 0 ] && grep -q '^bootout gui/.*/com.videoscan.swift6-analysis$' "$RT/launchctl.log" && [ ! -e "$PL" ] && [ -e "$PL.off-rota" ]; then
    pass "an off-rota Mac has the job removed and the plist moved aside"
else
    fail "M1 install: rc=$IRC $(cat "$RT/out.log" "$RT/launchctl.log" | tr '\n' ' ')"
fi
inst Nobody; IRC=$?
[ "$IRC" -ne 0 ] && grep -q 'no "analysis" slot' "$RT/out.log" && pass "a Mac with no analysis slot is refused" || fail "unknown host: rc=$IRC"

# ── Summary ─────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════"
echo "Tests passed: $PASSES"
echo "Tests failed: $FAILS"
echo "════════════════════════════════════════════════════════════════"
if [ "$FAILS" -gt 0 ]; then
    for r in "${RESULTS[@]}"; do case "$r" in FAIL:*) echo "  $r" ;; esac; done
    exit 1
fi
exit 0
