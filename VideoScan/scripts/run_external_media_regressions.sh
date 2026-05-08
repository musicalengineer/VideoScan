#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEDIA_ROOT="$ROOT/VideoScan/VideoScanTests/Fixtures/External"
MANIFEST=""
VERBOSE=0
ROOT_CONFIG="/tmp/videoscan_external_media_root"
MANIFEST_CONFIG="/tmp/videoscan_external_media_manifest"
XCODEBUILD_LOG="/tmp/videoscan_external_media_xcodebuild.log"

usage() {
  cat <<'USAGE'
Usage: VideoScan/scripts/run_external_media_regressions.sh [options]

Options:
  --media-root PATH     Directory containing manifest.json and local media.
  --manifest PATH       Manifest path. Default: <media-root>/manifest.json.
  --verbose             Show full xcodebuild output.
  --help                Show this help.

Examples:
  VideoScan/scripts/run_external_media_regressions.sh
  VideoScan/scripts/run_external_media_regressions.sh --media-root /Users/rickb/VideoScanTestMedia
  VideoScan/scripts/run_external_media_regressions.sh --manifest /tmp/manifest.json
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --media-root)
      [[ $# -ge 2 ]] || { echo "error: --media-root requires a value" >&2; usage >&2; exit 2; }
      MEDIA_ROOT="$2"
      shift 2
      ;;
    --manifest)
      [[ $# -ge 2 ]] || { echo "error: --manifest requires a value" >&2; usage >&2; exit 2; }
      MANIFEST="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
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

cleanup() {
  rm -f "$ROOT_CONFIG" "$MANIFEST_CONFIG"
}
trap cleanup EXIT

printf '%s\n' "$MEDIA_ROOT" > "$ROOT_CONFIG"
if [[ -n "$MANIFEST" ]]; then
  printf '%s\n' "$MANIFEST" > "$MANIFEST_CONFIG"
fi

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
  -only-testing:VideoScanTests/ExternalMediaManifestDecodingTests
  -only-testing:VideoScanTests/ExternalMediaRegressionTests
)

echo "VideoScan external media regression tests"
echo "  Worktree:   $ROOT"
echo "  Media root: $MEDIA_ROOT"
if [[ -n "$MANIFEST" ]]; then
  echo "  Manifest:   $MANIFEST"
else
  echo "  Manifest:   $MEDIA_ROOT/manifest.json"
fi
echo "  Full log:   $XCODEBUILD_LOG"
echo

if [[ "$VERBOSE" == "1" ]]; then
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG"
else
  "${cmd[@]}" 2>&1 | tee "$XCODEBUILD_LOG" | awk '
    /Test .*started/ ||
    /Test .*passed/ ||
    /Test .*failed/ ||
    /Suite .*started/ ||
    /Suite .*passed/ ||
    /Suite .*failed/ ||
    /Issue recorded/ ||
    /\*\* TEST/ ||
    /Testing failed/ ||
    /error:/ { print }
  '
fi
