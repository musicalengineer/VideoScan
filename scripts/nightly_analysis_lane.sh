#!/usr/bin/env bash
# nightly_analysis_lane.sh — the nightly Swift 6 static-analysis lane (the
# "Coverity analogue"; docs/design/swift6_migration_2026_10_25.md §7, GH #376).
#
# Runs on the fleet in the away window after the 02:00 test nightly, never on
# Rick's machine while he works. It VERIFIES and REPORTS; it never commits to
# main and never writes scripts/warnings_baseline.tsv (decision 2026-10-25: the
# merging session lowers the baseline from a slice's clean build logs with
# `warning_ratchet.py update --clean`). Every stage prints ONE line with a
# number (CLAUDE.md rule 9); a stage that prints none is red, and so is the
# lane. The verdict logic is scripts/analysis_lane.py (tested); this file owns
# processes, paths and timeouts only.
#
# Stages (default: ratchet,census,periphery,memsafe; --stages picks; `lint` is opt-in, see below):
#   ratchet    clean Debug `xcodebuild build-for-testing` with the sensor lane's
#              flags + clean `swift build --build-tests -vv` for Core, then
#              warning_ratchet.py check (RED = a regression overnight), progress
#              and categories into the report, and "baseline can be lowered: N"
#              when the clean counts are below the committed baseline.
#   census     escape_hatch_census.py — nonisolated(unsafe), @unchecked Sendable,
#              assumeIsolated, unchecked locks, Unsafe*Pointer, unsafeBitCast,
#              try!, as!, force-unwrap (swiftlint) per target, per-file deltas
#              against the previous night's census (report mode; TODO ratchet).
#   lint       swiftlint analyze (unused_import, unused_declaration) on the clean
#              build's compiler log — counts only. OPT-IN (--stages …,lint):
#              measured 2026-10-25 on the M4, each file's SourceKit index request
#              re-typechecks the whole ~1,400-file app module, so one 70-file
#              folder had not finished after 540 s (unused_import alone) nor
#              1,500 s (both rules) — O(files²) on one big module. Periphery
#              covers unused declarations from the index store in 21 s.
#   periphery  periphery scan --skip-build on the clean build's index store —
#              counts only, third-party excluded.
#   memsafe    a separate Debug build with OTHER_SWIFT_FLAGS=-strict-memory-safety
#              (Swift 6.2+; probed first) into its own DerivedData, plus Core
#              with -Xswiftc -strict-memory-safety; diagnostics counted.
# Optional (--sanitizer thread|address, repeatable; or `auto` = the rota's day):
#   sanitizer  weekly_sanitizer.py --configuration Release --target all
#              [--subset catalog]; TSan or ASan+UBSan findings = RED stage.
#              The two kinds cannot share a build and do not share a night.
#
# Usage:
#   scripts/nightly_analysis_lane.sh                       # the five stages
#   scripts/nightly_analysis_lane.sh --sanitizer thread    # + a TSan pass (Core + app, Release)
#   scripts/nightly_analysis_lane.sh --stages census,periphery --no-wait
#   scripts/nightly_analysis_lane.sh --sanitizer auto --subset catalog
#
# Environment (all optional; the harness scripts/test_nightly_analysis_lane.sh
# uses them to run the real lane against fake tools):
#   VIDEOSCAN_ANALYSIS_REPO        checkout to analyse (default: this script's repo)
#   VIDEOSCAN_ANALYSIS_LOGDIR      state + reports (default ~/Library/Logs/VideoScan/swift6-analysis)
#   VIDEOSCAN_ANALYSIS_DD_ROOT     DerivedData root (default ~/Library/Caches/videoscan-analysis-dd — not /tmp,
#                                  which macOS garbage-collects mid-build; see nightly_local_tests.sh)
#   VIDEOSCAN_ANALYSIS_SKIP_BUILD=1 with VIDEOSCAN_ANALYSIS_APP_LOG / _CORE_LOG: reuse existing clean
#                                  build logs instead of building (dry runs; the report says "reused")
#   VIDEOSCAN_ANALYSIS_BASELINE    a baseline other than scripts/warnings_baseline.tsv (harness only)
#   VIDEOSCAN_ANALYSIS_BUILD_TIMEOUT_SECONDS (5400), VIDEOSCAN_ANALYSIS_TOOL_TIMEOUT_SECONDS (1800),
#   VIDEOSCAN_ANALYSIS_SANITIZER_HOURS (3), VIDEOSCAN_ANALYSIS_WAIT_MINUTES (120)
#
# Outputs under $LOGDIR: <date>.log (this run), <date>/ (tool logs, stage JSON),
# <date>-report.md, latest.json (what session_start.sh and morning_metrics.sh
# read via `analysis_lane.py alert`), runs.jsonl, census.json (previous census).
#
# Budget on the M4 (measured 2026-10-25 unless marked est.): clean Debug
# build-for-testing 1,645–2,764 s (9/10–9/30 nights); swift build --build-tests
# ~5 min est.; census 6 s; periphery --skip-build 21 s; memsafe: Core 35 s
# (466 diagnostics), the app build ≈ another clean build; swiftlint analyze —
# opt-in, see above; TSan full app 78 min (weekly 10/25, Debug), ASan+UBSan
# 75 min (10/24). The four default stages fit in ~1.5–2 h; one sanitizer kind
# adds ~1.5–2.5 h (Release, Core + app); hence one kind per night, by weekday
# (`auto`), and `--subset catalog` (545 app suites + all of Core) when short.
#
# Memory: the lane holds nothing; xcodebuild and swiftlint own their peaks.

set -u

LANE_VERSION="2026-10-25-stage2-r1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${VIDEOSCAN_ANALYSIS_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOGDIR="${VIDEOSCAN_ANALYSIS_LOGDIR:-$HOME/Library/Logs/VideoScan/swift6-analysis}"
DD_ROOT="${VIDEOSCAN_ANALYSIS_DD_ROOT:-$HOME/Library/Caches/videoscan-analysis-dd}"
BUILD_TIMEOUT="${VIDEOSCAN_ANALYSIS_BUILD_TIMEOUT_SECONDS:-5400}"
TOOL_TIMEOUT="${VIDEOSCAN_ANALYSIS_TOOL_TIMEOUT_SECONDS:-1800}"
SANITIZER_HOURS="${VIDEOSCAN_ANALYSIS_SANITIZER_HOURS:-3}"
WAIT_MINUTES="${VIDEOSCAN_ANALYSIS_WAIT_MINUTES:-120}"
GRACE="${VIDEOSCAN_ANALYSIS_TERM_GRACE_SECONDS:-10}"
PY="${VIDEOSCAN_ANALYSIS_PYTHON:-python3}"

STAGES="ratchet,census,periphery,memsafe"
SANITIZERS=""
SUBSET="full"
WAIT=true
while [ $# -gt 0 ]; do
    case "$1" in
        --stages) STAGES="$2"; shift 2 ;;
        --sanitizer) SANITIZERS="$SANITIZERS $2"; shift 2 ;;
        --subset) SUBSET="$2"; shift 2 ;;
        --no-wait) WAIT=false; shift ;;
        -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# `auto`: the rota says which sanitizer runs on which weekday (nightly_rota.json
# "sanitizer": {"Sat": "address", "Sun": "thread"}); other days none.
resolve_sanitizers() {
    local out="" k
    for k in $SANITIZERS; do
        if [ "$k" = "auto" ]; then
            k=$("$PY" - "$REPO/scripts/nightly_rota.json" "$(date +%a)" <<'PY'
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("sanitizer") or {}).get(sys.argv[2], ""))
except Exception:
    print("")
PY
)
            [ -n "$k" ] && out="$out $k"
        else
            out="$out $k"
        fi
    done
    SANITIZERS="$out"
}
resolve_sanitizers

DATE="$(date +%Y-%m-%d)"
RUN_DIR="$LOGDIR/$DATE"
STAGE_DIR="$RUN_DIR/stages"
mkdir -p "$STAGE_DIR"
LOGFILE="$LOGDIR/$DATE.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
# shellcheck source=lib/process_group_watchdog.sh
source "$SCRIPT_DIR/lib/process_group_watchdog.sh"

COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
HOSTNAME_="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
LANE_START=$(date +%s)
log "=== Swift 6 analysis lane v$LANE_VERSION — $HOSTNAME_ — $REPO @ $COMMIT — stages: $STAGES${SANITIZERS:+ + sanitizer:$SANITIZERS} ==="

has_stage() { case ",$STAGES," in *",$1,"*) return 0 ;; esac; return 1; }

# Wait for the test nightly (another xcodebuild) to finish — the fleet runs
# this lane after it, and two builds at once double both their times.
if $WAIT; then
    waited=0
    while pgrep -x xcodebuild >/dev/null 2>&1; do
        if [ "$waited" -ge $((WAIT_MINUTES * 60)) ]; then
            log "another xcodebuild still running after ${WAIT_MINUTES} min — running anyway (times will be inflated)"
            break
        fi
        [ "$waited" -eq 0 ] && log "another xcodebuild is running (the test nightly?) — waiting up to ${WAIT_MINUTES} min"
        sleep 60; waited=$((waited + 60))
    done
fi

# The sensor lane's exact build flags (scripts/sensor_lane.py run_app), minus
# the test-only ones (-only-testing, -parallel-testing-enabled). Same Debug,
# same destination, same signing overrides, ONLY_ACTIVE_ARCH=YES — so the
# warnings here are the warnings every merge is checked against.
APP_BUILD_FLAGS=(-project "$REPO/VideoScan/VideoScan.xcodeproj" -scheme VideoScan -configuration Debug
                 -destination "platform=macOS,arch=arm64" -skip-testing:VideoScanUITests
                 CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= ONLY_ACTIVE_ARCH=YES)

EXPECT=""
add_expect() { EXPECT="${EXPECT:+$EXPECT,}$1"; }
stage_py() {   # stage_py <stage> <args…>: the one line + <stage>.json; never aborts the lane
    "$PY" "$REPO/scripts/analysis_lane.py" --out-dir "$STAGE_DIR" "$@" || true
}

# ── ratchet ─────────────────────────────────────────────────────────
APP_LOG="$RUN_DIR/clean-build-app.log"
CORE_LOG="$RUN_DIR/clean-build-core.log"
RATCHET_DD="$DD_ROOT/ratchet"
CORE_SCRATCH="$DD_ROOT/ratchet-core"
APP_RC=""; CORE_RC=""
if has_stage ratchet || has_stage lint || has_stage periphery; then
    add_expect ratchet
    if [ "${VIDEOSCAN_ANALYSIS_SKIP_BUILD:-0}" = "1" ]; then
        APP_LOG="${VIDEOSCAN_ANALYSIS_APP_LOG:-$APP_LOG}"; CORE_LOG="${VIDEOSCAN_ANALYSIS_CORE_LOG:-$CORE_LOG}"
        APP_RC=0; CORE_RC=0
        log "ratchet: reusing existing build logs (VIDEOSCAN_ANALYSIS_SKIP_BUILD=1): $APP_LOG, $CORE_LOG"
        RATCHET_DD="${VIDEOSCAN_ANALYSIS_DD:-$RATCHET_DD}"
    else
        t0=$(date +%s)
        log "ratchet: CLEAN Debug build-for-testing → $RATCHET_DD (watchdog ${BUILD_TIMEOUT}s)"
        rm -rf "$RATCHET_DD"
        run_with_process_group_watchdog "$BUILD_TIMEOUT" "$GRACE" "$APP_LOG" \
            xcodebuild build-for-testing "${APP_BUILD_FLAGS[@]}" -derivedDataPath "$RATCHET_DD"
        APP_RC=$?
        $NIGHTLY_WATCHDOG_DID_TIMEOUT && APP_RC=124
        log "ratchet: app build rc=$APP_RC in $(( $(date +%s) - t0 ))s"
        t0=$(date +%s)
        log "ratchet: CLEAN swift build --build-tests -vv → $CORE_SCRATCH"
        swift package clean --package-path "$REPO/VideoScan/VideoScanCore" --scratch-path "$CORE_SCRATCH" >/dev/null 2>&1 || true
        run_with_process_group_watchdog "$BUILD_TIMEOUT" "$GRACE" "$CORE_LOG" \
            swift build --build-tests -vv --package-path "$REPO/VideoScan/VideoScanCore" --scratch-path "$CORE_SCRATCH"
        CORE_RC=$?
        $NIGHTLY_WATCHDOG_DID_TIMEOUT && CORE_RC=124
        log "ratchet: Core build rc=$CORE_RC in $(( $(date +%s) - t0 ))s"
    fi
    stage_py ratchet --app-log "$APP_LOG" --core-log "$CORE_LOG" --app-rc "$APP_RC" --core-rc "$CORE_RC" --clean \
        ${VIDEOSCAN_ANALYSIS_BASELINE:+--baseline "$VIDEOSCAN_ANALYSIS_BASELINE"}
fi

# ── census ──────────────────────────────────────────────────────────
if has_stage census; then
    add_expect census
    t0=$(date +%s)
    stage_py census --state "$LOGDIR/census.json"
    log "census done in $(( $(date +%s) - t0 ))s"
fi

# ── lint (swiftlint analyze) ────────────────────────────────────────
if has_stage lint; then
    add_expect lint
    t0=$(date +%s)
    LINT_JSON="$RUN_DIR/swiftlint-analyze.json"
    ANALYZER_CFG="$RUN_DIR/swiftlint-analyzer-rules.yml"
    printf 'analyzer_rules:\n  - unused_import\n  - unused_declaration\n' > "$ANALYZER_CFG"
    if [ -s "$APP_LOG" ]; then
        run_with_process_group_watchdog "$BUILD_TIMEOUT" "$GRACE" "$LINT_JSON" \
            swiftlint analyze --quiet --compiler-log-path "$APP_LOG" \
                --config "$REPO/.swiftlint.yml" --config "$ANALYZER_CFG" --reporter json --force-exclude \
                "$REPO/VideoScan/VideoScan" "$REPO/VideoScan/VideoScanTests" \
                "$REPO/VideoScan/VideoScanCore/Sources" "$REPO/VideoScan/VideoScanCore/Tests"
        LINT_RC=$?
        $NIGHTLY_WATCHDOG_DID_TIMEOUT && LINT_RC=124
    else
        LINT_RC=1; : > "$LINT_JSON"
        log "lint: no compiler log to analyze ($APP_LOG)"
    fi
    stage_py lint --report "$LINT_JSON" --rc "$LINT_RC"
    log "lint done in $(( $(date +%s) - t0 ))s (rc=$LINT_RC)"
fi

# ── periphery ───────────────────────────────────────────────────────
if has_stage periphery; then
    add_expect periphery
    t0=$(date +%s)
    PERIPHERY_JSON="$RUN_DIR/periphery.json"
    INDEX_STORE="$RATCHET_DD/Index.noindex/DataStore"
    if [ -d "$INDEX_STORE" ]; then
        run_with_process_group_watchdog "$TOOL_TIMEOUT" "$GRACE" "$PERIPHERY_JSON" \
            periphery scan --config "$REPO/.periphery.yml" --project "$REPO/VideoScan/VideoScan.xcodeproj" \
                --schemes VideoScan --skip-build --index-store-path "$INDEX_STORE" --format json --quiet
        PERIPHERY_RC=$?
        $NIGHTLY_WATCHDOG_DID_TIMEOUT && PERIPHERY_RC=124
    else
        PERIPHERY_RC=1; : > "$PERIPHERY_JSON"
        log "periphery: no index store at $INDEX_STORE (the clean build did not run or failed)"
    fi
    stage_py periphery --report "$PERIPHERY_JSON" --rc "$PERIPHERY_RC"
    log "periphery done in $(( $(date +%s) - t0 ))s (rc=$PERIPHERY_RC)"
fi

# ── memsafe (-strict-memory-safety) ─────────────────────────────────
if has_stage memsafe; then
    add_expect memsafe
    t0=$(date +%s)
    PROBE_SRC="$RUN_DIR/memsafe-probe.swift"
    PROBE_OUT="$RUN_DIR/memsafe-probe.txt"
    printf 'func peek(_ p: UnsafePointer<Int>) -> Int { p.pointee }\n' > "$PROBE_SRC"
    { xcrun swiftc --version 2>&1 | head -1; xcrun swiftc -typecheck -strict-memory-safety "$PROBE_SRC" 2>&1; } > "$PROBE_OUT"
    PROBE_RC=$?
    MS_APP_LOG="$RUN_DIR/memsafe-app.log"; MS_CORE_LOG="$RUN_DIR/memsafe-core.log"
    MS_APP_RC=""; MS_CORE_RC=""
    if [ "$PROBE_RC" -eq 0 ] && grep -qi 'unsafe' "$PROBE_OUT"; then
        if [ "${VIDEOSCAN_ANALYSIS_SKIP_BUILD:-0}" = "1" ] && [ -n "${VIDEOSCAN_ANALYSIS_MEMSAFE_APP_LOG:-}" ]; then
            MS_APP_LOG="$VIDEOSCAN_ANALYSIS_MEMSAFE_APP_LOG"; MS_CORE_LOG="${VIDEOSCAN_ANALYSIS_MEMSAFE_CORE_LOG:-$MS_CORE_LOG}"
            MS_APP_RC=0; MS_CORE_RC=0
            log "memsafe: reusing existing logs: $MS_APP_LOG, $MS_CORE_LOG"
        else
            MS_DD="$DD_ROOT/memsafe"
            log "memsafe: CLEAN Debug build with -strict-memory-safety → $MS_DD"
            rm -rf "$MS_DD" "$DD_ROOT/memsafe-core"
            run_with_process_group_watchdog "$BUILD_TIMEOUT" "$GRACE" "$MS_APP_LOG" \
                xcodebuild build "${APP_BUILD_FLAGS[@]}" -derivedDataPath "$MS_DD" \
                    OTHER_SWIFT_FLAGS='$(inherited) -strict-memory-safety'
            MS_APP_RC=$?
            $NIGHTLY_WATCHDOG_DID_TIMEOUT && MS_APP_RC=124
            run_with_process_group_watchdog "$BUILD_TIMEOUT" "$GRACE" "$MS_CORE_LOG" \
                swift build --package-path "$REPO/VideoScan/VideoScanCore" --scratch-path "$DD_ROOT/memsafe-core" \
                    -Xswiftc -strict-memory-safety
            MS_CORE_RC=$?
            $NIGHTLY_WATCHDOG_DID_TIMEOUT && MS_CORE_RC=124
        fi
        stage_py memsafe --probe-rc "$PROBE_RC" --probe-out "$PROBE_OUT" --app-log "$MS_APP_LOG" --core-log "$MS_CORE_LOG" \
            --app-rc "$MS_APP_RC" --core-rc "$MS_CORE_RC"
    else
        stage_py memsafe --probe-rc "$PROBE_RC" --probe-out "$PROBE_OUT"
    fi
    log "memsafe done in $(( $(date +%s) - t0 ))s"
fi

# ── sanitizers (optional; one kind per night) ───────────────────────
for KIND in $SANITIZERS; do
    add_expect "sanitizer-$KIND"
    t0=$(date +%s)
    SAN_LOGDIR="${VIDEOSCAN_ANALYSIS_SANITIZER_LOGDIR:-$HOME/Library/Logs/VideoScan/sanitizer}"
    log "sanitizer $KIND: weekly_sanitizer.py --configuration Release --target all --subset $SUBSET (cap ${SANITIZER_HOURS}h)"
    "$PY" "$REPO/scripts/weekly_sanitizer.py" --sanitizer "$KIND" --configuration Release --target all \
        --subset "$SUBSET" --no-wait --timeout-hours "$SANITIZER_HOURS" --source analysis-lane \
        --log-dir "$SAN_LOGDIR" --dd-root "$DD_ROOT/sanitizer" || log "sanitizer $KIND: runner exited $?"
    stage_py sanitizer --kind "$KIND" --row "$SAN_LOGDIR/latest-$KIND.json"
    log "sanitizer $KIND done in $(( $(date +%s) - t0 ))s"
done

# ── report ──────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - LANE_START ))
"$PY" "$REPO/scripts/analysis_lane.py" report --dir "$STAGE_DIR" --expect "$EXPECT" \
    --latest "$LOGDIR/latest.json" --runs "$LOGDIR/runs.jsonl" --markdown "$LOGDIR/$DATE-report.md" \
    --commit "$COMMIT" --host "$HOSTNAME_" --elapsed "$ELAPSED"
RC=$?
log "=== Swift 6 analysis lane done in ${ELAPSED}s — $([ "$RC" -eq 0 ] && echo GREEN || echo RED) — report $LOGDIR/$DATE-report.md ==="
exit "$RC"
