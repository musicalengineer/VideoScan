#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_ID="${VIDEOSCAN_ARCFACE_REPRO_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
DERIVED_DATA="${VIDEOSCAN_ARCFACE_REPRO_DERIVED_DATA:-/tmp/vs-codex-arcface-repro/dd-$RUN_ID}"
RESULT_BUNDLE="${VIDEOSCAN_ARCFACE_REPRO_RESULT_BUNDLE:-/tmp/vs-codex-arcface-repro/ArcFaceParallelRepro-$RUN_ID.xcresult}"
CONFIG_DIR="/tmp/vs-codex-stress"
CONFIG_FILE="$CONFIG_DIR/arcface-parallel-repro.conf"
CONFIGURATION="${VIDEOSCAN_ARCFACE_REPRO_CONFIGURATION:-Debug}"
TIMEOUT="${VIDEOSCAN_ARCFACE_REPRO_TIMEOUT:-300}"
CONCURRENCY="${VIDEOSCAN_ARCFACE_REPRO_CONCURRENCY:-12}"
FRAME_STEP="${VIDEOSCAN_ARCFACE_REPRO_FRAME_STEP:-5}"
START_STAGGER_MS="${VIDEOSCAN_ARCFACE_REPRO_START_STAGGER_MS:-250}"
JOBS="${VIDEOSCAN_ARCFACE_REPRO_JOBS:-}"
PROGRESS_INTERVAL="${VIDEOSCAN_ARCFACE_REPRO_PROGRESS_INTERVAL:-20}"
HARD_TIMEOUT="${VIDEOSCAN_ARCFACE_REPRO_HARD_TIMEOUT:-$((TIMEOUT + 120))}"

mkdir -p "$(dirname "$DERIVED_DATA")" "$(dirname "$RESULT_BUNDLE")" "$CONFIG_DIR"
rm -rf "$RESULT_BUNDLE"
touch "$CONFIG_DIR/arcface-parallel-repro-enabled"
{
  printf 'VIDEOSCAN_ARCFACE_REPRO_TIMEOUT=%s\n' "$TIMEOUT"
  printf 'VIDEOSCAN_ARCFACE_REPRO_CONCURRENCY=%s\n' "$CONCURRENCY"
  printf 'VIDEOSCAN_ARCFACE_REPRO_FRAME_STEP=%s\n' "$FRAME_STEP"
  printf 'VIDEOSCAN_ARCFACE_REPRO_START_STAGGER_MS=%s\n' "$START_STAGGER_MS"
  printf 'VIDEOSCAN_ARCFACE_REPRO_JOBS=%s\n' "$JOBS"
  printf 'VIDEOSCAN_ARCFACE_REPRO_RUN_ID=%s\n' "$RUN_ID"
} > "$CONFIG_FILE"
trap 'rm -f "$CONFIG_DIR/arcface-parallel-repro-enabled" "$CONFIG_FILE"' EXIT

echo "Running VideoScan ArcFace parallel-search crash reproducer"
echo "  derived data: $DERIVED_DATA"
echo "  result bundle: $RESULT_BUNDLE"
echo "  configuration: $CONFIGURATION"
echo "  timeout: $TIMEOUT seconds"
echo "  concurrency: $CONCURRENCY"
echo "  frame step: $FRAME_STEP"
echo "  start stagger: ${START_STAGGER_MS}ms"
echo "  hard timeout: $HARD_TIMEOUT seconds"
if [[ -n "$JOBS" ]]; then
  echo "  jobs: $JOBS"
else
  echo "  jobs: default Donna=/Users/rickb/Movies and Ma=/Users/rickb/Movies"
fi
echo

print_progress() {
  echo
  echo "[$(date +%H:%M:%S)] facedetect progress snapshot"
  local found=0
  while IFS= read -r log; do
    found=1
    echo "--- $(basename "$log") ---"
    tail -n 8 "$log" || true
  done < <(ls -t "$HOME"/Library/Logs/VideoScan/facedetect_*arcface-repro-"$RUN_ID"-*.log 2>/dev/null | head -n 8)
  if [[ "$found" == 0 ]]; then
    echo "(no arcface-repro facedetect logs yet for run $RUN_ID)"
  fi
}

monitor_progress() {
  local xcode_pid="$1"
  while kill -0 "$xcode_pid" 2>/dev/null; do
    sleep "$PROGRESS_INTERVAL"
    kill -0 "$xcode_pid" 2>/dev/null || break
    print_progress
  done
}

hard_timeout() {
  local xcode_pid="$1"
  sleep "$HARD_TIMEOUT"
  if kill -0 "$xcode_pid" 2>/dev/null; then
    echo
    echo "[$(date +%H:%M:%S)] hard timeout reached after ${HARD_TIMEOUT}s; terminating xcodebuild"
    print_progress
    kill "$xcode_pid" 2>/dev/null || true
  fi
}

VIDEOSCAN_ARCFACE_PARALLEL_REPRO=1 \
VIDEOSCAN_ARCFACE_REPRO_TIMEOUT="$TIMEOUT" \
VIDEOSCAN_ARCFACE_REPRO_CONCURRENCY="$CONCURRENCY" \
VIDEOSCAN_ARCFACE_REPRO_FRAME_STEP="$FRAME_STEP" \
VIDEOSCAN_ARCFACE_REPRO_START_STAGGER_MS="$START_STAGGER_MS" \
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:VideoScanTests/ArcFaceParallelSearchReproducerTests \
  -parallel-testing-enabled NO \
  ENABLE_TESTABILITY=YES \
  CODE_SIGNING_ALLOWED=NO \
  MACOSX_DEPLOYMENT_TARGET=15.0 &

xcode_pid=$!
monitor_progress "$xcode_pid" &
monitor_pid=$!
hard_timeout "$xcode_pid" &
timeout_pid=$!

set +e
wait "$xcode_pid"
status=$?
set -e

kill "$monitor_pid" "$timeout_pid" 2>/dev/null || true
wait "$monitor_pid" "$timeout_pid" 2>/dev/null || true

exit "$status"
