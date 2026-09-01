#!/bin/zsh
# Overnight model bake-off for VideoScan's actual needs (Rick, 2026-08-31).
#
# Two models, two harnesses, one variable changed:
#
#   BASELINE  qwen3.6:35b-a3b-nvfp4   35B total /  3B active  (MoE, installed)
#   CANDIDATE qwen3.8:27b-mlx         27B total / 27B active  (dense, 2026-08-13)
#
#   fitness corpus  code review (recall AND precision), US/EU history,
#                   abstention, domain knowledge, NL->AST
#   qwen-bench      the existing 44-case tool-planning corpus, so the number
#                   is directly comparable to the 82.6% recorded on 2026-08-27
#
# Everything is deterministic (temperature 0, pinned seed) and every raw
# response is kept, so any verdict can be re-scored by hand.
set -u

REPO=${REPO:-$HOME/dev/VideoScan}
HOST=${HOST:-http://localhost:11434}
SEED=${SEED:-101}
BASELINE=${BASELINE:-qwen3.6:35b-a3b-nvfp4}
CANDIDATE=${CANDIDATE:-qwen3.8:27b-mlx}

STAMP=$(date +%Y%m%d-%H%M)
OUT=$HOME/Library/Logs/VideoScan/model-fitness-$STAMP
mkdir -p "$OUT"
LOG=$OUT/run.log

say() { print -r -- "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

say "=== overnight model fitness ==="
say "baseline  $BASELINE"
say "candidate $CANDIDATE"
say "host      $HOST"
say "output    $OUT"

# Only run models that are actually present; a typo'd tag must not look like
# a model that failed the eval.
for m in "$BASELINE" "$CANDIDATE"; do
  if ! ollama list | awk '{print $1}' | grep -qx "$m"; then
    say "FATAL: model not installed: $m   (ollama pull $m)"
    exit 2
  fi
done

say ""
say "--- 1/4 fitness corpus: baseline ---"
python3 "$REPO/tools/model-fitness/run_fitness.py" run \
  --model "$BASELINE" --host "$HOST" --seed "$SEED" \
  --out "$OUT/fitness-baseline.jsonl" >>"$LOG" 2>&1
say "exit=$?"

say ""
say "--- 2/4 fitness corpus: candidate ---"
python3 "$REPO/tools/model-fitness/run_fitness.py" run \
  --model "$CANDIDATE" --host "$HOST" --seed "$SEED" \
  --out "$OUT/fitness-candidate.jsonl" >>"$LOG" 2>&1
say "exit=$?"

say ""
say "--- 3/4 qwen-bench tool planning: baseline ---"
python3 "$REPO/tools/qwen-bench/qwen_bench.py" run \
  --transport native-tools --host "$HOST" --model "$BASELINE" \
  --seed "$SEED" --samples 1 \
  --out "$OUT/qwenbench-baseline.jsonl" >>"$LOG" 2>&1
say "exit=$?"

say ""
say "--- 4/4 qwen-bench tool planning: candidate ---"
python3 "$REPO/tools/qwen-bench/qwen_bench.py" run \
  --transport native-tools --host "$HOST" --model "$CANDIDATE" \
  --seed "$SEED" --samples 1 \
  --out "$OUT/qwenbench-candidate.jsonl" >>"$LOG" 2>&1
say "exit=$?"

say ""
say "=== HEAD TO HEAD ==="
python3 "$REPO/tools/model-fitness/run_fitness.py" compare \
  "$OUT/fitness-baseline.jsonl" "$OUT/fitness-candidate.jsonl" \
  2>&1 | tee -a "$LOG" | tee "$OUT/summary.txt"

say ""
say "done. raw responses in $OUT"
