#!/bin/bash
# agent-status.sh — append one agent-status row to the shared dashboard feed.
#
# Part of the Agent Dashboard (docs/agent_dashboard.md): both managers
# (Claude, Codex) append rows here; the engineering-room UI renders the
# latest row per agent. Append-only, attributed, honest — a stale row is
# better than a fake-live one, so rows carry timestamps and the UI shows
# "last seen" age rather than pretending liveness.
#
# Usage:
#   scripts/agent-status.sh <manager> <agent> <state> <task> [progress] [blockedOn] [machine]
#     manager   claude | codex
#     agent     short id, e.g. "feature-dev/trim-master" or "qa/a0b09c9"
#     state     working | idle | blocked | waiting-on-human | done | failed
#     task      short description (quote it)
#     progress  optional (quote it)
#     blockedOn optional — REQUIRED when state=blocked|waiting-on-human
#     machine   none | m4 | m5 | m1 (defaults to none for legacy/headless callers)
#
# Example:
#   scripts/agent-status.sh claude "qa/trim" working "QA review of feature/trim-master" "reading diff"

set -euo pipefail

DEFAULT_FEED="$(cd "$(dirname "$0")/.." && pwd)/tools/engineering-room/var/agent-status.jsonl"
FEED="${ENGINEERING_ROOM_STATUS_FEED:-$DEFAULT_FEED}"
mkdir -p "$(dirname "$FEED")"

manager="${1:?manager}" ; agent="${2:?agent}" ; state="${3:?state}" ; task="${4:?task}"
progress="${5:-}" ; blockedOn="${6:-}" ; machine="${7:-none}"

case "$state" in
  working|idle|blocked|waiting-on-human|done|failed) ;;
  *) echo "invalid state: $state" >&2; exit 1 ;;
esac
if [[ "$state" == "blocked" || "$state" == "waiting-on-human" ]] && [[ -z "$blockedOn" ]]; then
  echo "state '$state' requires blockedOn" >&2; exit 1
fi
case "$machine" in
  none|m4|m5|m1) ;;
  *) echo "invalid machine: $machine" >&2; exit 1 ;;
esac

# JSON-escape via python (always present on macOS).
python3 - "$manager" "$agent" "$state" "$task" "$progress" "$blockedOn" "$machine" >> "$FEED" <<'PY'
import json, sys, datetime
m, a, s, t, p, b, machine = sys.argv[1:8]
row = {"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
       "manager": m, "agent": a, "state": s, "task": t, "machine": machine}
if p: row["progress"] = p
if b: row["blockedOn"] = b
print(json.dumps(row))
PY
