#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Running checked-in regression suites..."
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  -only-testing:VideoScanTests/FFProbeIntegrationTests \
  -only-testing:VideoScanTests/ExternalMediaManifestDecodingTests \
  -only-testing:VideoScanTests/ScanEngineTests \
  -only-testing:VideoScanTests/CombineTests \
  -only-testing:VideoScanTests/PersonFinderCacheTests

echo
echo "External media regressions are opt-in:"
echo "  scripts/run_external_media_regressions.sh"
