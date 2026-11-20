#!/bin/bash
# run_tests.sh — run a smoke (default) or full test pass and watch it, googletest-style.
#
#   scripts/run_tests.sh [--smoke | --full] [--unit] [--regression] [--integration] [--perf]
#                        [--stress] [--python] [--corpus] [--verbose] [--host m4|ultra|m5pro|m1]
#                        [--ref <rev>] [--list] [--dry-run] [--yes] [--force]
#
# All the logic is in scripts/run_tests.py (its docstring is the reference), run with Apple's
# /usr/bin/python3 so it works on every fleet Mac with nothing installed.
# Exit: 0 green · 1 red · 2 usage / nothing to run here / --full with --host · 3 busy · 130 interrupted.
# --full is this Mac only; for the M4: scripts/m4_run.sh suite --host m4 --ref <commit> --wait.
exec /usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/run_tests.py" "$@"
