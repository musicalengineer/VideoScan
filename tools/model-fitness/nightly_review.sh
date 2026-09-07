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
# THE REVIEWER'S OWN MODEL AND HOST (2026-09-06).
#
# This script used to pass no --model, so review_real_commits.py fell back
# to configured_model(), which reads `defaults read Rick-Breen.VideoScan
# archivist.ollamaModel` — HALLIE's setting. Changing the brain in the app's
# Settings pane therefore silently changed the nightly code reviewer too,
# and on 2026-09-06 Rick did exactly that while exploring the picker.
# (codex #1147/#1148: installed != approved, and Hallie's role is not the
# developer's role.)
#
# The reviewer is a CODE model and Hallie is a family archivist; they have
# no reason to be the same tag, and every reason not to be. Both are
# overridable from the environment for a one-off run.
#
# Host: ricksm5 rather than the M4, because Rick's M4 holds Hallie's brain
# and a 20 GB reviewer beside a 21 GB archivist on a 64 GB machine is a
# memory fight nobody asked for. ricksm5 has 48 GB and already has this
# model installed.
REVIEW_MODEL=${REVIEW_MODEL:-qwen2.5-coder:32b}
ENDPOINT=${ENDPOINT:-http://ricksm5.local:11434}
mkdir -p "$STATE"
cd "$REPO" || exit 1

# THE REVIEWER FOLLOWS LOCAL `main`, NOT `origin/main` (2026-09-07).
#
# It used to read origin/main. Rick's practice is to leave main unpushed until
# he has spot-tested it, so from 2026-09-04 to 2026-09-07 origin/main sat at
# b31a2b59 while 33 commits — the entire Hallie run — landed locally. Both the
# 09/06 and 09/07 runs logged "nothing new" and reviewed NONE of it. The
# reviewer was reporting on the publishing schedule, not the work.
#
# Local main is where the work lands, so that is what gets reviewed. `main`
# rather than HEAD on purpose: this may run while a feature branch or a
# worktree is checked out, and the nightly's subject is main.
git fetch --quiet origin main 2>>"$STATE/nightly.log" || true
head=$(git rev-parse main 2>/dev/null || git rev-parse HEAD)
last=$(cat "$STATE/last_sha" 2>/dev/null || echo "")
retry_file="$STATE/unreviewed_shas"
quiet_file="$STATE/consecutive_noop"
if [[ -n ${RANGE:-} ]]; then
  range=$RANGE
elif [[ -n $last ]] && git merge-base --is-ancestor "$last" "$head" 2>/dev/null; then
  range="$last..$head"
elif git rev-parse -q --verify "$head~10" >/dev/null 2>&1; then
  range="$head~10..$head"
else
  # A young repo (or a fresh checkout with no baseline): $head~10 does not
  # resolve, git rev-list errors, count falls to 0 and the reviewer reports
  # "nothing new" for a repo it has never looked at. Review all of it.
  range="$head"
fi
count=$(git rev-list --no-merges --count "$range" 2>/dev/null || echo 0)
stamp=$(date +%Y%m%d-%H%M)
# Carried-forward commits an earlier run errored on are reviewable work even
# when the range itself is empty.
retry=$(cat "$retry_file" 2>/dev/null | tr -d ' \n')
if [[ $count -eq 0 && -z $retry ]]; then
  # A SECOND quiet night in a row is not routine — the first time this
  # happened (2026-09-06/07) it meant the reviewer had gone blind on a ref it
  # should not have been following, and it said so in one line nobody reads.
  # Silence that repeats gets escalated to the channel.
  noop=$(( $(cat "$quiet_file" 2>/dev/null || echo 0) + 1 ))
  echo "$noop" > "$quiet_file"
  echo "$stamp nothing new ($range) — $noop consecutive" >> "$STATE/nightly.log"
  echo "$head" > "$STATE/last_sha"
  if [[ $noop -ge 2 ]]; then
    python3 tools/team-channel.py post --from reviewer --to claude \
      --subject "nightly review: $noop quiet nights — is main moving?" \
      --body "The nightly reviewer has found nothing to review for $noop consecutive nights (range $range, head $head).

That is either a genuinely quiet period or the reviewer is watching the wrong thing. It follows LOCAL main; if commits are landing on a branch that never merges to main, they are not being reviewed. Worth one look before assuming all is well." \
      >> "$STATE/nightly.log" 2>&1
  fi
  exit 0
fi
echo 0 > "$quiet_file"

out="$STATE/$stamp"
[[ -n $retry ]] && echo "$stamp retrying $(echo "$retry" | tr ',' '\n' | grep -c .) previously-unreviewed commit(s): $retry" >> "$STATE/nightly.log"
# An ARRAY, not `${retry:+--also-commits "$retry"}`: zsh does not word-split
# parameter expansions, so that form passed argparse ONE argument
# ("--also-commits abc12345") and the retry queue was silently never handed
# over. Caught by test_nightly_review.sh case 3.
retry_args=()
[[ -n $retry ]] && retry_args=(--also-commits "$retry")
python3 tools/model-fitness/review_real_commits.py \
  --range "$range" --endpoint "$ENDPOINT" --model "$REVIEW_MODEL" --out "$out" \
  "${retry_args[@]}" \
  > "$out.summary.txt" 2>&1
rc=$?
# Advance the baseline only when the review actually ran: a transient
# failure (ollama down at 04:30) must not skip these commits forever
# (nightly reviewer finding, 2026-09-02).
if [[ $rc -eq 0 ]]; then echo "$head" > "$STATE/last_sha"; fi

flagged=$(grep -l '^- verdict: FLAGGED' "$out"/*.md 2>/dev/null | wc -l | tr -d ' ')
errors=$(grep -l '^- verdict: ERROR' "$out"/*.md 2>/dev/null | wc -l | tr -d ' ')
model=$(grep -m1 '^model' "$out.summary.txt" | awk '{print $2}')

# AN ERRORED COMMIT WAS NEVER REVIEWED (2026-09-07). Every ERROR is the 600s
# ceiling or a dead endpoint; the commit's diff was never read by anything.
# The baseline still advanced past it, so it was never looked at again — 19 of
# 122 commits over the first five nights, 11 of them on one night, all silent.
# They are queued here and retried next run. An attempt counter drops a commit
# that fails MAX_RETRIES times, so one pathological diff cannot stall the
# queue forever; it is reported as abandoned when that happens.
MAX_RETRIES=${MAX_RETRIES:-3}
errored=$(sed -n 's/^ERRORED_SHAS: //p' "$out.summary.txt" | tail -1 | tr -d ' ')
abandoned=""
if [[ $rc -eq 0 ]]; then
  next="" 
  for sha in ${(s:,:)errored}; do
    [[ -z $sha ]] && continue
    tries=$(sed -n "s/^$sha //p" "$STATE/retry_attempts" 2>/dev/null | tail -1)
    tries=$(( ${tries:-0} + 1 ))
    if [[ $tries -ge $MAX_RETRIES ]]; then
      abandoned="$abandoned $sha"
      grep -v "^$sha " "$STATE/retry_attempts" 2>/dev/null > "$STATE/retry_attempts.tmp" || true
      mv -f "$STATE/retry_attempts.tmp" "$STATE/retry_attempts" 2>/dev/null || true
    else
      next="${next:+$next,}$sha"
      grep -v "^$sha " "$STATE/retry_attempts" 2>/dev/null > "$STATE/retry_attempts.tmp" || true
      mv -f "$STATE/retry_attempts.tmp" "$STATE/retry_attempts" 2>/dev/null || true
      echo "$sha $tries" >> "$STATE/retry_attempts"
    fi
  done
  echo "$next" > "$retry_file"
fi
{
  echo "Nightly local-model review ($model) of $count commit(s), $range"
  echo "quiet $((count - flagged - errors)) / flagged $flagged / errors $errors  (exit $rc)"
  echo "raw verdicts: $out"
  # UNREVIEWED IS NOT REVIEWED-AND-CLEAN. Before 2026-09-07 an error was a
  # number in this header and nothing else, so a night where 11 of 71 commits
  # were never read looked much like a quiet one.
  if [[ $errors -gt 0 ]]; then
    echo
    echo "NOT REVIEWED — $errors of $count timed out or lost the endpoint."
    echo "These were never read by anything. Queued for retry next run:"
    sed -n '/^  UNREVIEWED (retried next run):/,/^$/p' "$out.summary.txt" | sed '1d'
  fi
  if [[ -n ${abandoned// /} ]]; then
    echo
    echo "ABANDONED after $MAX_RETRIES attempts — these commits have never been"
    echo "reviewed and no longer will be. Read them yourself:$abandoned"
  fi
  if [[ $flagged -gt 0 ]]; then
    echo
    echo "FLAGGED — read each before believing it (count bias: what it misses means nothing):"
    for f in $(grep -l '^- verdict: FLAGGED' "$out"/*.md); do
      echo "-- $(head -1 "$f" | sed 's/^# //')"
      sed -n '/^---$/,$p' "$f" | sed '1d' | head -25
    done
  fi
} > "$out.digest.md"
echo "$stamp reviewed $count ($range): flagged $flagged errors $errors${abandoned:+ abandoned$abandoned}" >> "$STATE/nightly.log"

subject="nightly review: $count commits, $flagged flagged"
[[ $errors -gt 0 ]] && subject="$subject, $errors UNREVIEWED"
[[ -n ${abandoned// /} ]] && subject="$subject, abandoned$abandoned"
python3 tools/team-channel.py post --from reviewer --to claude \
  --subject "$subject" \
  --body - < "$out.digest.md" >> "$STATE/nightly.log" 2>&1
