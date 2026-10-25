#!/usr/bin/env bash
# sensor_lane_stamp.sh <repo> — record "sensor lane GREEN" for the exact working
# tree of <repo>, so the pre-push hook (scripts/git-hooks/pre-push) can let a
# push of main through when the pushed commit's tree is one that was stamped.
#
# Called by run_sensors.sh after a GREEN run. The tree hash covers tracked and
# untracked-but-not-ignored files (what a `git add -A` would commit), computed
# in a scratch index so the real index is untouched. Prints
#   sensor lane stamp: tree <hash> recorded
# on success and a loud line on failure; exit 1 on failure so the caller can
# tell (a stamp that silently fails means every push is refused — that is what
# happened from 2026-10-23 to 2026-10-25).
#
#   scripts/sensor_lane_stamp.sh /path/to/checkout-or-worktree
set -u
REPO="${1:?usage: sensor_lane_stamp.sh <repo>}"

common="$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)"
if [ -z "$common" ]; then
    echo "sensor lane stamp NOT recorded: $REPO is not a git repository" >&2
    exit 1
fi
case "$common" in /*) ;; *) common="$REPO/$common" ;; esac

# mktemp CREATES the file, and git refuses an existing zero-length index
# ("index file smaller than expected") — the 10/23–10/25 bug. Git wants the
# path to be absent so it can create the index itself.
tmp_index="$(mktemp)"
rm -f "$tmp_index"
tree="$(GIT_INDEX_FILE="$tmp_index" git -C "$REPO" add -A . 2>/dev/null && GIT_INDEX_FILE="$tmp_index" git -C "$REPO" write-tree 2>/dev/null)"
rm -f "$tmp_index"
if [ -z "$tree" ]; then
    echo "sensor lane stamp NOT recorded: could not hash the working tree of $REPO (scratch index failed)" >&2
    exit 1
fi

stamp="$common/sensor-lane-green"
{ [ -f "$stamp" ] && tail -n 49 "$stamp"; echo "$tree $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$stamp.tmp" && mv "$stamp.tmp" "$stamp"
echo "sensor lane stamp: tree $tree recorded"
