#!/usr/bin/env bash
# run_catalog_tests.sh — "run the catalog unit tests and regression tests"
# (Rick, 2026-10-23). Debug. Every VideoScanTests suite named Catalog* plus the
# catalog P0 suites (ProductionShapeRescanSensorTests, P0Truth*), via
# xcodebuild -only-testing; every VideoScanCore Catalog* suite via swift test.
# Exit 0 = GREEN; 1 = RED (a failure, or fewer tests ran than declared — a
# zero-test run is red); 2 = INCOMPLETE (tests SKIPPED, never a pass).
#
#   scripts/run_catalog_tests.sh                        # both halves
#   scripts/run_catalog_tests.sh --list                 # the selection, no build
#   scripts/run_catalog_tests.sh --app-only | --core-only
#   scripts/run_catalog_tests.sh --derived-data <dir>   # reuse your Debug build
#
# The gauntlet (scripts/gauntlet/manifest.json, regression stage) runs the same
# P0 suites in Release in the away window. Logic: scripts/catalog_tests.py.
exec python3 "$(dirname "$0")/catalog_tests.py" "$@"
