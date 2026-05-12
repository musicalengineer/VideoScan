#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${VIDEOSCAN_STRESS_DERIVED_DATA:-/tmp/vs-codex-stress/dd}"
RESULT_BUNDLE="${VIDEOSCAN_STRESS_RESULT_BUNDLE:-/tmp/vs-codex-stress/AdversarialStress.xcresult}"
CONFIG_DIR="/tmp/vs-codex-stress"
ITERATIONS="${VIDEOSCAN_STRESS_ITERATIONS:-24}"
PARALLELISM="${VIDEOSCAN_STRESS_PARALLELISM:-6}"
TIMEOUT="${VIDEOSCAN_STRESS_TIMEOUT:-90}"

mkdir -p "$(dirname "$DERIVED_DATA")" "$(dirname "$RESULT_BUNDLE")" "$CONFIG_DIR"
rm -rf "$RESULT_BUNDLE"
printf '%s\n' "$ITERATIONS" > "$CONFIG_DIR/iterations"
printf '%s\n' "$PARALLELISM" > "$CONFIG_DIR/parallelism"
printf '%s\n' "$TIMEOUT" > "$CONFIG_DIR/timeout"
touch "$CONFIG_DIR/enabled"
trap 'rm -f "$CONFIG_DIR/enabled"' EXIT

echo "Running VideoScan adversarial stress tests"
echo "  derived data: $DERIVED_DATA"
echo "  result bundle: $RESULT_BUNDLE"
echo "  iterations: $ITERATIONS"
echo "  parallelism: $PARALLELISM"
echo "  timeout: $TIMEOUT seconds"
echo

VIDEOSCAN_STRESS=1 \
VIDEOSCAN_STRESS_ITERATIONS="$ITERATIONS" \
VIDEOSCAN_STRESS_PARALLELISM="$PARALLELISM" \
VIDEOSCAN_STRESS_TIMEOUT="$TIMEOUT" \
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:VideoScanTests/AdversarialCoreStressTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  MACOSX_DEPLOYMENT_TARGET=15.0
