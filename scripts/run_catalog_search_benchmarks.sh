#!/usr/bin/env bash
# Run the fixed 100k synthetic catalog-search benchmark and validate its JSONL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_M4=0
PUBLISH=0
LOCAL_OUTPUT=""
VERBOSE=0

usage() {
  cat <<'USAGE'
Usage: scripts/run_catalog_search_benchmarks.sh [options]

Options:
  --publish              Publish the validated run to origin/metrics.
  --local-output PATH    Append atomically to a local JSONL stream.
  --allow-m4             Explicitly permit running on an M4 (blocked by default).
  --verbose              Show full xcodebuild output.
  --help                 Show this help.

The benchmark is always Release, arm64, clean main, and the fixed 100k
synthetic corpus. M1/M5 routing is external to this script.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --local-output)
      [[ $# -ge 2 ]] || { echo "error: --local-output requires a path" >&2; exit 2; }
      LOCAL_OUTPUT="$2"; shift 2 ;;
    --allow-m4) ALLOW_M4=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$PUBLISH" == "1" && -n "$LOCAL_OUTPUT" ]]; then
  echo "error: --publish and --local-output are mutually exclusive" >&2
  exit 2
fi

cd "$ROOT"
BRANCH="$(git branch --show-current)"
COMMIT="$(git rev-parse HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: benchmark requires branch main (got ${BRANCH:-detached HEAD})" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: benchmark requires a clean worktree" >&2
  exit 1
fi
if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: benchmark requires a full 40-character commit SHA" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: benchmark requires arm64" >&2
  exit 1
fi
if [[ -n "${VS_SEARCH_BENCH_CATALOG:-}" || -n "${TEST_RUNNER_VS_SEARCH_BENCH_CATALOG:-}" ]]; then
  echo "error: real-catalog benchmark environment is set; refusing to run" >&2
  exit 1
fi

HARDWARE="$(system_profiler SPHardwareDataType 2>/dev/null || true)"
MACHINE_CLASS="$(printf '%s\n' "$HARDWARE" | sed -nE 's/^[[:space:]]*Chip:[[:space:]]*Apple[[:space:]]+(M[0-9]+).*/\1/p' | head -1 | tr '[:upper:]' '[:lower:]')"
MACHINE_CLASS="$(printf '%s' "${VIDEOSCAN_MACHINE_CLASS:-${MACHINE_CLASS:-unknown}}" | tr '[:upper:]' '[:lower:]')"
if [[ "$MACHINE_CLASS" != "m1" && "$MACHINE_CLASS" != "m5" && "$ALLOW_M4" != "1" ]]; then
  echo "error: only M1/M5 run by default (detected $MACHINE_CLASS); route externally or explicitly pass --allow-m4" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/videoscan_search_bench.XXXXXX")"
RAW="$RUN_DIR/raw.jsonl"
LOG="$RUN_DIR/xcodebuild.log"
DERIVED_DATA="$RUN_DIR/DerivedData"
RUN_ID="catalog-search-$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"

echo "VideoScan catalog-search performance benchmark"
echo "  Run ID:       $RUN_ID"
echo "  Machine:      $MACHINE_CLASS"
echo "  Corpus:       100,000 synthetic records"
echo "  Configuration: Release arm64"
echo "  Raw JSONL:    $RAW"
echo "  DerivedData:  $DERIVED_DATA"
echo "  Full log:     $LOG"

cmd=(
  env
  TEST_RUNNER_VS_RUN_SEARCH_BENCH=1
  "TEST_RUNNER_VS_BENCH_OUT=$RAW"
  xcodebuild test
  -project VideoScan/VideoScan.xcodeproj
  -scheme VideoScan
  -configuration Release
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$DERIVED_DATA"
  -parallel-testing-enabled NO
  -maximum-concurrent-test-device-destinations 1
  -only-testing:VideoScanTests/CatalogSearchBenchmarkTests
)

status=0
if [[ "$VERBOSE" == "1" ]]; then
  "${cmd[@]}" 2>&1 | tee "$LOG" || status=$?
else
  "${cmd[@]}" 2>&1 | tee "$LOG" | awk '
    /SEARCHBENCH/ || /Test .*started/ || /Test .*passed/ || /Test .*failed/ ||
    /Test run with/ || /error:/ || /\*\* TEST/ { print }
  ' || status=$?
fi
if [[ "$status" -ne 0 ]]; then
  echo "error: xcodebuild failed with status $status; artifacts retained in $RUN_DIR" >&2
  exit "$status"
fi
if [[ ! -s "$RAW" ]]; then
  echo "error: benchmark passed without producing raw JSONL; artifacts retained in $RUN_DIR" >&2
  exit 1
fi

publish_args=("$RAW" --run-id "$RUN_ID")
if [[ "$PUBLISH" == "1" ]]; then
  publish_args+=(--publish)
elif [[ -n "$LOCAL_OUTPUT" ]]; then
  publish_args+=(--local-output "$LOCAL_OUTPUT")
fi
python3 "$ROOT/scripts/publish_search_benchmarks.py" "${publish_args[@]}"
echo "Validated benchmark complete; artifacts retained in $RUN_DIR"
