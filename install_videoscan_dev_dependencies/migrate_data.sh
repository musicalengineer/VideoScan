#!/usr/bin/env bash
# install_videoscan_dev_dependencies/migrate_data.sh
#
# Copies VideoScan's DATA from an old Mac to this one, for a migration like
# M4 → M5 Ultra. The dev tools come from install.sh; this is the part that
# cannot be re-downloaded: the catalog, People, CyberBrain, ledger, archive
# journals, and the git-ignored family photos and models in the checkout.
#
# Safety rules (Rick's delete-safety principle applies to copies too):
#   - PULL ONLY. The source Mac is read, never written.
#   - DRY RUN BY DEFAULT. Nothing is copied until you add --go.
#   - Never deletes on this Mac. A file this copy would replace is kept
#     beside it as <name>.pre-migrate-<stamp>.
#   - Refuses while VideoScan is running on either Mac (the catalog lock and
#     SQLite WAL files must be quiescent to copy consistently).
#   - Copies only git-IGNORED files into the checkout, from a list made on
#     the source, so it can never overwrite tracked code in the fresh clone.
#
# Usage:
#   ./migrate_data.sh --from RicksM4.local              dry run: what would copy
#   ./migrate_data.sh --from RicksM4.local --go         copy it
#   add --with-ollama  to also copy ~/.ollama/models   (~56 GB; or re-pull)
#   add --with-hf      to also copy ~/.cache/huggingface (~9 GB; or re-download)

set -euo pipefail

SOURCE=""
GO=0
WITH_OLLAMA=0
WITH_HF=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)        SOURCE="${2:-}"; shift 2 ;;
        --go)          GO=1; shift ;;
        --with-ollama) WITH_OLLAMA=1; shift ;;
        --with-hf)     WITH_HF=1; shift ;;
        -h|--help)     sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$SOURCE" ]] || { echo "usage: $0 --from HOST [--go] [--with-ollama] [--with-hf]" >&2; exit 2; }

STAMP=$(date +%Y%m%d-%H%M%S)
CHECKOUT="$HOME/dev/VideoScan"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

# macOS ships openrsync (protocol 29) as /usr/bin/rsync; it lacks the
# options used here. Use Homebrew's rsync 3.x on both ends.
RSYNC=/opt/homebrew/bin/rsync
[[ -x "$RSYNC" ]] || { echo "need Homebrew rsync on this Mac: brew install rsync" >&2; exit 1; }
"${SSH[@]}" "$SOURCE" test -x /opt/homebrew/bin/rsync \
    || { echo "need Homebrew rsync on $SOURCE: brew install rsync" >&2; exit 1; }

# -s protects paths with spaces ("Application Support"); --backup keeps any
# file this copy would replace; no --delete, ever.
RSYNC_OPTS=(-a -s --human-readable --stats
            --rsync-path=/opt/homebrew/bin/rsync
            -e "ssh -o BatchMode=yes -o ConnectTimeout=10"
            --backup --suffix=".pre-migrate-$STAMP")
if [[ "$GO" == "1" ]]; then
    echo "COPYING from $SOURCE (backups of replaced files: *.pre-migrate-$STAMP)"
else
    RSYNC_OPTS+=(--dry-run)
    echo "DRY RUN from $SOURCE — nothing will be copied. Add --go to copy."
fi

# ---- refuse while the app is running anywhere ----
if pgrep -x VideoScan >/dev/null; then
    echo "REFUSING: VideoScan is running on this Mac. Quit it first." >&2; exit 1
fi
if "${SSH[@]}" "$SOURCE" pgrep -x VideoScan >/dev/null 2>&1; then
    echo "REFUSING: VideoScan is running on $SOURCE. Quit it there first." >&2; exit 1
fi
[[ -d "$CHECKOUT/.git" ]] || { echo "clone the repo to $CHECKOUT first (then run install.sh)" >&2; exit 1; }

section() { echo; echo "== $1 =="; }

# ---- 1. App Support: catalog, People, CyberBrain, ledger, journals ----
section "Application Support/VideoScan"
# HallieKokoro is rebuilt by install.sh (it is a compiled binary + model);
# preview-cache is regenerated on demand.
"$RSYNC" "${RSYNC_OPTS[@]}" \
    --exclude "HallieKokoro*" --exclude "preview-cache/" \
    "$SOURCE:Library/Application Support/VideoScan/" \
    "$HOME/Library/Application Support/VideoScan/"

# ---- 2. git-ignored data inside the checkout ----
section "Git-ignored data in ~/dev/VideoScan (family photos, models, profiles)"
LIST=$(mktemp "${TMPDIR:-/tmp}/videoscan-migrate-list.XXXXXX")
trap 'rm -f "$LIST"' EXIT
# Built on the SOURCE, so it is exactly what that checkout ignores. Excludes
# things install.sh rebuilds or that are scratch: venvs, build products,
# caches, worktrees, the repo trash, profiler output.
"${SSH[@]}" "$SOURCE" "git -C dev/VideoScan status --ignored --porcelain -z" \
    | tr '\0' '\n' | sed -n 's/^!! //p' \
    | grep -v -E '^(venv|venv-[^/]*|\.build|\.cache|\.pytest_cache|\.trash|\.worktrees|\.codex-worktrees|codex-worktrees|\.claude/worktrees)(/|$)' \
    | grep -v -E '(^|/)(\.build[^/]*|__pycache__|DerivedData|\.swiftpm)(/|$)|\.DS_Store|default\.profraw' \
    > "$LIST" || true
echo "$(wc -l < "$LIST" | tr -d ' ') ignored paths listed on $SOURCE"
"$RSYNC" "${RSYNC_OPTS[@]}" -r --files-from="$LIST" \
    "$SOURCE:dev/VideoScan/" "$CHECKOUT/"

# ---- 3. optional big caches ----
if [[ "$WITH_OLLAMA" == "1" ]]; then
    section "Ollama models (~/.ollama/models)"
    "$RSYNC" "${RSYNC_OPTS[@]}" "$SOURCE:.ollama/models/" "$HOME/.ollama/models/"
fi
if [[ "$WITH_HF" == "1" ]]; then
    section "Hugging Face cache (~/.cache/huggingface)"
    "$RSYNC" "${RSYNC_OPTS[@]}" "$SOURCE:.cache/huggingface/" "$HOME/.cache/huggingface/"
fi

echo
if [[ "$GO" == "1" ]]; then
    echo "Done. Next: ./install.sh --check, then open VideoScan and confirm the catalog count matches $SOURCE."
else
    echo "Dry run complete. Review the totals above, then re-run with --go."
fi
