#!/bin/zsh
# A headless Claude Code session billed to Rick's Anthropic Console credits
# (not the Claude plan). The key is read from the Keychain item
# `anthropic-api-key` at run time and never written anywhere.
#
#   scripts/claude_api_session.sh <worktree> <brief.md> [budget-usd] [model]
#     worktree    absolute path of the git worktree the session works in
#     brief.md    the task brief (the whole prompt)
#     budget-usd  hard cap for this session (default 15)
#     model       default opus
#
# Output: ~/Library/Logs/VideoScan/claude-api/<stamp>-<brief>.jsonl (stream-json;
# the last line carries total_cost_usd). Permission mode `auto` with the
# project's .claude/settings.json allowlist; anything that would prompt is
# denied, so the session cannot block on a question.
set -euo pipefail

wt=${1:?worktree path}
brief=${2:?brief file}
budget=${3:-15}
model=${4:-opus}

[[ -d $wt/.git || -f $wt/.git ]] || { print -u2 "not a git worktree: $wt"; exit 2; }
[[ $wt != "$HOME/dev/VideoScan" ]] || { print -u2 "refusing Rick's checkout; use a worktree"; exit 2; }
[[ -r $brief ]] || { print -u2 "brief not readable: $brief"; exit 2; }

key=$(/usr/bin/security find-generic-password -s anthropic-api-key -w 2>/dev/null) \
  || { print -u2 "Keychain item anthropic-api-key not found"; exit 3; }

logdir=$HOME/Library/Logs/VideoScan/claude-api
mkdir -p "$logdir"
log=$logdir/$(date +%Y%m%d-%H%M%S)-${${brief:t}:r}.jsonl
print "START claude-api session · model $model · cap \$$budget · $wt · log $log"

cd "$wt"
ANTHROPIC_API_KEY=$key "$HOME/.local/bin/claude" -p "$(<"$brief")" \
  --model "$model" --max-budget-usd "$budget" \
  --permission-mode auto --permission-prompts none \
  --output-format stream-json --verbose > "$log" 2>&1 && rc=0 || rc=$?

cost=$(/usr/bin/python3 -c 'import json,sys
c="?"
for l in open(sys.argv[1]):
    try: d=json.loads(l)
    except Exception: continue
    if d.get("type")=="result": c=d.get("total_cost_usd","?")
print(c)' "$log")
print "OUTCOME claude-api session rc=$rc cost \$$cost · log $log"
exit $rc
