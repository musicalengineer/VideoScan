#!/usr/bin/env bash
# corpus_run.sh — the real-data corpus harness (docs/guides/operations.md §1a;
# DECISIONS 2026-11-17 "The M4 holds a real-data test corpus").
#
#   scripts/corpus_run.sh prepare             [--wait] [--dry-run]
#   scripts/corpus_run.sh run <check|proof|verbs|sweep> [--ref <rev>] [--deadline <s>] [--limit <n>] [--wait] [--force] [--dry-run]
#   scripts/corpus_run.sh stage sweep --ref <rev> --limit <n> [--max-gb <g>] [--budget-gb <g>] [--dry-run]
#   scripts/corpus_run.sh status              [--dry-run]
#   scripts/corpus_run.sh accept <check|proof|verbs|sweep> [--dry-run]
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
#   run sweep the check lane's engines over the wider collection, read in place on the
#             read-only share mounted under ~/corpus/live (the catalog backup's live rows
#             there); --limit N takes the next N files this commit has not swept yet.
#             Reports add what each file cost (wall, CPU, ffprobe/ffmpeg CPU, footprint)
#   run verbs the verbs that move, trash and promote, by the app's real engines, on
#             CLONES of ~20 corpus files under ~/corpus/work/<run>/ (cp -c: no extra
#             space): Find + Delete Duplicates, Move to Trash, Remove and Remove
#             from Catalog each followed by a rescan, Promote into a scratch
#             archive. Never the Finder Trash, never a real archive; ~/corpus/media
#             is proven untouched by a size+mtime sweep before and after
#   stage sweep  over ssh, under the testbed lock: copies the next <n> files a sweep at <rev>
#             has not run from the read-only share into ~/corpus/work/sweep-stage/<commit>/,
#             each checked against the catalog's SHA-256 (files over --max-gb, default 8,
#             wait; at most --budget-gb, default 150, and never below 10% of the disk free).
#             The next `run sweep --ref <rev>` sweeps those copies and removes them. Why: the
#             ad-hoc-signed test host is asked by macOS, on the M4's screen, before it may open
#             a network volume (again at every build); an ssh session may.
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
    sed -n '4,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

VERB="${1:-}"; [ $# -gt 0 ] && shift
case "$VERB" in
    prepare)
        # The harness's own commit is checked out on the host; prepare reads nothing from the tree.
        exec /bin/bash "$SCRIPT_DIR/m4_run.sh" corpus --host m4 --corpus-lane prepare --ref HEAD "$@" ;;
    run)
        LANE="${1:-}"; [ $# -gt 0 ] && shift
        case "$LANE" in check|proof|verbs|sweep) ;; *) echo "corpus_run: run wants check|proof|verbs|sweep" >&2; exit 2 ;; esac
        exec /bin/bash "$SCRIPT_DIR/m4_run.sh" corpus --host m4 --corpus-lane "$LANE" "$@" ;;
    stage)
        LANE="${1:-}"; [ $# -gt 0 ] && shift
        [ "$LANE" = sweep ] || { echo "corpus_run: stage wants sweep" >&2; exit 2; }
        REF=""; LIMIT=""; MAXGB=""; BUDGET=""; DRY=0
        while [ $# -gt 0 ]; do
            case "$1" in
                --ref) REF="${2:-}"; shift 2 || usage ;;
                --limit) LIMIT="${2:-}"; shift 2 || usage ;;
                --max-gb) MAXGB="${2:-}"; shift 2 || usage ;;
                --budget-gb) BUDGET="${2:-}"; shift 2 || usage ;;
                --dry-run) DRY=1; shift ;;
                *) usage ;;
            esac
        done
        [[ "$LIMIT" =~ ^[0-9]+$ ]] || { echo "corpus_run: stage wants --limit <n files>" >&2; exit 2; }
        [ -z "$MAXGB" ] || [[ "$MAXGB" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "corpus_run: --max-gb wants a number" >&2; exit 2; }
        [ -z "$BUDGET" ] || [[ "$BUDGET" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "corpus_run: --budget-gb wants a number" >&2; exit 2; }
        SHA="$(git -C "$SCRIPT_DIR/.." rev-parse --verify "${REF:-HEAD}^{commit}" 2>/dev/null)" \
            || { echo "corpus_run: --ref does not name a commit" >&2; exit 2; }
        ARGS="stage sweep --sha $SHA --limit $LIMIT${MAXGB:+ --max-gb $MAXGB}${BUDGET:+ --budget-gb $BUDGET}"
        if [ "$DRY" = 1 ]; then
            echo "+ ssh $M4_SSH python3 - $ARGS < $SCRIPT_DIR/corpus_run.py"
            exit 0
        fi
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$M4_SSH" "python3 - $ARGS" <"$SCRIPT_DIR/corpus_run.py" ;;
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
        case "$LANE" in check|proof|verbs|sweep) ;; *) echo "corpus_run: accept wants check|proof|verbs|sweep" >&2; exit 2 ;; esac
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
    *) echo "corpus_run: unknown verb '$VERB' (prepare|run|stage|status|accept)" >&2; exit 2 ;;
esac
