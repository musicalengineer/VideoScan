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
# Three models, chosen so the result is INTERPRETABLE rather than merely
# favourable. Baseline vs 3.6-dense isolates architecture (3B active -> 27B
# active at the same generation); 3.6-dense vs 3.8-dense isolates the
# generation (identical shape, ten months of post-training apart). Without
# the middle model a win is real but unattributable.
MODELS=(${MODELS:-qwen3.6:35b-a3b-nvfp4 qwen3.6:27b-mlx qwen3.8:27b-mlx})
BASELINE=${MODELS[1]}
CANDIDATE=${MODELS[-1]}

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
for m in $MODELS; do
  if ! ollama list | awk '{print $1}' | grep -qx "$m"; then
    say "FATAL: model not installed: $m   (ollama pull $m)"
    exit 2
  fi
done

RUNS=()
for m in $MODELS; do
  slug=${m//[:\/]/_}
  say ""
  say "--- fitness corpus: $m ---"
  python3 "$REPO/tools/model-fitness/run_fitness.py" run \
    --model "$m" --host "$HOST" --seed "$SEED" \
    --out "$OUT/fitness-$slug.jsonl" >>"$LOG" 2>&1
  say "exit=$?"
  RUNS+=("$OUT/fitness-$slug.jsonl")
done

for m in $MODELS; do
  slug=${m//[:\/]/_}
  say ""
  say "--- qwen-bench tool planning: $m ---"
  python3 "$REPO/tools/qwen-bench/qwen_bench.py" run \
    --transport native-tools --host "$HOST" --model "$m" \
    --seed "$SEED" --samples 1 \
    --out "$OUT/qwenbench-$slug.jsonl" >>"$LOG" 2>&1
  say "exit=$?"
done

say ""
say "=== HEAD TO HEAD ==="
python3 "$REPO/tools/model-fitness/run_fitness.py" compare \
  "${RUNS[@]}" 2>&1 | tee -a "$LOG" | tee "$OUT/summary.txt"

say ""
say "done. raw responses in $OUT"
