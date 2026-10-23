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
    common="$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)"
    if [ -n "$common" ]; then
        case "$common" in /*) ;; *) common="$REPO/$common" ;; esac
        # Tree hash of the WORKING tree (tracked + untracked-but-not-ignored),
        # computed in a scratch index so the real index is untouched.
        tmp_index="$(mktemp)"
        tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$REPO" add -A . >/dev/null 2>&1 && GIT_INDEX_FILE="$tmp_index" git -C "$REPO" write-tree 2>/dev/null)"
        rm -f "$tmp_index"
        if [ -n "$tree" ]; then
            stamp="$common/sensor-lane-green"
            { [ -f "$stamp" ] && tail -n 49 "$stamp"; echo "$tree $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
            echo "sensor lane stamp: tree $tree recorded"
        fi
    fi
fi
exit "$rc"
