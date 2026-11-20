#!/bin/bash
# run_tests.sh — run a smoke (default) or full test pass and watch it, googletest-style.
#
#   scripts/run_tests.sh [--smoke | --full] [--unit] [--regression] [--integration] [--perf]
#                        [--stress] [--python] [--corpus] [--verbose] [--host m4|ultra|m5pro|m1]
#                        [--ref <rev>] [--filter 'Pos1:Pos2-Neg1'] [--list] [--dry-run] [--yes] [--force]
#   scripts/run_tests.sh --status       # every live run on this Mac, the slots, the M4 lock holder
#
# All the logic is in scripts/run_tests.py (its docstring is the reference), run with Apple's
# /usr/bin/python3 so it works on every fleet Mac with nothing installed.
# Exit: 0 green · 1 red · 2 usage / nothing to run here / a filter matching nothing · 3 busy · 130 interrupted.
# Runs on one Mac go side by side; only a build at one commit is waited for (run_tests.py docstring).
# --full is this Mac only; for the M4: scripts/m4_run.sh suite --host m4 --ref <commit> --wait.
exec /usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/run_tests.py" "$@"
