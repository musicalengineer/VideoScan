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
# STATE is overridable so a test harness can point it somewhere disposable
# without repurposing HOME (codex #1160). Production is unchanged.
STATE=${REVIEW_STATE:-$HOME/Library/Logs/VideoScan/model-review}
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
#
# Re-checked 2026-09-12 when the Hallie replay moved to the M4's own ollama
# (127.0.0.1, GH #181): the M4 lists qwen3.6:27b-mlx, qwen3.8:27b-mlx and
# qwen3.6:35b-a3b-nvfp4 — no code model — so the reviewer STAYS on ricksm5.
# What changed is what happens when ricksm5 is asleep (see the preflight
# below): one line, not forty urlopen errors.
REVIEW_MODEL=${REVIEW_MODEL:-qwen2.5-coder:32b}
ENDPOINT=${ENDPOINT:-http://ricksm5.local:11434}
# Seconds to wait before the one preflight retry. Long enough for a host
# that is merely slow to answer /api/tags; the tests set it to 1.
REVIEW_PREFLIGHT_RETRY_SECONDS=${REVIEW_PREFLIGHT_RETRY_SECONDS:-90}
# ONE INTERPRETER FOR THE PREFLIGHT AND THE REVIEWS (2026-09-25).
# Under launchd, PATH resolves python3 to Homebrew's ad-hoc-signed python.
# After the macOS 26.7 update (9/22) that binary got "[Errno 65] No route to
# host" to every LAN address (Local Network privacy) while curl, Apple-signed
# and exempt, did not. The curl preflight passed and all 152 commits ERRORed.
# The preflight now asks with this interpreter and urllib, exactly as
# review_real_commits.py will. Overridable for a one-off run.
PYTHON=${REVIEW_PYTHON:-python3}
PYTHON_BIN=$(command -v "$PYTHON" 2>/dev/null || print -r -- "$PYTHON")
# tools/team-channel.py refuses a post over these (MAX_SUBJECT / MAX_BODY).
# On 2026-09-25 a subject naming 46 abandoned SHAs was refused, so the digest
# never arrived. test_nightly_review.sh reads the real values from the channel's
# source and checks every post against them, so these cannot drift silently.
CHANNEL_MAX_SUBJECT=160
CHANNEL_MAX_BODY=20000
mkdir -p "$STATE"

# Post to the team channel, never over its limits. The subject is clipped (a
# refused post is worse than a clipped one); the body is cut with a pointer
# to the file that holds the whole of it.
#   post_channel <subject> <body-file> [<full-text-path-for-the-note>]
post_channel() {
  local subject=$1 body_file=$2 full=${3:-$2} body note
  (( ${#subject} > CHANNEL_MAX_SUBJECT )) && subject="${subject[1,$((CHANNEL_MAX_SUBJECT - 1))]}…"
  body=$(<"$body_file")
  if (( ${#body} > CHANNEL_MAX_BODY )); then
    note=$'\n\n[truncated for the channel — the full text is '"$full"']'
    body="${body[1,$((CHANNEL_MAX_BODY - ${#note} - 1))]}$note"
  fi
  print -r -- "$body" | "$PYTHON" tools/team-channel.py post --from reviewer --to claude \
    --subject "$subject" --body - >> "$STATE/nightly.log" 2>&1
}
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
    "$PYTHON" tools/team-channel.py post --from reviewer --to claude \
      --subject "nightly review: $noop quiet nights — is main moving?" \
      --body "The nightly reviewer has found nothing to review for $noop consecutive nights (range $range, head $head).

That is either a genuinely quiet period or the reviewer is watching the wrong thing. It follows LOCAL main; if commits are landing on a branch that never merges to main, they are not being reviewed. Worth one look before assuming all is well." \
      >> "$STATE/nightly.log" 2>&1
  fi
  exit 0
fi
echo 0 > "$quiet_file"

# THE HOST MUST BE AWAKE BEFORE ANY COMMIT IS ASKED ABOUT (2026-09-12).
#
# Night of 09/11->12: ricksm5 was asleep at 04:30. Every one of 40 commits
# went to a dead endpoint; 10 sat at the 600 s ceiling and were logged as
# "timed out", the rest as urlopen errors, and the digest still read like a
# review. The commits went to the retry queue, but the night's reviewing was
# gone and the reason was buried in 40 verdict files.
#
# So: ask /api/tags once; if silent, wait REVIEW_PREFLIGHT_RETRY_SECONDS and
# ask again. Still silent -> say "asleep" in ONE line (nightly.log + the
# channel), advance NOTHING (last_sha and the retry queue are untouched, so
# the next run picks up the same range) and exit 1. A host that answers but
# lacks REVIEW_MODEL fails the same way with its own reason.
#
# No wake attempt: this repo's tooling has no wakeonlan and no ssh wake for
# ricksm5, and adding one would be a new network dependency in a 04:30 job.
# If the M5 keeps sleeping through 04:30, that is a pmset/schedule question
# for Rick, not a retry loop here.
#
# THE PREFLIGHT ASKS THE WAY THE REVIEWS WILL (2026-09-25): same $PYTHON,
# same urllib, same $ENDPOINT. It used to be curl, which macOS exempts from
# Local Network privacy, so a python that could not reach ricksm5 passed the
# preflight and every commit ERRORed. On success it prints the model names
# (exit 0; an empty list is a reachable host with no models); on failure it
# prints the error (exit 1).
tags_of() {
  "$PYTHON" - "$ENDPOINT" 2>&1 <<'PY'
import json, sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1].rstrip("/") + "/api/tags", timeout=15) as r:
        print("\n".join(m["name"] for m in json.load(r).get("models", [])))
except Exception as exc:  # noqa: BLE001 - the reason is the output
    print(str(exc) or type(exc).__name__)
    sys.exit(1)
PY
}
tags=$(tags_of); tags_rc=$?
if [[ $tags_rc -ne 0 ]]; then
  sleep "$REVIEW_PREFLIGHT_RETRY_SECONDS"
  tags=$(tags_of); tags_rc=$?
fi
skip_reason=""; skip_short=""; skip_advice=""
if [[ $tags_rc -ne 0 ]]; then
  py_err=$(print -r -- "$tags" | tail -1)
  # Is it the host or the interpreter? curl is Apple-signed and exempt from
  # Local Network privacy, so "curl can, python can't" means the host is up
  # and this python is blocked. Diagnosis only — curl never stands in for
  # the reviewer's own path again.
  if curl -sf -o /dev/null --max-time 15 "$ENDPOINT/api/tags" 2>/dev/null; then
    skip_short="python cannot reach $ENDPOINT (curl can)"
    skip_reason="python ($PYTHON_BIN) cannot reach $ENDPOINT: $py_err — but curl CAN reach it, so the host is up and this interpreter is blocked"
    skip_advice="The host answers curl but not $PYTHON_BIN, which is what reviews with. On macOS this is Local Network privacy: a launchd-run Homebrew/venv python loses LAN access (typically after an OS update or a brew upgrade of python) while Apple-signed curl is exempt. Only Rick can grant it, in the GUI on this Mac: System Settings > Privacy & Security > Local Network, turn on the entry for this python (it may be listed as 'Python' or 'python3.x'). If there is no entry, macOS never asked and there is nothing to toggle; the alternative is REVIEW_PYTHON=/usr/bin/python3 (Apple-signed, exempt, like curl), which is Rick's call. Until then every run skips here, loudly, with the baseline kept."
  else
    skip_short="host $ENDPOINT asleep or unreachable"
    skip_reason="host $ENDPOINT asleep or unreachable: /api/tags did not answer twice (retry after ${REVIEW_PREFLIGHT_RETRY_SECONDS}s); python: $py_err"
    skip_advice="If ricksm5 keeps sleeping through 04:30 the fix is its sleep schedule, not this script."
  fi
elif ! print -r -- "$tags" | grep -qx "$REVIEW_MODEL"; then
  skip_short="host $ENDPOINT lacks $REVIEW_MODEL"
  skip_reason="host $ENDPOINT is up but does not list $REVIEW_MODEL (has: $(print -r -- "$tags" | tr '\n' ' '))"
  skip_advice="Pull $REVIEW_MODEL on that host, or set REVIEW_MODEL to one it has."
fi
if [[ -n $skip_reason ]]; then
  pending=$(( count + $(print -r -- "$retry" | tr ',' '\n' | grep -c .) ))
  echo "$stamp SKIPPED — $skip_reason; $pending commit(s) ($range${retry:+ + retry queue}) not reviewed, baseline kept" >> "$STATE/nightly.log"
  skip_body="$STATE/$stamp.skipped.md"
  {
    echo "Nothing was reviewed tonight. $pending commit(s) in $range${retry:+ plus the retry queue} are still pending; the baseline was not advanced, so the next run reviews them."
    echo
    echo "Reason: $skip_reason"
    echo
    echo "$skip_advice"
  } > "$skip_body"
  post_channel "nightly review: SKIPPED — $skip_short" "$skip_body"
  exit 1
fi

# UNIQUE PER RUN, not per minute (codex #1160). The stamp is
# YYYYMMDD-HHMM and review_real_commits.py does mkdir(exist_ok=True), so two
# runs inside the same minute — a clean retry straight after an ERROR, which
# is now the normal thing to do — shared one directory. The flagged/errors
# greps below count *.md across it, so the second run inherited the first
# run's stale ERROR and FLAGGED verdicts. My own harness masked this by
# running several times a minute and never checking the counts afterwards.
out="$STATE/$stamp"
[[ -e $out ]] && out="$STATE/$stamp-$$"
[[ -n $retry ]] && echo "$stamp retrying $(echo "$retry" | tr ',' '\n' | grep -c .) previously-unreviewed commit(s): $retry" >> "$STATE/nightly.log"
# An ARRAY, not `${retry:+--also-commits "$retry"}`: zsh does not word-split
# parameter expansions, so that form passed argparse ONE argument
# ("--also-commits abc12345") and the retry queue was silently never handed
# over. Caught by test_nightly_review.sh case 3.
retry_args=()
[[ -n $retry ]] && retry_args=(--also-commits "$retry")
"$PYTHON" tools/model-fitness/review_real_commits.py \
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
# THE UNITS ACTUALLY REVIEWED, not the range size (codex #1160). A retry-only
# run has count=0 while reviewing carried-forward commits, so `count - flagged
# - errors` went NEGATIVE the moment one of them was flagged. The python
# prints the real figure.
# Counted from the per-commit verdict files, which are ground truth for what
# was actually reviewed. Parsing the summary's "units" line would reintroduce
# the same failure in a new place: when the parse misses, $count is wrong for
# exactly the retry-only run that made quiet go negative.
reviewed=$(ls "$out"/*.md 2>/dev/null | wc -l | tr -d ' ')
[[ -n $reviewed ]] || reviewed=0

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
  echo "Nightly local-model review ($model) of $reviewed commit(s), $range"
  echo "quiet $((reviewed - flagged - errors)) / flagged $flagged / errors $errors  (exit $rc)"
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
echo "$stamp reviewed $reviewed ($range): flagged $flagged errors $errors${abandoned:+ abandoned$abandoned}" >> "$STATE/nightly.log"

# COUNTS IN THE SUBJECT, SHAS IN THE BODY (2026-09-25). The subject used to
# end ", abandoned <every sha>"; the 09/25 run abandoned 46 and the channel
# refused the post (MAX_SUBJECT 160), so no digest arrived. The digest body
# already lists every abandoned SHA under "ABANDONED after N attempts".
subject="nightly review: $reviewed commits, $flagged flagged"
[[ $errors -gt 0 ]] && subject="$subject, $errors UNREVIEWED"
abandoned_n=${#${(z)abandoned}}
[[ $abandoned_n -gt 0 ]] && subject="$subject, $abandoned_n abandoned"
post_channel "$subject" "$out.digest.md"
