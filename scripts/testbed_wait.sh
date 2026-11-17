#!/usr/bin/env bash
# testbed_wait.sh — wait until the testbed on this Mac is idle, for a GitHub Actions job
# on the M4 runner (ci.yml, the macOS jobs). Probes the testbed lock (~/m4run/lock —
# scripts/testbed_lock.py probe, the same kernel truth scripts/m4_run.sh and
# scripts/nightly_gauntlet.sh use) every 30 s until it reads FREE, and sits out the
# 13:50–14:05 host-time window so the 14:00 nightly (scripts/nightly_rota.json) takes
# the lock first. It never HOLDS the lock: a job's steps are separate shells, and the
# runner has its own checkout (~/actions-runner/_work) and DerivedData, so a job that
# starts after the wait shares only CPU with a testbed run that starts later.
#
#   scripts/testbed_wait.sh [--budget SECONDS] [--interval SECONDS] [--lock DIR]
#
# Exit: 0 idle · 3 still busy when the budget ran out (the step fails and says so) · 2 usage.
# Test hook: VIDEOSCAN_TESTBED_WAIT_NOW=HHMM fixes the clock.
# Tests: tests/test_install_gh_runner.py.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUDGET=10800; INTERVAL=30; LOCK="$HOME/m4run/lock"
usage() { echo "usage: testbed_wait.sh [--budget S] [--interval S] [--lock DIR]" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --budget) BUDGET="${2:-}"; shift 2 || usage ;;
        --interval) INTERVAL="${2:-}"; shift 2 || usage ;;
        --lock) LOCK="${2:-}"; shift 2 || usage ;;
        *) usage ;;
    esac
done
[[ "$BUDGET" =~ ^[0-9]+$ ]] && [[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -gt 0 ] \
    || { echo "testbed_wait: --budget and --interval want whole seconds" >&2; exit 2; }

now_hhmm() { echo "${VIDEOSCAN_TESTBED_WAIT_NOW:-$(date +%H%M)}"; }
quiet() {   # the nightly's slot: let it take the lock first
    local t
    t="$(now_hhmm)"
    [ "$t" -ge 1350 ] 2>/dev/null && [ "$t" -lt 1405 ]
}

waited=0; said=""
while :; do
    probe="$(python3 "$HERE/testbed_lock.py" probe "$LOCK" 2>/dev/null || echo 'BUSY (probe failed)')"
    if quiet; then
        why="the 14:00 nightly's window ($(now_hhmm))"
    elif [ "$probe" = FREE ]; then
        [ -n "$said" ] && echo "testbed_wait: idle after ${waited}s"
        exit 0
    else
        why="${probe#BUSY }"
    fi
    if [ "$waited" -ge "$BUDGET" ]; then
        echo "testbed_wait: still waiting after ${waited}s — $why" >&2
        exit 3
    fi
    [ "$said" = "$why" ] || { echo "testbed_wait: waiting — $why"; said="$why"; }
    sleep "$INTERVAL"
    waited=$((waited + INTERVAL))
done
