#!/usr/bin/env bash
#
# The single entry point for the Python test suite.
#
# As of 2026-08-29 only the CI workflow (.github/workflows/python-tests.yml)
# calls this. The local nightly does NOT yet — nightly_local_tests.sh has no
# caller for it, and that wiring is owned elsewhere. The point of a single
# entry point is that once the nightly does call it, the two cannot drift;
# that is an intention, not a description of today.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-29 the Python suite was largely unrun: CI executed two modules
# and the nightly none. The counts, since three different ones appear in
# this file's history and they are easy to conflate:
#
#     416   a `pytest tests/` sweep of the working tree
#   - 21    tests/test_post_nightly_updates.py, UNTRACKED and belonging to a
#           person rather than to CI — hence git ls-files below. Retired
#           2026-09-03 (Rick: dev_updater.sh is a utility and needs no
#           tests); the count is kept here because the arithmetic below
#           still has to reconcile against that history.
#   = 395   tracked, under tests/ only
#   +  5    tools/poi-c02/test_tools.py, tracked but outside tests/ and so
#           missed until discovery was widened repo-wide
#   = 400   tracked today, and the floor this script asserts
#
# Worse than the gap itself was that neither runner FAILS when tests go
# missing: pytest and unittest both exit 0 when a module drops out of
# collection. A missing dependency silently took that 416 sweep down to 359
# while the output still looked healthy.
#
# So this script does three things, and the third is the point:
#   1. runs the suite against an explicit TRACKED file list, not a
#      directory sweep — the working tree may hold untracked test files
#      that belong to a person, not to CI;
#   2. preflights the external tools whose absence would otherwise show up
#      as a confusing hard error deep in a test;
#   3. asserts FLOORS on module and test counts, so shrinkage is loud.
#
# Floors are deliberately not auto-derived. A baseline that regenerates
# itself ratchets downward the first time something breaks, which is
# exactly when you want it to complain.
#
# Usage:  scripts/run_python_tests.sh
#         PYTHON=/path/to/python scripts/run_python_tests.sh
#
# Written for bash 3.2 — that is what /bin/bash is on macOS, where the
# nightly is intended to run it. No mapfile, no associative arrays.

set -euo pipefail

# Measured 2026-08-29 against 29 tracked modules. Raise both when tests are
# added; never lower them to make a red run green.
MIN_MODULES=29
MIN_TESTS=400

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# Prefer the repo venv (Rick's convention, and it has the deps); fall back
# to python3 for CI, which installs the deps into its own environment.
if [ -z "${PYTHON:-}" ]; then
  if [ -x "$REPO_ROOT/venv/bin/python" ]; then
    PYTHON="$REPO_ROOT/venv/bin/python"
  else
    PYTHON=python3
  fi
fi
echo "python: $PYTHON ($("$PYTHON" --version 2>&1))"

# ── Preflight ───────────────────────────────────────────────────────────
# tests/test_search_benchmark_metrics.py drives the dashboard contract
# through a Node harness with no availability guard: without node it raises
# FileNotFoundError from deep inside subprocess, which reads like a test
# bug. Fail here instead, where the message says what is actually missing.
# Deliberately NOT a skip — silently dropping the dashboard contract tests
# is the failure mode this script exists to prevent.
if ! command -v node >/dev/null 2>&1; then
  echo "::error::node is not on PATH. The dashboard contract tests in tests/test_search_benchmark_metrics.py require it, and skipping them would hide a whole contract. Install Node (CI: actions/setup-node)."
  exit 1
fi
echo "node: $(node --version)"

# ── Tracked modules only ────────────────────────────────────────────────
# git ls-files, never a glob or a directory sweep: an untracked test file
# in the working tree belongs to whoever put it there and must not become
# a CI dependency, nor inflate the counts this script asserts.
#
# Patterns are repo-WIDE, not tests/-only (codex review, #915). Scoping to
# tests/ silently omitted tools/poi-c02/test_tools.py — five tracked
# materializer safety and provenance tests. Matching by name anywhere means
# a future module in a new directory is picked up on its own, instead of
# waiting for someone to notice it was never running.
MODULES=()
while IFS= read -r f; do
  [ -n "$f" ] && MODULES+=("$f")
done < <(git ls-files '*test_*.py' '*_test.py' | sort -u)

MODULE_COUNT=${#MODULES[@]}
echo "tracked test modules: $MODULE_COUNT (floor $MIN_MODULES)"
if [ "$MODULE_COUNT" -lt "$MIN_MODULES" ]; then
  echo "::error::only $MODULE_COUNT tracked test modules, expected at least $MIN_MODULES. A module was deleted, renamed, or untracked."
  exit 1
fi

# ── Collection floor ────────────────────────────────────────────────────
# Counted before running, so an import error that silently removes a whole
# module is caught even when every surviving test passes.
COLLECT_OUT=$("$PYTHON" -m pytest --collect-only -q "${MODULES[@]}" 2>&1) || {
  echo "$COLLECT_OUT"
  echo "::error::pytest collection failed. See the errors above."
  exit 1
}
COLLECTED=$(printf '%s\n' "$COLLECT_OUT" | sed -n 's/^\([0-9][0-9]*\) tests* collected.*/\1/p' | tail -1)
if [ -z "$COLLECTED" ]; then
  printf '%s\n' "$COLLECT_OUT" | tail -20
  echo "::error::could not parse a collected-test count from pytest output."
  exit 1
fi
echo "collected tests: $COLLECTED (floor $MIN_TESTS)"
if [ "$COLLECTED" -lt "$MIN_TESTS" ]; then
  printf '%s\n' "$COLLECT_OUT" | tail -20
  echo "::error::collected only $COLLECTED tests, expected at least $MIN_TESTS. A module probably failed to import — check for a missing dependency."
  exit 1
fi

# ── Run ─────────────────────────────────────────────────────────────────
# -rs reports skip reasons. Skips are legitimate here (the VLM smoke test
# skips without venv-mlx or ffmpeg) but they should never be invisible:
# a test that starts skipping everywhere is indistinguishable from a
# passing one in a bare summary line.
echo
"$PYTHON" -m pytest -q -rs "${MODULES[@]}"
