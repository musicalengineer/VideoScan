# Step: homebrew — everything in the repo-root Brewfile (single source of truth).

section "Homebrew packages (Brewfile)"

BREWFILE="$REPO_ROOT/Brewfile"
if ! command -v brew >/dev/null 2>&1; then
    failed "Brewfile" "Homebrew is not installed (see preflight)"
elif checking; then
    # Lines look like "→ Formula jpeg needs to be installed." and go to
    # STDERR — discarding stderr here once turned every check green.
    missing=$(HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --file="$BREWFILE" --verbose --no-upgrade 2>&1 \
        | grep -E "needs to be installed" || true)
    if [[ -z "$missing" ]]; then
        ok "every Brewfile entry is installed"
    else
        while IFS= read -r line; do
            failed "brew: $(echo "$line" | awk '{print tolower($2) " " $3}')" "missing (run without --check to install)"
        done <<< "$missing"
    fi
else
    note "brew bundle --file=$BREWFILE (first run takes a while: ffmpeg, python, node, ollama…)"
    if brew bundle --file="$BREWFILE" --no-upgrade; then
        ok "Brewfile satisfied"
    else
        failed "brew bundle" "re-run: brew bundle --file=$BREWFILE --verbose"
    fi
fi

# Tools that are not in Homebrew but that scripts call.
if [[ -x "$HOME/.local/bin/claude" ]] || command -v claude >/dev/null 2>&1; then
    ok "claude CLI"
else
    manual "claude CLI" "installed by the claude-code cask; then run 'claude' once to sign in"
fi
if [[ -x "$HOME/.local/bin/codex" ]] || command -v codex >/dev/null 2>&1; then
    ok "codex CLI"
else
    # tools/codex_review.py and dev_updater.sh expect ~/.local/bin/codex.
    manual "codex CLI" "install codex so it lands in ~/.local/bin/codex, then 'codex login' (only needed for codex review passes)"
fi
