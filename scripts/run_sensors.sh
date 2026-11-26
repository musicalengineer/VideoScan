#!/usr/bin/env bash
# run_sensors.sh — the pre-merge SENSOR LANE (GH #360 item 1). Runs every
# source-scan / architecture sensor in VideoScanTests (xcodebuild
# -only-testing, Debug) and VideoScanCore (swift test --filter), and nothing
# else. Exit 0 = every sensor green; exit 1 = a red sensor (names printed) or a
# lane that ran zero tests. Mandatory before an agent reports done and before a
# merge to main (CLAUDE.md, hard rule 9).
#
#   scripts/run_sensors.sh              # both halves
#   scripts/run_sensors.sh --app-only   # just the app target
#   python3 scripts/sensor_lane.py list # what it runs (discovered from source)
#
# All the logic lives in scripts/sensor_lane.py; this is the shell entry.
#
# 2026-11-10 (GH #400): the lane also validates the gauntlet manifest
# (scripts/gauntlet/inventory.swift --validate, ~6 s, no build). A stale
# manifest is RED here with the errors and how to refresh — so the stamp below,
# and therefore the pre-push hook, already covers it.
#
# 2026-10-23: on GREEN this script records the hash of the exact working tree it
# ran against in <git common dir>/sensor-lane-green (last 50 trees). The
# pre-push hook refuses a push to main whose commit tree has no recorded green
# (scripts/git-hooks/pre-push). Edit after the lane → the stamp no longer
# matches → run the lane again. That is the point.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# 2026-11-07 (GH #453): `run_sensors.sh --help` exited 0 and was stamped green
# with no test run. A stamp now needs the lane's own "sensor lane GREEN (N
# tests)" line with N > 0 (rule 9: a run with no number is red). Help never
# stamps; any other exit 0 without that line is red. The lane's output is
# streamed (python3 -u, tee) and kept in a temp file only to read that line;
# the file is one lane's console output (a few KB) and is deleted here.
lane_out="$(mktemp "${TMPDIR:-/tmp}/run-sensors.XXXXXX")" || { echo "run_sensors.sh: mktemp failed" >&2; exit 1; }
python3 -u "$HERE/sensor_lane.py" run "$@" | tee "$lane_out"
rc=${PIPESTATUS[0]}
ran=$(sed -nE 's/^sensor lane GREEN \(([0-9]+) tests?\)$/\1/p' "$lane_out" | tail -n 1)
rm -f "$lane_out"
asked_help=false
for arg in "$@"; do
    case "$arg" in -h|--help) asked_help=true ;; esac
done
if [ "$rc" -eq 0 ] && $asked_help; then
    exit 0                                   # the help screen: not a run, never a stamp
fi
if [ "$rc" -eq 0 ] && [ "${ran:-0}" -le 0 ]; then
    echo "sensor lane stamp NOT recorded: the lane exited 0 without a 'sensor lane GREEN (N tests)' line with N > 0 — a run with no number is red" >&2
    rc=1
fi
if [ "$rc" -eq 0 ]; then
    # The stamp lives in scripts/sensor_lane_stamp.sh (tested by
    # tests/test_sensor_lane_stamp.py). 2026-10-25: the inline version built
    # its scratch index on an EMPTY mktemp file, git refused it, and the stamp
    # was skipped silently — no push to main passed the hook for two days. A
    # failed stamp is now loud and makes the lane red: green that cannot be
    # proven to the hook is not green.
    bash "$HERE/sensor_lane_stamp.sh" "$REPO" || rc=1
fi
exit "$rc"
