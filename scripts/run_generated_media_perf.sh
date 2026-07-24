#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FILE_COUNT="${VIDEOSCAN_PERF_FILE_COUNT:-12}"
DURATION="${VIDEOSCAN_PERF_DURATION:-1.5}"
TIME_LIMIT_MIN="${VIDEOSCAN_PERF_TIME_LIMIT_MIN:-10}"
VERBOSE="${VIDEOSCAN_PERF_VERBOSE:-0}"

# Stable copy of the most recent successful results, for tooling that wants
# a fixed path. The authoritative per-run copy lives in the mktemp run dir.
STABLE_RESULTS="/tmp/videoscan_perf_results.txt"

usage() {
  cat <<'USAGE'
Usage: scripts/run_generated_media_perf.sh [options]

Options:
  --verbose                 Show full xcodebuild output.
  --file-count N            Generate N benchmark media files. Default: 12.
  --duration SECONDS        Duration of each generated media file. Default: 1.5.
  --time-limit MINUTES      Per-test time limit. Default: 10. Large corpora
                            (hundreds of files or long durations) need more.
  --help                    Show this help.

Examples:
  scripts/run_generated_media_perf.sh
  scripts/run_generated_media_perf.sh --verbose
  scripts/run_generated_media_perf.sh --file-count 100 --duration 2.0
  scripts/run_generated_media_perf.sh --file-count 1000 --duration 10 --time-limit 60

Each run uses its own temp directory (results + xcodebuild log paths are
printed at start), so concurrent runs don't interfere. On success the results
are also copied to /tmp/videoscan_perf_results.txt.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=1
      shift
      ;;
    --file-count)
      if [[ $# -lt 2 ]]; then
        echo "error: --file-count requires a value" >&2
        usage >&2
        exit 2
      fi
      FILE_COUNT="$2"
      shift 2
      ;;
    --duration)
      if [[ $# -lt 2 ]]; then
        echo "error: --duration requires a value" >&2
        usage >&2
        exit 2
      fi
      DURATION="$2"
      shift 2
      ;;
    --time-limit)
      if [[ $# -lt 2 ]]; then
        echo "error: --time-limit requires a value" >&2
        usage >&2
        exit 2
      fi
      TIME_LIMIT_MIN="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/videoscan_perf.XXXXXX")"
RESULTS="$RUN_DIR/results.txt"
XCODEBUILD_LOG="$RUN_DIR/xcodebuild.log"

cd "$ROOT"

# Configuration reaches the test host via TEST_RUNNER_* variables — xcodebuild
# strips the prefix and injects them into the test runner's environment. No
# shared marker files, so concurrent runs can't sabotage each other.
cmd=(
  env
  "TEST_RUNNER_VIDEOSCAN_PERF=1"
  "TEST_RUNNER_VIDEOSCAN_PERF_FILE_COUNT=$FILE_COUNT"
  "TEST_RUNNER_VIDEOSCAN_PERF_DURATION=$DURATION"
  "TEST_RUNNER_VIDEOSCAN_PERF_TIME_LIMIT_MIN=$TIME_LIMIT_MIN"
  "TEST_RUNNER_VIDEOSCAN_PERF_RESULTS=$RESULTS"
  xcodebuild test
  -project VideoScan/VideoScan.xcodeproj
  -scheme VideoScan
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath .derivedData
  -parallel-testing-enabled NO
  -maximum-concurrent-test-device-destinations 1
  -only-testing:VideoScanTests/GeneratedMediaPerformanceTests
)

echo "VideoScan generated-media performance benchmarks"
echo "  Worktree:   $ROOT"
echo "  Corpus:     $FILE_COUNT generated file(s), ${DURATION}s each"
echo "  Time limit: ${TIME_LIMIT_MIN} min/test"
echo "  Results:    $RESULTS"
echo "  Full log:   $XCODEBUILD_LOG"
echo

status=0
if [[ "$VERBOSE" == "1" ]]; then
  echo "Running xcodebuild with full verbose output..."
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG" || status=$?
else
  echo "Running xcodebuild. Showing benchmark progress only; pass --verbose for full build output."
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG" | awk '
    /Test .*started/ ||
    /Test .*passed/ ||
    /Test .*failed/ ||
    /Test run with/ ||
    /Executed [0-9]+ tests/ ||
    /Time limit/ ||
    /Suite .*started/ ||
    /Suite .*passed/ ||
    /VIDEOSCAN_PERF/ ||
    /Generated media performance results/ ||
    /\*\* TEST/ ||
    /Testing failed/ ||
    /error:/ { print }
  ' || status=$?
fi

echo

# Guard: a "passing" xcodebuild run that skipped the benchmarks (or a run that
# died before measuring) must not look like success or reprint stale numbers.
if [[ ! -s "$RESULTS" ]] || ! grep -q "VIDEOSCAN_PERF" "$RESULTS"; then
  echo "error: no benchmark measurements were produced (results file empty or missing)." >&2
  echo "       The tests may have been skipped or failed before measuring." >&2
  echo "       xcodebuild exit status: $status" >&2
  echo "       Full log: $XCODEBUILD_LOG — last lines:" >&2
  tail -n 25 "$XCODEBUILD_LOG" >&2 || true
  exit 1
fi

echo "Generated media performance results:"
cat "$RESULTS"

if [[ $status -ne 0 ]]; then
  echo
  echo "warning: xcodebuild exited with status $status — results above may be incomplete." >&2
  echo "         (A --time-limit increase is the usual fix for large corpora.)" >&2
  echo "         Full log: $XCODEBUILD_LOG" >&2
  exit "$status"
fi

cp "$RESULTS" "$STABLE_RESULTS"
