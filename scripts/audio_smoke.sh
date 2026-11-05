#!/usr/bin/env bash
# audio_smoke.sh — watch the real-model audio test go RED, then GREEN.
#
#   scripts/audio_smoke.sh
#
# Rick, 2026-11-05: "run it with whisper disabled and show red - no audio -
# then run with whisper and show green good audio". Both runs are
# tests/test_audio_transcribe_smoke.py::test_known_speech_is_transcribed,
# the app's real Whisper path (worker + per-file script, venv-mlx, the
# app's arguments) on a generated clip that says "The quick brown fox jumps
# over the lazy dog. Seventeen purple elephants."
#
#   1. RED   — Whisper "disabled": the model hidden the way a Mac without it
#              looks (an empty Hugging Face cache, offline). The test must
#              FAIL, saying the model is not on this Mac. If it passes here,
#              the demo itself is broken and says so.
#   2. GREEN — the same test with this Mac's real cache.
#
# Exit 0 only when the pair is RED then GREEN. ~10 s with the model warm.
# Python: venv/bin/python (pytest); the test spawns venv-mlx itself.
# Memory: one Whisper child at a time (~0.5 GB), the clip < 1 MB.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$REPO/venv/bin/python"
[ -x "$PY" ] || PY="$HOME/dev/VideoScan/venv/bin/python"
TEST="$REPO/tests/test_audio_transcribe_smoke.py::test_known_speech_is_transcribed"
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/audio-smoke-empty-hf.XXXXXX")"
trap 'rm -rf "$EMPTY"' EXIT

run_pytest() {   # extra env assignments as args (via env) → pytest's lines
    env "$@" "$PY" -m pytest -q -p no:cacheprovider -rA "$TEST" 2>&1 \
        | grep -E '^(PASSED|FAILED|GREEN|E +(AssertionError|RED)|[0-9]+ (passed|failed))' \
        | sed -E 's/^E +AssertionError: /    /; s/^/  /'
    return "${PIPESTATUS[0]}"
}

echo "== 1. Whisper disabled (model hidden: empty HF cache, offline) — expect RED =="
run_pytest HF_HUB_OFFLINE=1 HF_HOME="$EMPTY" HF_HUB_CACHE="$EMPTY"
red_rc=$?
if [ "$red_rc" -ne 0 ]; then
    echo "RED — no audio: with the model hidden the real path refuses, as it must"
else
    echo "BROKEN DEMO — the test passed with the model hidden; it cannot catch a missing model"
fi

echo
echo "== 2. Whisper enabled (this Mac's model) — expect GREEN =="
run_pytest
green_rc=$?
if [ "$green_rc" -eq 0 ]; then
    echo "GREEN — good audio: the real model heard the known sentence"
else
    echo "RED — this Mac cannot transcribe: see the reason above (python3 scripts/check_models.py lists what is missing)"
fi

[ "$red_rc" -ne 0 ] && [ "$green_rc" -eq 0 ]
