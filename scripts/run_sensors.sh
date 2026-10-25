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
# 2026-10-23: on GREEN this script records the hash of the exact working tree it
# ran against in <git common dir>/sensor-lane-green (last 50 trees). The
# pre-push hook refuses a push to main whose commit tree has no recorded green
# (scripts/git-hooks/pre-push). Edit after the lane → the stamp no longer
# matches → run the lane again. That is the point.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

python3 "$HERE/sensor_lane.py" run "$@"
rc=$?
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
