#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Running Python unit tests..."
python3 -m unittest discover tests

echo
echo "Running Swift unit tests..."
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .derivedData \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  -only-testing:VideoScanTests
