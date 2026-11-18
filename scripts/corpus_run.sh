#!/usr/bin/env bash
# corpus_run.sh — the real-data corpus harness (docs/guides/operations.md §1a;
# DECISIONS 2026-11-17 "The M4 holds a real-data test corpus").
#
#   scripts/corpus_run.sh prepare             [--wait] [--dry-run]
#   scripts/corpus_run.sh run <check|proof>   [--ref <rev>] [--deadline <s>] [--limit <n>] [--wait] [--force] [--dry-run]
#   scripts/corpus_run.sh status              [--dry-run]
#   scripts/corpus_run.sh accept <check|proof> [--dry-run]
#
# Launched from the Ultra; everything runs ON THE M4, through scripts/m4_run.sh
# (lane `corpus`): the testbed lock, the per-run LaunchAgent in the GUI
# session, the --ref checkout in the M4's testbed worktree. This script only
# translates the words above into that call; the work is scripts/corpus_run.py.
#
#   prepare   builds the sealed state under ~/corpus/state on the M4 (idempotent)
#   run check probe · Check Media (quick) · Verify Audio on every corpus file
#   run proof Balance Audio into ~/corpus/work/<run>/, then the balanced-copy
#             proof, on the one-sided-sound files (needs a --ref with the engine)
#   status    the testbed lock, then the newest run of each lane judged against
#             the lane's baseline: counts, outcome words, and each changed file
#             by SHA-256 prefix (old -> new)
#   accept    blesses the lane's newest run as its baseline (records the run, its
#             commit, who and when). A lane's verdict is its diff against the
#             baseline: AMBER when a file's outcome word moved, RED when a file
#             crashed an engine or timed out. Refused for a RED or partial run.
#
# The corpus is copies of real family media: it never leaves the M4, and this
# script prints nothing but counts, outcome words and codec names. The harness
# refuses any host but the M4 and any state root outside ~/corpus/state.
#
# Exit: m4_run.sh's (0 started / GREEN or AMBER with --wait · 1 RED · 2 usage ·
# 3 busy · 5 nightly window).
#
# Tests: tests/test_corpus_run.py.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M4_SSH="ricksm4.local"

usage() {
    sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

VERB="${1:-}"; [ $# -gt 0 ] && shift
case "$VERB" in
    prepare)
        # The harness's own commit is checked out on the host; prepare reads nothing from the tree.
        exec /bin/bash "$SCRIPT_DIR/m4_run.sh" corpus --host m4 --corpus-lane prepare --ref HEAD "$@" ;;
    run)
        LANE="${1:-}"; [ $# -gt 0 ] && shift
        case "$LANE" in check|proof) ;; *) echo "corpus_run: run wants check|proof" >&2; exit 2 ;; esac
        exec /bin/bash "$SCRIPT_DIR/m4_run.sh" corpus --host m4 --corpus-lane "$LANE" "$@" ;;
    status)
        if [ "${1:-}" = --dry-run ]; then
            /bin/bash "$SCRIPT_DIR/m4_run.sh" status --host m4 --dry-run
            echo "+ ssh $M4_SSH python3 - status < $SCRIPT_DIR/corpus_run.py"
            exit 0
        fi
        [ $# -eq 0 ] || usage
        /bin/bash "$SCRIPT_DIR/m4_run.sh" status --host m4 || exit 1
        # The helper's own source on stdin: status never depends on what is installed on the host.
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$M4_SSH" "python3 - status" <"$SCRIPT_DIR/corpus_run.py" ;;
    accept)
        LANE="${1:-}"; [ $# -gt 0 ] && shift
        case "$LANE" in check|proof) ;; *) echo "corpus_run: accept wants check|proof" >&2; exit 2 ;; esac
        # Who: this account on this Mac, as one word (the helper scrubs it again).
        WHO="$(id -un 2>/dev/null)@$(hostname -s 2>/dev/null)"
        WHO="$(printf '%s' "$WHO" | tr -c 'A-Za-z0-9_.@-' '_')"
        if [ "${1:-}" = --dry-run ]; then
            echo "+ ssh $M4_SSH python3 - accept $LANE --by $WHO < $SCRIPT_DIR/corpus_run.py"
            exit 0
        fi
        [ $# -eq 0 ] || usage
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$M4_SSH" "python3 - accept $LANE --by $WHO" <"$SCRIPT_DIR/corpus_run.py" ;;
    ""|-h|--help) usage ;;
    *) echo "corpus_run: unknown verb '$VERB' (prepare|run|status|accept)" >&2; exit 2 ;;
esac
