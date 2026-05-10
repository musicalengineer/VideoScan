#!/bin/bash
# verify-claude-setup.sh
# Checks that the VideoScan repo is in the expected state before committing
# the Claude Code agent team config. Run from the VideoScan repo root.
#
# Exits 0 if everything looks good, 1 if any check fails.
# Cosmetic warnings (yellow) don't cause failure.

set -u  # error on undefined vars, but don't auto-exit on failed commands —
        # we want to report all problems, not stop at the first one

# --- terminal colors (skipped if not a TTY, so it stays readable in pipes) ---
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

PASS="${G}✓${N}"
FAIL="${R}✗${N}"
WARN="${Y}!${N}"

fail_count=0
warn_count=0

note_fail() { echo "  ${FAIL} $1"; fail_count=$((fail_count + 1)); }
note_pass() { echo "  ${PASS} $1"; }
note_warn() { echo "  ${WARN} $1"; warn_count=$((warn_count + 1)); }

section() { echo; echo "${B}$1${N}"; }

# ----------------------------------------------------------------------------
# 0. Are we even in the right place?
# ----------------------------------------------------------------------------
section "0. Sanity: are we in the VideoScan repo?"

if [ ! -d .git ]; then
  echo "  ${FAIL} Not at the root of a git repo. cd to ~/dev/VideoScan and re-run."
  exit 1
fi

repo_name=$(basename "$(pwd)")
if [ "$repo_name" != "VideoScan" ]; then
  note_warn "Directory is '$repo_name', expected 'VideoScan'. Continuing anyway."
else
  note_pass "In the VideoScan repo root."
fi

# ----------------------------------------------------------------------------
# 1. .gitignore says the right thing
# ----------------------------------------------------------------------------
section "1. .gitignore configuration"

if [ ! -f .gitignore ]; then
  note_fail ".gitignore is missing entirely."
else
  if grep -qE '^\s*\.claude/?\s*$' .gitignore; then
    note_fail ".gitignore still has a blanket '.claude/' rule — this will hide everything we want to commit."
    echo "      Edit .gitignore and replace '.claude/' with '.claude/settings.local.json'"
  else
    note_pass "No blanket .claude/ ignore rule found."
  fi

  if grep -qE '^\s*\.claude/settings\.local\.json\s*$' .gitignore; then
    note_pass "Specific rule for .claude/settings.local.json is present."
  else
    note_fail "Missing rule: '.claude/settings.local.json' is not in .gitignore."
    echo "      Add this line under your '# Claude Code' section."
  fi

  if grep -qE '^\s*\.claude/worktrees/?\s*$' .gitignore; then
    note_pass "Specific rule for .claude/worktrees/ is present."
  else
    note_fail "Missing rule: '.claude/worktrees/' is not in .gitignore. This is runtime state that shouldn't be committed."
    echo "      Add this line under your '# Claude Code' section."
  fi
fi

# ----------------------------------------------------------------------------
# 2. Expected agent and command files exist
# ----------------------------------------------------------------------------
section "2. Expected .claude/ files exist"

expected_files=(
  ".claude/MANAGER.md"
  ".claude/agents/feature-dev.md"
  ".claude/agents/bug-fix.md"
  ".claude/agents/testing.md"
  ".claude/agents/qa.md"
  ".claude/agents/performance.md"
  ".claude/agents/metrics.md"
  ".claude/commands/feature.md"
  ".claude/commands/bug.md"
  ".claude/commands/harden.md"
  ".claude/settings.json"
)

for f in "${expected_files[@]}"; do
  if [ -f "$f" ]; then
    note_pass "$f"
  else
    note_fail "Missing: $f"
  fi
done

# Defensive: warn if a stray MANAGER.md is still in .claude/agents/ (would be
# treated as a dispatchable subagent and create a manager-of-manager loop)
if [ -f .claude/agents/MANAGER.md ]; then
  note_fail "Stray .claude/agents/MANAGER.md exists. MANAGER.md should ONLY live at .claude/MANAGER.md."
  echo "      Delete .claude/agents/MANAGER.md to avoid the dispatcher treating it as a subagent."
fi

# ----------------------------------------------------------------------------
# 3. settings.local.json — should exist OR not, but must be ignored if it does
# ----------------------------------------------------------------------------
section "3. settings.local.json ignore behavior"

if [ -f .claude/settings.local.json ]; then
  note_warn "settings.local.json exists — verifying it's ignored."
  if git check-ignore -q .claude/settings.local.json; then
    note_pass "settings.local.json is correctly ignored by git."
  else
    note_fail "settings.local.json EXISTS but is NOT ignored! It will be committed if you 'git add .claude/'."
    echo "      Fix .gitignore before staging."
  fi
else
  note_pass "settings.local.json does not exist yet — will be created by Claude Code later. Fine."
fi

# ----------------------------------------------------------------------------
# 4. Unexpected files in .claude/ (caches, history, scratch)
# ----------------------------------------------------------------------------
section "4. Unexpected files in .claude/"

# Build a list of allowed paths (relative to .claude/). These are entries that
# we either want committed, or that we know are expected runtime state.
allowed_basenames=$(printf '%s\n' \
  "agents" \
  "commands" \
  "settings.json" \
  "settings.local.json" \
  "MANAGER.md" \
  "CLAUDE-AGENTS.md" \
  "metrics-baseline.json" \
  "worktrees" \
  ".DS_Store")

unexpected_found=0
runtime_state_reported=0

if [ -d .claude ]; then
  for entry in .claude/* .claude/.*; do
    base=$(basename "$entry")
    [ "$base" = "." ] && continue
    [ "$base" = ".." ] && continue
    [ ! -e "$entry" ] && continue

    if echo "$allowed_basenames" | grep -qx "$base"; then
      # Known/expected. If it's runtime state, verify it's ignored.
      case "$base" in
        worktrees)
          runtime_state_reported=1
          if git check-ignore -q ".claude/worktrees" 2>/dev/null; then
            note_pass "worktrees/ exists and is ignored by git."
          else
            note_fail "worktrees/ exists but is NOT ignored. Would be staged by 'git add .claude/'."
          fi
          ;;
        .DS_Store)
          runtime_state_reported=1
          if git check-ignore -q ".claude/.DS_Store" 2>/dev/null; then
            note_pass ".DS_Store exists and is ignored by git."
          else
            note_fail ".DS_Store exists but is NOT ignored. (Your top-level .gitignore should handle this.)"
          fi
          ;;
      esac
    else
      note_warn "Unexpected entry in .claude/: $base"
      echo "      If it's runtime/cache state, add to .gitignore. If it's intentional config, ignore this warning."
      unexpected_found=1
    fi
  done
fi

if [ "$unexpected_found" -eq 0 ] && [ "$runtime_state_reported" -eq 0 ]; then
  note_pass "No unexpected files in .claude/."
fi

# ----------------------------------------------------------------------------
# 5. settings.json shape — basic sanity, not deep validation
# ----------------------------------------------------------------------------
section "5. settings.json basic sanity"

if [ -f .claude/settings.json ]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json,sys; json.load(open('.claude/settings.json'))" 2>/dev/null; then
      note_pass "settings.json is valid JSON."
    else
      note_fail "settings.json is NOT valid JSON. Claude Code will fail to load it."
    fi
  else
    note_warn "python3 not available — skipping JSON validation."
  fi

  if grep -q '"permissions"' .claude/settings.json; then
    note_pass "Contains 'permissions' key."
  else
    note_warn "No 'permissions' key found in settings.json."
  fi
else
  note_fail "settings.json is missing (already reported above)."
fi

# ----------------------------------------------------------------------------
# 6. What git is about to do
# ----------------------------------------------------------------------------
section "6. git status — what will get committed"

echo
git status --short
echo

# Final paranoia: any runtime state in the staged/untracked .claude/ output?
suspicious=$(git status --porcelain .claude/ 2>/dev/null | grep -E '(cache|history|\.log$|\.tmp$|scratch|worktrees|\.DS_Store)' || true)
if [ -n "$suspicious" ]; then
  note_fail "git sees runtime/cache files in .claude/ that should be ignored:"
  echo "$suspicious" | sed 's/^/        /'
  echo "      Update .gitignore to exclude these before staging."
else
  note_pass "No runtime state appears in git's view of .claude/."
fi

if [ -f .claude/settings.local.json ]; then
  would_stage=$(git status --porcelain .claude/settings.local.json 2>/dev/null)
  if [ -n "$would_stage" ]; then
    note_fail "git sees changes to settings.local.json (it would be committed). Fix .gitignore!"
  fi
fi

# ----------------------------------------------------------------------------
# 7. Other modified files in the repo — informational only
# ----------------------------------------------------------------------------
section "7. Other modified files (informational)"

# Exclude .gitignore (belongs in this commit), the .claude/ dir, and this
# script itself from "unrelated" status.
other_modified=$(git status --porcelain \
  | grep -vE '^\?\? \.claude/|^.M \.claude/|\.gitignore$|verify-claude-setup\.sh$' \
  || true)

if [ -n "$other_modified" ]; then
  note_warn "These files are also modified and would be picked up by 'git add -A':"
  echo "$other_modified" | sed 's/^/        /'
  echo "      Decide if they belong in the agent-setup commit or a separate one."
else
  note_pass "No unrelated modifications outside .claude/ and .gitignore."
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
section "Summary"

echo "  Failures: $fail_count"
echo "  Warnings: $warn_count"
echo

if [ "$fail_count" -gt 0 ]; then
  echo "${R}${B}NOT READY TO COMMIT.${N} Fix the ✗ items above and re-run."
  exit 1
elif [ "$warn_count" -gt 0 ]; then
  echo "${Y}${B}READY TO COMMIT, with warnings.${N} Review the ! items, then if they're fine:"
  echo
  echo "  git add .gitignore .claude/"
  echo "  git status   # final eyeball check"
  echo "  git commit -m \"Add Claude Code agent team config and project settings\""
  exit 0
else
  echo "${G}${B}ALL CHECKS PASSED.${N} Suggested commit sequence:"
  echo
  echo "  git add .gitignore .claude/"
  echo "  git status   # final eyeball check"
  echo "  git commit -m \"Add Claude Code agent team config and project settings\""
  exit 0
fi