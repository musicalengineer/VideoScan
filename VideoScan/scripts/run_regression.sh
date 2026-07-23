#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "Running checked-in regression suites..."
# NOTE: -only-testing filters are SUITE identifiers (struct/class names), not
# file names. xcodebuild does not error on a filter that matches nothing —
# stale names silently run zero tests (found 2026-07-22: "ScanEngineTests"
# and "CombineTests" matched nothing). The executed-count guard below turns
# that silence into a failure.
LOG="$(mktemp)"
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
  -only-testing:VideoScanTests/ScanPhaseTests \
  -only-testing:VideoScanTests/ScanCounterInvariantTests \
  -only-testing:VideoScanTests/ScanMergePairCarryoverTests \
  -only-testing:VideoScanTests/CombineEngineTests \
  -only-testing:VideoScanTests/CombineEngineExtendedTests \
  -only-testing:VideoScanTests/OnlineSubstituteTests \
  -only-testing:VideoScanTests/CodecCompatibilityTests \
  -only-testing:VideoScanTests/CombineTechniquePropagationTests \
  -only-testing:VideoScanTests/CombinedRecordSpecTests \
  -only-testing:VideoScanTests/CombineBatchPlanTests \
  -only-testing:VideoScanTests/CombineEngineArgsTests \
  -only-testing:VideoScanTests/PersonFinderCacheTests \
  | tee "$LOG"

# Sum executed counts from both frameworks (XCTest: "Executed N tests";
# Swift Testing: "Test run with N tests ... passed").
executed=$(awk '/Executed [0-9]+ test/ {for(i=1;i<=NF;i++) if($i=="Executed"){s+=$(i+1)}} /Test run with [0-9]+ test/ {for(i=1;i<=NF;i++) if($i=="with"){s+=$(i+1)}} END {print s+0}' "$LOG")
# Signal only — XCTest emits per-suite and rollup lines, so this can
# double-count. It exists to catch the zero case, not to report a precise total.
echo "Executed-count signal: ${executed}"
if [ "${executed}" -eq 0 ]; then
  echo "ERROR: zero tests executed — stale -only-testing filters?" >&2
  exit 1
fi

echo
echo "External media regressions are opt-in:"
echo "  VideoScan/scripts/run_external_media_regressions.sh"
