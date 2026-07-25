#!/bin/zsh
# team-channel watcher — turns a new channel message into a LOCAL poke of the
# addressed agent. The poll itself costs zero tokens and zero network: it
# watches the channel directory on disk (both agents write here before
# pushing). Tokens are spent only when an agent is actually woken, and the
# wake prompt is triage-only.
#
# Usage:
#   watch_channel.sh --daemon        # poll loop (launchd entry point)
#   watch_channel.sh --once          # single poll pass (cron/manual)
#   watch_channel.sh --poke <agent>  # manual wake, ignores cooldown (rick's poke)
#   DRY_RUN=1 watch_channel.sh ...   # log what would happen, wake nobody
#
# Config (env, all optional):
#   CHANNEL_REPO           repo root        (default ~/dev/VideoScan)
#   CHANNEL_POLL_SECONDS   poll interval    (default 120)
#   CHANNEL_WAKE_COOLDOWN  per-agent cooldown seconds (default 1800)
#   CODEX_WAKE_CMD         wake command for codex  (default: codex exec -)
#   CLAUDE_WAKE_CMD        wake command for claude (default: claude -p --model opus)
#     Claude wakes default to Opus deliberately: channel triage does not need
#     the top model. The woken agent can tell Rick if a full session is needed.

set -u

REPO="${CHANNEL_REPO:-$HOME/dev/VideoScan}"
CHANNEL="$REPO/docs/team-channel"
STATE_DIR="${CHANNEL_WATCHER_STATE:-$HOME/Library/Application Support/VideoScan/channel-watcher}"
LOG_DIR="$HOME/Library/Logs/VideoScan"
SEEN="$STATE_DIR/seen.txt"
INTERVAL="${CHANNEL_POLL_SECONDS:-120}"
COOLDOWN="${CHANNEL_WAKE_COOLDOWN:-1800}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STATE_DIR" "$LOG_DIR"
LOG="$LOG_DIR/channel-watcher.log"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" }

wake_prompt() {
  local files="$1"
  cat <<EOF
New team-channel message(s) for you in $CHANNEL: $files
Triage only, minimal tokens: read ONLY the new message(s) and anything they
reference. If a reply is warranted, write it in-channel per the README and
commit/push it (docs commits are exempt from the merge gate). If it requests
substantial work, reply acknowledging + queue it for your next full session —
do NOT start large work from this wake. If the message is already answered
in-channel, exit without writing anything.
EOF
}

cooldown_active() {
  local stamp="$STATE_DIR/last-wake-$1"
  [[ -f "$stamp" ]] || return 1
  (( $(date +%s) - $(stat -f %m "$stamp") < COOLDOWN ))
}

wake() {
  local agent="$1" files="$2" force="${3:-0}"
  local stamp="$STATE_DIR/last-wake-$agent"
  local pending="$STATE_DIR/pending-$agent"
  if [[ "$force" != 1 ]] && cooldown_active "$agent"; then
    # Not dropped: queue for retry once the cooldown expires.
    print -r -- "$files" >> "$pending"
    log "defer wake $agent (cooldown active): $files"
    return 0
  fi
  # Fold any deferred files into this wake so nothing is swallowed.
  if [[ -f "$pending" ]]; then
    files="$files, $(paste -sd ', ' - < "$pending")"
    rm -f "$pending"
  fi
  touch "$stamp"
  local prompt; prompt="$(wake_prompt "$files")"
  if [[ "$DRY_RUN" == 1 ]]; then
    log "DRY_RUN: would wake $agent for: $files"
    return 0
  fi
  log "waking $agent for: $files"
  case "$agent" in
    codex)
      # `codex exec` reads the task from stdin with `-`. Override via CODEX_WAKE_CMD.
      ( cd "$REPO" && print -r -- "$prompt" | ${=CODEX_WAKE_CMD:-codex exec -} ) \
        >> "$LOG_DIR/channel-watcher-codex.log" 2>&1 &
      ;;
    claude)
      ( cd "$REPO" && ${=CLAUDE_WAKE_CMD:-claude -p --model opus} "$prompt" ) \
        >> "$LOG_DIR/channel-watcher-claude.log" 2>&1 &
      ;;
    *) log "unknown agent: $agent"; return 1 ;;
  esac
}

# author = 5th hyphen-separated token of YYYY-MM-DD-HHMM-author-slug.md
author_of() { print -r -- "${1:t}" | cut -d- -f5 }

poll_once() {
  [[ -d "$CHANNEL" ]] || { log "channel dir missing: $CHANNEL"; return 1 }
  touch "$SEEN"
  local -a new_for_codex=() new_for_claude=()
  for f in "$CHANNEL"/*.md(N); do
    local base="${f:t}"
    [[ "$base" == "README.md" ]] && continue
    grep -qxF "$base" "$SEEN" && continue
    print -r -- "$base" >> "$SEEN"
    case "$(author_of "$base")" in
      claude) new_for_codex+=("$base") ;;
      codex)  new_for_claude+=("$base") ;;
      rick)   new_for_codex+=("$base"); new_for_claude+=("$base") ;;
      *)      log "unrecognized author in: $base" ;;
    esac
  done
  (( ${#new_for_codex} ))  && wake codex  "${(j:, :)new_for_codex}"
  (( ${#new_for_claude} )) && wake claude "${(j:, :)new_for_claude}"
  # Retry deferred wakes whose cooldown has since expired (no new message needed).
  local agent
  for agent in codex claude; do
    if [[ -s "$STATE_DIR/pending-$agent" ]] && ! cooldown_active "$agent"; then
      wake "$agent" "deferred:"
    fi
  done
  return 0
}

case "${1:---daemon}" in
  --once) poll_once ;;
  --poke) wake "${2:?usage: --poke codex|claude}" "(manual poke from Rick)" 1 ;;
  --daemon)
    log "watcher started (interval=${INTERVAL}s cooldown=${COOLDOWN}s dry_run=$DRY_RUN)"
    # First pass marks everything currently in the channel as seen, so a
    # (re)start never replays history as fresh wakes.
    touch "$SEEN"
    for f in "$CHANNEL"/*.md(N); do
      grep -qxF "${f:t}" "$SEEN" || print -r -- "${f:t}" >> "$SEEN"
    done
    while true; do
      poll_once
      sleep "$INTERVAL"
    done
    ;;
  *) print -u2 "usage: $0 [--daemon|--once|--poke codex|claude]"; exit 2 ;;
esac
