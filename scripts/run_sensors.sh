#!/usr/bin/env bash
# run_sensors.sh — the pre-merge SENSOR LANE (GH #360 item 1). Runs every
# source-scan / architecture sensor in VideoScanTests (xcodebuild
# -only-testing, Debug) and VideoScanCore (swift test --filter), and nothing
# else. Exit 0 = every sensor green; exit 1 = a red sensor (names printed) or a
# lane that ran zero tests. Mandatory before an agent reports done and before a
# merge to main (CLAUDE.md, "Pre-merge sensor lane").
#
#   scripts/run_sensors.sh              # both halves
#   scripts/run_sensors.sh --app-only   # just the app target
#   python3 scripts/sensor_lane.py list # what it runs (discovered from source)
#
# All the logic lives in scripts/sensor_lane.py; this is the shell entry.
exec python3 "$(dirname "$0")/sensor_lane.py" run "$@"
