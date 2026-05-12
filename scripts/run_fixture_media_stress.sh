#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_ID="${VIDEOSCAN_FIXTURE_STRESS_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
CONFIG_DIR="/tmp/vs-codex-stress"
CONFIG_FILE="$CONFIG_DIR/fixture-media-stress.conf"
DERIVED_DATA="${VIDEOSCAN_FIXTURE_STRESS_DERIVED_DATA:-/tmp/vs-codex-fixture-stress/dd-$RUN_ID}"
RESULT_BUNDLE="${VIDEOSCAN_FIXTURE_STRESS_RESULT_BUNDLE:-/tmp/vs-codex-fixture-stress/FixtureMediaStress-$RUN_ID.xcresult}"
CONFIGURATION="${VIDEOSCAN_FIXTURE_STRESS_CONFIGURATION:-Debug}"
FIXTURE_DIR="${VIDEOSCAN_FIXTURE_STRESS_FIXTURE_DIR:-$ROOT/tests/fixtures/videos}"
PEOPLE="${VIDEOSCAN_FIXTURE_STRESS_PEOPLE:-Donna,Ma}"
ENGINES="${VIDEOSCAN_FIXTURE_STRESS_ENGINES:-vision,arcface}"
DUPLICATES="${VIDEOSCAN_FIXTURE_STRESS_DUPLICATES:-12}"
MAX_SEARCHES="${VIDEOSCAN_FIXTURE_STRESS_MAX_SEARCHES:-6}"
TIMEOUT="${VIDEOSCAN_FIXTURE_STRESS_TIMEOUT:-180}"
CONCURRENCY="${VIDEOSCAN_FIXTURE_STRESS_CONCURRENCY:-12}"
FRAME_STEP="${VIDEOSCAN_FIXTURE_STRESS_FRAME_STEP:-5}"
START_STAGGER_MS="${VIDEOSCAN_FIXTURE_STRESS_START_STAGGER_MS:-25}"
STAGE_MODE="${VIDEOSCAN_FIXTURE_STRESS_STAGE_MODE:-link}"
PROGRESS_INTERVAL="${VIDEOSCAN_FIXTURE_STRESS_PROGRESS_INTERVAL:-20}"
HARD_TIMEOUT="${VIDEOSCAN_FIXTURE_STRESS_HARD_TIMEOUT:-$((TIMEOUT * MAX_SEARCHES + 180))}"
USE_RAMDISK="${VIDEOSCAN_FIXTURE_STRESS_USE_RAMDISK:-0}"
RAMDISK_MB="${VIDEOSCAN_FIXTURE_STRESS_RAMDISK_MB:-8192}"
STAGE_BASE="${VIDEOSCAN_FIXTURE_STRESS_STAGE_BASE:-/tmp}"
RAMDISK_DEVICE=""

mount_ramdisk() {
  local sectors=$((RAMDISK_MB * 2048))
  local name="VideoScan_FixtureStress_$RUN_ID"
  local dev
  dev="$(/usr/bin/hdiutil attach -nomount "ram://$sectors" | tr -d '[:space:]')"
  /usr/sbin/diskutil eraseVolume APFS "$name" "$dev" >/dev/null
  RAMDISK_DEVICE="$dev"
  STAGE_BASE="/Volumes/$name"
}

cleanup() {
  rm -f "$CONFIG_DIR/fixture-media-stress-enabled" "$CONFIG_FILE"
  if [[ -n "$RAMDISK_DEVICE" ]]; then
    /usr/bin/hdiutil detach "$RAMDISK_DEVICE" -force >/dev/null 2>&1 || true
  fi
}

mkdir -p "$(dirname "$DERIVED_DATA")" "$(dirname "$RESULT_BUNDLE")" "$CONFIG_DIR"
rm -rf "$RESULT_BUNDLE"

if [[ "$USE_RAMDISK" == "1" ]]; then
  mount_ramdisk
fi

touch "$CONFIG_DIR/fixture-media-stress-enabled"
{
  printf 'VIDEOSCAN_FIXTURE_STRESS_RUN_ID=%s\n' "$RUN_ID"
  printf 'VIDEOSCAN_FIXTURE_STRESS_FIXTURE_DIR=%s\n' "$FIXTURE_DIR"
  printf 'VIDEOSCAN_FIXTURE_STRESS_STAGE_BASE=%s\n' "$STAGE_BASE"
  printf 'VIDEOSCAN_FIXTURE_STRESS_STAGE_MODE=%s\n' "$STAGE_MODE"
  printf 'VIDEOSCAN_FIXTURE_STRESS_PEOPLE=%s\n' "$PEOPLE"
  printf 'VIDEOSCAN_FIXTURE_STRESS_ENGINES=%s\n' "$ENGINES"
  printf 'VIDEOSCAN_FIXTURE_STRESS_DUPLICATES=%s\n' "$DUPLICATES"
  printf 'VIDEOSCAN_FIXTURE_STRESS_MAX_SEARCHES=%s\n' "$MAX_SEARCHES"
  printf 'VIDEOSCAN_FIXTURE_STRESS_TIMEOUT=%s\n' "$TIMEOUT"
  printf 'VIDEOSCAN_FIXTURE_STRESS_CONCURRENCY=%s\n' "$CONCURRENCY"
  printf 'VIDEOSCAN_FIXTURE_STRESS_FRAME_STEP=%s\n' "$FRAME_STEP"
  printf 'VIDEOSCAN_FIXTURE_STRESS_START_STAGGER_MS=%s\n' "$START_STAGGER_MS"
} > "$CONFIG_FILE"
trap cleanup EXIT

echo "Running VideoScan fixture-media stress"
echo "  run id: $RUN_ID"
echo "  fixture dir: $FIXTURE_DIR"
echo "  stage base: $STAGE_BASE"
echo "  stage mode: $STAGE_MODE"
echo "  ram disk: $USE_RAMDISK (${RAMDISK_MB} MB)"
echo "  people: $PEOPLE"
echo "  engines: $ENGINES"
echo "  duplicates per fixture: $DUPLICATES"
echo "  max searches: $MAX_SEARCHES"
echo "  timeout per stage: $TIMEOUT seconds"
echo "  hard timeout: $HARD_TIMEOUT seconds"
echo "  concurrency: $CONCURRENCY"
echo "  frame step: $FRAME_STEP"
echo "  result bundle: $RESULT_BUNDLE"
echo

print_progress() {
  echo
  echo "[$(date +%H:%M:%S)] fixture-stress progress snapshot"
  local staged
  staged="$(find "$STAGE_BASE" -maxdepth 1 -type d -name "videoscan-fixture-stress-$RUN_ID" -print 2>/dev/null | head -n 1 || true)"
  if [[ -n "$staged" ]]; then
    echo "  staged files: $(find "$staged" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    du -sh "$staged" 2>/dev/null || true
  else
    echo "  staged files: not created yet"
  fi

  local found_logs=0
  while IFS= read -r log; do
    found_logs=1
    echo "--- $(basename "$log") ---"
    tail -n 8 "$log" || true
  done < <(ls -t "$HOME"/Library/Logs/VideoScan/facedetect_*fixture-stress-"$RUN_ID"-*.log 2>/dev/null | head -n 8)
  if [[ "$found_logs" == 0 ]]; then
    echo "  facedetect logs: none yet for run $RUN_ID"
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

VIDEOSCAN_FIXTURE_STRESS=1 \
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:VideoScanTests/FixtureMediaStressTests \
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
