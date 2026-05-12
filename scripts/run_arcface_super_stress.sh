#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE_DIR="${VIDEOSCAN_POI_DIR:-$HOME/Library/Application Support/VideoScan/POI}"
MOVIES_PATH="${VIDEOSCAN_SUPER_MOVIES_PATH:-$HOME/Movies}"
SEAGATE_PATH="${VIDEOSCAN_SUPER_SEAGATE_PATH:-/Volumes/Seagate2TB}"
MYBOOK_PATH="${VIDEOSCAN_SUPER_MYBOOK_PATH:-/Volumes/MyBook3Terabytes}"
TIMEOUT="${VIDEOSCAN_SUPER_TIMEOUT:-420}"
RUN_ID="${VIDEOSCAN_SUPER_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"

sanitize_profile() {
  printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_'
}

profile_exists() {
  local name="$1"
  local folder
  folder="$(sanitize_profile "$name")"
  [[ -f "$PROFILE_DIR/$folder/profile.json" ]]
}

add_job_if_ready() {
  local -n out_ref="$1"
  local name="$2"
  local path="$3"

  if [[ -d "$path" ]] && profile_exists "$name"; then
    out_ref+=("$name=$path")
  fi
}

join_jobs() {
  local IFS=';'
  printf '%s' "$*"
}

run_stage() {
  local stage="$1"
  local label="$2"
  local configuration="$3"
  local concurrency="$4"
  local frame_step="$5"
  local stagger_ms="$6"
  shift 6
  local jobs=("$@")

  if [[ "${#jobs[@]}" -eq 0 ]]; then
    echo "Skipping stage $stage ($label): no runnable jobs"
    return 0
  fi

  local jobs_arg
  jobs_arg="$(join_jobs "${jobs[@]}")"
  local derived="/tmp/vs-codex-arcface-super/$RUN_ID/stage-${stage}-dd"
  local result="/tmp/vs-codex-arcface-super/$RUN_ID/stage-${stage}.xcresult"

  echo
  echo "============================================================"
  echo "Stage $stage: $label"
  echo "  configuration: $configuration"
  echo "  concurrency: $concurrency"
  echo "  frame step: $frame_step"
  echo "  start stagger: ${stagger_ms}ms"
  echo "  jobs: $jobs_arg"
  echo "============================================================"

  VIDEOSCAN_ARCFACE_REPRO_CONFIGURATION="$configuration" \
  VIDEOSCAN_ARCFACE_REPRO_CONCURRENCY="$concurrency" \
  VIDEOSCAN_ARCFACE_REPRO_FRAME_STEP="$frame_step" \
  VIDEOSCAN_ARCFACE_REPRO_START_STAGGER_MS="$stagger_ms" \
  VIDEOSCAN_ARCFACE_REPRO_TIMEOUT="$TIMEOUT" \
  VIDEOSCAN_ARCFACE_REPRO_DERIVED_DATA="$derived" \
  VIDEOSCAN_ARCFACE_REPRO_RESULT_BUNDLE="$result" \
  VIDEOSCAN_ARCFACE_REPRO_JOBS="$jobs_arg" \
  scripts/run_arcface_parallel_repro.sh
  local status=$?

  if [[ "$status" -ne 0 ]]; then
    echo
    echo "Stage $stage failed with exit status $status"
    echo "  result bundle: $result"
    return "$status"
  fi
}

declare -a candidates=()
add_job_if_ready candidates "Donna" "$SEAGATE_PATH"
add_job_if_ready candidates "Ma" "$MOVIES_PATH"
add_job_if_ready candidates "Donna" "$MYBOOK_PATH"
add_job_if_ready candidates "Anna" "$MOVIES_PATH"
add_job_if_ready candidates "Rick" "$MOVIES_PATH"
add_job_if_ready candidates "Beth" "$MOVIES_PATH"

if [[ -n "${VIDEOSCAN_SUPER_JOBS:-}" ]]; then
  IFS=';' read -r -a candidates <<< "$VIDEOSCAN_SUPER_JOBS"
fi

if [[ "${#candidates[@]}" -eq 0 ]]; then
  echo "No runnable ArcFace super-stress jobs found."
  echo "Set VIDEOSCAN_SUPER_JOBS='Donna=/Volumes/Seagate2TB;Ma=$HOME/Movies;Anna=$HOME/Movies'"
  exit 2
fi

echo "VideoScan ArcFace super stress"
echo "  POI dir: $PROFILE_DIR"
echo "  run id: $RUN_ID"
echo "  timeout per stage: $TIMEOUT seconds"
echo "  candidate jobs:"
for job in "${candidates[@]}"; do
  echo "    $job"
done

run_stage 1 "single ArcFace baseline" Debug 12 5 250 "${candidates[@]:0:1}" || exit $?
run_stage 2 "manual-crash shape, two ArcFace jobs" Debug 12 5 100 "${candidates[@]:0:2}" || exit $?

if [[ "${#candidates[@]}" -ge 3 ]]; then
  run_stage 3 "three ArcFace jobs, tighter stagger" Debug 16 3 50 "${candidates[@]:0:3}" || exit $?
fi

if [[ "${#candidates[@]}" -ge 4 ]]; then
  run_stage 4 "four ArcFace jobs, release build" Release 24 2 0 "${candidates[@]:0:4}" || exit $?
fi

run_stage 5 "maximum available candidates, release build" Release 32 1 0 "${candidates[@]}" || exit $?

echo
echo "All ArcFace super-stress stages completed without a process abort."
