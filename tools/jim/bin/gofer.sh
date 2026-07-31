#!/usr/bin/env bash
# gofer.sh — delegate a bounded task to a local (or cloud-escalated) LLM "employee".
#
# Modular by design: an "employee" is just  name + employees/<name>.conf + personas/<name>.md.
# You normally invoke it through a name-symlink so the command reads like a person:
#
#     jim "Draft a one-line commit message for: bumped ffprobe timeout to 30s"
#
# ...where bin/jim is a symlink to this script. The invoked name selects the employee.
# You can also be explicit:  gofer.sh --employee jim "..."   or   GOFER_EMPLOYEE=jim gofer.sh "..."
#
# Hire a new employee (e.g. Bob):
#     cp employees/jim.conf employees/bob.conf   # then edit MODEL / persona / params
#     cp personas/jim.md    personas/bob.md      # then edit the job description
#     ln -s gofer.sh        bin/bob
#     bob "some task"
#
# Task text comes from the arguments, or from stdin if no args are given:
#     cat diff.txt | jim --escalate "Write release notes for this diff"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

die() { printf 'gofer: %s\n' "$*" >&2; exit 1; }

show_help() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Flags:
  --employee NAME   Pick the employee explicitly (default: the invoked command name).
  --escalate        Use the employee's ESCALATION_MODEL (cloud) instead of the local brain.
  --dry-run         Print the resolved request and exit without calling anything.
  --raw             Print the full JSON response instead of just the message text.
  -h, --help        This help.
EOF
}

# --- parse args -------------------------------------------------------------
INVOKED="$(basename "$0")"
case "$INVOKED" in gofer|gofer.sh) INVOKED="" ;; esac

DRY_RUN=0; RAW=0; ESCALATE=0
EMPLOYEE_OVERRIDE="${GOFER_EMPLOYEE:-}"
declare -a ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --employee)   EMPLOYEE_OVERRIDE="${2:-}"; shift 2 ;;
    --employee=*) EMPLOYEE_OVERRIDE="${1#*=}"; shift ;;
    --escalate)   ESCALATE=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --raw)        RAW=1; shift ;;
    -h|--help)    show_help; exit 0 ;;
    --)           shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done

# --- resolve employee + config ---------------------------------------------
# shellcheck source=/dev/null
source "$ROOT/config.sh"

EMPLOYEE="${EMPLOYEE_OVERRIDE:-${INVOKED:-$DEFAULT_EMPLOYEE}}"
CONF="$ROOT/employees/$EMPLOYEE.conf"
if [ ! -f "$CONF" ]; then
  avail="$(cd "$ROOT/employees" 2>/dev/null && ls *.conf 2>/dev/null | sed 's/\.conf$//' | grep -v '^_' | tr '\n' ' ')"
  die "no such employee '$EMPLOYEE' (available: ${avail:-none})"
fi

# Shared defaults first; the employee .conf may override any of these.
HOST="$DEFAULT_HOST"; PORT="$DEFAULT_PORT"; SCHEME="$DEFAULT_SCHEME"
TEMPERATURE="$DEFAULT_TEMPERATURE"; MAX_TOKENS="$DEFAULT_MAX_TOKENS"
TIMEOUT="$DEFAULT_TIMEOUT"; STRIP_THINK="$DEFAULT_STRIP_THINK"
MODEL=""; ESCALATION_MODEL=""; PERSONA=""; EMPLOYEE_NAME="$EMPLOYEE"; EMPLOYEE_ROLE=""
# shellcheck source=/dev/null
source "$CONF"

[ -n "$MODEL" ] || die "employee '$EMPLOYEE' has no MODEL set in $CONF"

USE_MODEL="$MODEL"
if [ "$ESCALATE" -eq 1 ]; then
  [ -n "$ESCALATION_MODEL" ] || die "employee '$EMPLOYEE' has no ESCALATION_MODEL configured"
  USE_MODEL="$ESCALATION_MODEL"
fi

PERSONA_FILE="$ROOT/personas/${PERSONA:-$EMPLOYEE.md}"
[ -f "$PERSONA_FILE" ] || die "missing persona file: $PERSONA_FILE"
SYSTEM_PROMPT="$(cat "$PERSONA_FILE")"

# --- task text --------------------------------------------------------------
if [ "${#ARGS[@]}" -gt 0 ]; then
  TASK="${ARGS[*]}"
else
  [ -t 0 ] && die "no task given (pass as arguments or pipe via stdin)"
  TASK="$(cat)"
fi
[ -n "${TASK//[[:space:]]/}" ] || die "empty task"

# --- build request ----------------------------------------------------------
PAYLOAD="$(jq -n \
  --arg model "$USE_MODEL" \
  --arg sys "$SYSTEM_PROMPT" \
  --arg user "$TASK" \
  --argjson temp "$TEMPERATURE" \
  --argjson maxtok "$MAX_TOKENS" \
  '{model:$model, stream:false, temperature:$temp, max_tokens:$maxtok,
    messages:[{role:"system",content:$sys},{role:"user",content:$user}]}')"

URL="$SCHEME://$HOST:$PORT/v1/chat/completions"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
employee : $EMPLOYEE ($EMPLOYEE_NAME — ${EMPLOYEE_ROLE:-unspecified role})
model    : $USE_MODEL$( [ "$ESCALATE" -eq 1 ] && echo "  [ESCALATED / cloud]" )
endpoint : $URL
persona  : $PERSONA_FILE
timeout  : ${TIMEOUT}s   strip_think=$STRIP_THINK
--- payload ---
EOF
  printf '%s\n' "$PAYLOAD" | jq .
  exit 0
fi

# --- call -------------------------------------------------------------------
declare -a AUTH=()
[ -n "${OLLAMA_API_KEY:-}" ] && AUTH=(-H "Authorization: Bearer $OLLAMA_API_KEY")

RESP="$(curl -sS -m "$TIMEOUT" "${AUTH[@]+"${AUTH[@]}"}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" "$URL")" \
  || die "request to $URL failed — is Ollama serving there? (try: OLLAMA_HOST=0.0.0.0:$PORT ollama serve on $HOST)"

ERR="$(printf '%s' "$RESP" | jq -r '.error // empty' 2>/dev/null || true)"
[ -z "$ERR" ] || die "model/endpoint error: $ERR"

if [ "$RAW" -eq 1 ]; then
  printf '%s\n' "$RESP"
  exit 0
fi

CONTENT="$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty')"
[ -n "$CONTENT" ] || die "no content in response (use --raw to inspect): $(printf '%s' "$RESP" | head -c 400)"

# Qwen3 "thinking" models wrap reasoning in <think>...</think>; strip it for gofer output.
if [ "$STRIP_THINK" -eq 1 ]; then
  printf '%s' "$CONTENT" | python3 -c 'import sys,re; sys.stdout.write(re.sub(r"<think>.*?</think>\s*","",sys.stdin.read(),flags=re.S).lstrip())'
  echo
else
  printf '%s\n' "$CONTENT"
fi
