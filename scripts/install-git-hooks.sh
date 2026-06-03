#!/usr/bin/env bash
# install-git-hooks.sh — copy the versioned hooks under scripts/git-hooks/
# into .git/hooks/. Idempotent — overwrites any existing hooks with the
# tracked-in-repo version.
#
# Why: git hooks aren't version-controlled by default (they live in
# .git/hooks/). Keeping the source of truth under scripts/git-hooks/
# lets the project enforce the same pre-commit checks for every
# developer. Run this once after cloning, or whenever the tracked hook
# files change.
#
# Usage:
#   scripts/install-git-hooks.sh

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
src_dir="$repo_root/scripts/git-hooks"
dst_dir="$repo_root/.git/hooks"

if [ ! -d "$src_dir" ]; then
    echo "No hooks found under $src_dir — nothing to install."
    exit 0
fi

for hook in "$src_dir"/*; do
    name=$(basename "$hook")
    cp "$hook" "$dst_dir/$name"
    chmod +x "$dst_dir/$name"
    echo "installed: $dst_dir/$name"
done

echo ""
echo "Done. Pre-commit hooks are active for this clone."
echo "To bypass on a single commit: git commit --no-verify"
