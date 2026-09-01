#!/bin/zsh
# Independent nightly code review by the local model (Rick, 2026-09-01).
#
# codex is out of tokens until 2026-09-07, so the local brain stands in as
# the reviewer who is not Claude. It reads every commit that landed on
# main since the last run, keeps the raw verdicts, and mails a digest to
# Claude on the team channel so the next session sees it before touching
# anything. Measured 2026-08-31: 18 quiet / 3 flagged / 2 genuine over 21
# real commits — adequate as an ADDITIVE reviewer, never a gate.
#
# Runs at 04:30 on the M4 (after the 02:00 test job has the machine).
# Idempotent: nothing new since last time -> one line and exit 0.
#
#   tools/model-fitness/nightly_review.sh            # since last run
#   RANGE=origin/main~5..origin/main tools/model-fitness/nightly_review.sh
set -u
REPO=${REPO:-$HOME/dev/VideoScan}
STATE=$HOME/Library/Logs/VideoScan/model-review
ENDPOINT=${ENDPOINT:-http://localhost:11434}
mkdir -p "$STATE"
cd "$REPO" || exit 1

git fetch --quiet origin main 2>>"$STATE/nightly.log" || true
head=$(git rev-parse origin/main 2>/dev/null || git rev-parse HEAD)
last=$(cat "$STATE/last_sha" 2>/dev/null || echo "")
if [[ -n ${RANGE:-} ]]; then
  range=$RANGE
elif [[ -n $last ]] && git merge-base --is-ancestor "$last" "$head" 2>/dev/null; then
  range="$last..$head"
else
  range="$head~10..$head"
fi
count=$(git rev-list --no-merges --count "$range" 2>/dev/null || echo 0)
stamp=$(date +%Y%m%d-%H%M)
if [[ $count -eq 0 ]]; then
  echo "$stamp nothing new ($range)" >> "$STATE/nightly.log"
  echo "$head" > "$STATE/last_sha"
  exit 0
fi

out="$STATE/$stamp"
python3 tools/model-fitness/review_real_commits.py \
  --range "$range" --endpoint "$ENDPOINT" --out "$out" \
  > "$out.summary.txt" 2>&1
rc=$?
echo "$head" > "$STATE/last_sha"

flagged=$(grep -l '^- verdict: FLAGGED' "$out"/*.md 2>/dev/null | wc -l | tr -d ' ')
errors=$(grep -l '^- verdict: ERROR' "$out"/*.md 2>/dev/null | wc -l | tr -d ' ')
model=$(grep -m1 '^model' "$out.summary.txt" | awk '{print $2}')
{
  echo "Nightly local-model review ($model) of $count commit(s), $range"
  echo "quiet $((count - flagged - errors)) / flagged $flagged / errors $errors  (exit $rc)"
  echo "raw verdicts: $out"
  if [[ $flagged -gt 0 ]]; then
    echo
    echo "FLAGGED — read each before believing it (count bias: what it misses means nothing):"
    for f in $(grep -l '^- verdict: FLAGGED' "$out"/*.md); do
      echo "-- $(head -1 "$f" | sed 's/^# //')"
      sed -n '/^---$/,$p' "$f" | sed '1d' | head -25
    done
  fi
} > "$out.digest.md"
echo "$stamp reviewed $count ($range): flagged $flagged errors $errors" >> "$STATE/nightly.log"

python3 tools/team-channel.py post --from reviewer --to claude \
  --subject "nightly review: $count commits, $flagged flagged" \
  --body - < "$out.digest.md" >> "$STATE/nightly.log" 2>&1
