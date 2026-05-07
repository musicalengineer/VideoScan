#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="/tmp/videoscan_perf_enabled"
RESULTS="/tmp/videoscan_perf_results.txt"
FILE_COUNT_CONFIG="/tmp/videoscan_perf_file_count"
DURATION_CONFIG="/tmp/videoscan_perf_duration"
XCODEBUILD_LOG="/tmp/videoscan_perf_xcodebuild.log"
FILE_COUNT="${VIDEOSCAN_PERF_FILE_COUNT:-12}"
DURATION="${VIDEOSCAN_PERF_DURATION:-1.5}"
VERBOSE="${VIDEOSCAN_PERF_VERBOSE:-0}"

cleanup() {
  rm -f "$MARKER" "$FILE_COUNT_CONFIG" "$DURATION_CONFIG"
}
trap cleanup EXIT

rm -f "$RESULTS"
touch "$MARKER"
printf '%s\n' "$FILE_COUNT" > "$FILE_COUNT_CONFIG"
printf '%s\n' "$DURATION" > "$DURATION_CONFIG"

cd "$ROOT"

cmd=(
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
echo "  Worktree: $ROOT"
echo "  Corpus:   $FILE_COUNT generated file(s), ${DURATION}s each"
echo "  Results:  $RESULTS"
echo "  Full log: $XCODEBUILD_LOG"
echo

if [[ "$VERBOSE" == "1" ]]; then
  echo "Running xcodebuild with full verbose output..."
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG"
else
  echo "Running xcodebuild. Showing benchmark progress only; set VIDEOSCAN_PERF_VERBOSE=1 for full build output."
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG" | awk '
    /Test .*started/ ||
    /Test .*passed/ ||
    /Suite .*started/ ||
    /Suite .*passed/ ||
    /VIDEOSCAN_PERF/ ||
    /Generated media performance results/ ||
    /\*\* TEST/ ||
    /Testing failed/ ||
    /error:/ { print }
  '
fi

echo
echo "Generated media performance results:"
cat "$RESULTS"
