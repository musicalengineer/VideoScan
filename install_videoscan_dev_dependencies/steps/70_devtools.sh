# Step: devtools — git hooks, logins, fleet ssh, and (opt-in) scheduled jobs.
# Logins are checked, never performed: they are Rick's accounts.

section "Developer tooling"

# ---- git hooks (scripts/git-hooks/ is the source of truth) ----
hook_src="$REPO_ROOT/scripts/git-hooks/pre-commit"
git_dir=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)
if [[ -n "$git_dir" && -f "$hook_src" ]]; then
    [[ "$git_dir" = /* ]] || git_dir="$REPO_ROOT/$git_dir"
    if cmp -s "$hook_src" "$git_dir/hooks/pre-commit"; then
        ok "pre-commit hook installed"
    elif checking; then
        failed "pre-commit hook" "missing or stale; run scripts/install-git-hooks.sh"
    elif bash "$REPO_ROOT/scripts/install-git-hooks.sh" >/dev/null 2>&1; then
        installed "pre-commit hook"
    else
        failed "pre-commit hook" "run scripts/install-git-hooks.sh"
    fi
fi

if command -v git-lfs >/dev/null 2>&1; then
    if git config --global --get filter.lfs.process >/dev/null 2>&1; then
        ok "git-lfs initialised"
    elif ! checking && git lfs install >/dev/null 2>&1; then
        installed "git-lfs hooks (git lfs install)"
    else
        failed "git-lfs" "run: git lfs install"
    fi
fi

if [[ -n "$(git config --global user.name)" && -n "$(git config --global user.email)" ]]; then
    ok "git identity ($(git config --global user.name))"
else
    manual "git identity" "git config --global user.name 'RickB'; git config --global user.email <your address>"
fi

# ---- logins (names only; never print tokens) ----
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    ok "gh signed in"
else
    manual "gh sign-in" "gh auth login (issues, metrics, nightly reporting)"
fi
if [[ -d "$HOME/.codex" ]]; then
    ok "codex config present (~/.codex)"
else
    manual "codex sign-in" "codex login (only for codex review passes)"
fi

# ---- fleet ssh (CatalogSync, TestDriver, models --copy-from) ----
this_host=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
for host in RicksM4.local RicksM5.local RicksM1.local; do
    [[ "${host%%.*}" == "$this_host" ]] && continue
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true >/dev/null 2>&1; then
        ok "ssh to $host"
    else
        manual "ssh to $host" "ssh-copy-id $host (needs Remote Login on $host); skip if that Mac is off or retired"
    fi
done

# ---- scheduled jobs (opt-in) ----
# install_nightly.sh picks the slot by hostname (*M4* 02:00, *M5* 03:15,
# *M1* 04:30). A new Mac must not join that rota until Rick decides its role.
section "Scheduled jobs (LaunchAgents)"
installed_agents=$(ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -c '^com\.videoscan\.' || true)
if [[ "$WITH_SCHEDULES" != "1" ]]; then
    if [[ "$installed_agents" -gt 0 ]]; then
        ok "$installed_agents com.videoscan LaunchAgents already installed (left alone)"
    else
        manual "scheduled jobs" "none installed; decide this Mac's fleet role, then re-run with --with-schedules (see MIGRATION_PLAN.md)"
    fi
elif checking; then
    note "--check: not installing LaunchAgents"
else
    case "$this_host" in
        *M4*|*M5*|*M1*)
            bash "$REPO_ROOT/scripts/install_nightly.sh" && installed "nightly tests agent ($this_host)" \
                || failed "nightly agent" "scripts/install_nightly.sh failed"
            ;;
        *)
            failed "nightly agent" "hostname '$this_host' has no slot in scripts/install_nightly.sh; add one first"
            ;;
    esac
    note "sanitizer and adversarial agents are M4-only today; install them by hand if this Mac takes that role:"
    note "  bash scripts/install_sanitizer_weekly.sh ; bash scripts/adversarial/install.sh"
fi
