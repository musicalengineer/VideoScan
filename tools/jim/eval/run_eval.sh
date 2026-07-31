#!/usr/bin/env bash
# run_eval.sh — run eval/tasks.jsonl through an employee and save outputs for grading.
#
#   tools/jim/eval/run_eval.sh [employee] [--escalate]
#
# Default employee: jim. Outputs land in eval/out/<employee>/<id>.txt (task + expect + answer).
# Grade the folder against eval/rubric.md (by eye, or hand it to Claude).
set -euo pipefail

EVAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$EVAL_DIR")"
EMPLOYEE="jim"
ESC=()
for a in "$@"; do
  case "$a" in
    --escalate) ESC=(--escalate) ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) EMPLOYEE="$a" ;;
  esac
done

TASKS="$EVAL_DIR/tasks.jsonl"
OUT="$EVAL_DIR/out/$EMPLOYEE"
mkdir -p "$OUT"
[ -f "$TASKS" ] || { echo "missing $TASKS" >&2; exit 1; }

echo "Auditioning '$EMPLOYEE'${ESC:+ (escalated)} on $(grep -c . "$TASKS") tasks -> $OUT"
n=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id="$(printf '%s' "$line"     | jq -r '.id')"
  prompt="$(printf '%s' "$line" | jq -r '.prompt')"
  expect="$(printf '%s' "$line" | jq -r '.expect')"
  n=$((n+1))
  printf '  [%2d] %-16s ... ' "$n" "$id"
  answer="$("$ROOT/bin/$EMPLOYEE" "${ESC[@]}" "$prompt" 2>&1 || echo '(delegate error — see output file)')"
  {
    echo "### TASK $id"
    echo "$prompt"
    echo
    echo "### EXPECT"
    echo "$expect"
    echo
    echo "### $EMPLOYEE ANSWER"
    echo "$answer"
  } > "$OUT/$id.txt"
  echo "done"
done < "$TASKS"

echo "Saved $n outputs to $OUT"
echo "Now grade against $ROOT/eval/rubric.md (traps 10 & 11 are the hiring gate)."
