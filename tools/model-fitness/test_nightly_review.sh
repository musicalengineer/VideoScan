#!/usr/bin/env bash
# test_nightly_review.sh — pin the nightly reviewer's three silent-failure
# modes, all of which it exhibited in production before 2026-09-07:
#
#   1. it followed origin/main, so 33 commits sitting on an unpushed local
#      main were never reviewed and it logged "nothing new" twice;
#   2. a commit whose review ERRORED (600s ceiling, dead endpoint) advanced
#      the baseline anyway and was never looked at again — 19 of the first
#      122 commits;
#   3. both of the above reported in one quiet log line nobody reads.
#
# Runs entirely in a sandbox: a throwaway repo, a stub reviewer, a stub team
# channel, and HOME pointed at the sandbox so STATE lands there.
#
# Usage:  tools/model-fitness/test_nightly_review.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR/nightly_review.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/nightly-review-test-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

FAILS=0; PASSES=0
pass() { PASSES=$((PASSES+1)); echo "  PASS: $*"; }
fail() { FAILS=$((FAILS+1));  echo "  FAIL: $*"; }

WORK="$SANDBOX/work"; ORIGIN="$SANDBOX/origin.git"
# STATE via the script's own REVIEW_STATE override rather than repurposing
# HOME (codex #1160), so this harness can be run by anyone whose execution
# rules forbid that.
STATE="$SANDBOX/state"
mkdir -p "$WORK/tools/model-fitness" "$STATE"
git init --quiet --bare "$ORIGIN"
git init --quiet "$WORK"
git -C "$WORK" config user.email t@t; git -C "$WORK" config user.name T
git -C "$WORK" remote add origin "$ORIGIN"
echo one > "$WORK/a.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "first"
git -C "$WORK" branch -M main; git -C "$WORK" push -q origin main

# Stub reviewer: emits the real script's contract — a summary with a
# model line and an ERRORED_SHAS line. STUB_ERRORS names what "timed out".
cat > "$WORK/tools/model-fitness/review_real_commits.py" <<'STUB'
import os, sys, re, pathlib
out = sys.argv[sys.argv.index("--out") + 1]
also = sys.argv[sys.argv.index("--also-commits") + 1] if "--also-commits" in sys.argv else ""
pathlib.Path(out).mkdir(parents=True, exist_ok=True)
errs = [e for e in os.environ.get("STUB_ERRORS", "").split(",") if e]
print("model    stub-model")
print(f"units    {1 + len(errs)}")
pathlib.Path(out, "01-aaaaaaaa.md").write_text("# aaaaaaaa x\n\n- verdict: quiet\n\n---\n\nfine\n")
for i, e in enumerate(errs):
    pathlib.Path(out, f"{i+2:02d}-{e}.md").write_text(f"# {e} x\n\n- verdict: ERROR\n\n---\n\ntimeout\n")
print("  UNREVIEWED (retried next run):" if errs else "")
for e in errs:
    print(f"    {e}  subject  — timed out")
print("ERRORED_SHAS: " + ",".join(errs))
pathlib.Path(out + ".alsocommits").write_text(also)
STUB

# Stub channel: append every post so the harness can assert on escalation.
cat > "$WORK/tools/team-channel.py" <<'STUB'
import sys, os, pathlib
subject = sys.argv[sys.argv.index("--subject") + 1] if "--subject" in sys.argv else ""
body = sys.stdin.read() if "-" in sys.argv else ""
with open(os.environ["POSTS_FILE"], "a") as fh:
    fh.write("SUBJECT: " + subject + "\n" + body + "\n===\n")
STUB
POSTS="$SANDBOX/posts.txt"; : > "$POSTS"

run_reviewer() {
    ( cd "$WORK"
      REVIEW_STATE="$STATE" REPO="$WORK" POSTS_FILE="$POSTS" \
      STUB_ERRORS="${1:-}" MAX_RETRIES="${MAX_RETRIES:-3}" \
      ENDPOINT=http://stub REVIEW_MODEL=stub-model \
      zsh "$REAL_SCRIPT" ) > "$SANDBOX/run.out" 2>&1
}

echo "== 1: local main ahead of an unpushed origin/main IS reviewed =="
# THE INCIDENT, exactly: a baseline at the last PUSHED commit, then work that
# lands on local main and is never pushed. Reading origin/main here yields
# "nothing new"; reading local main yields the one unreviewed commit.
mkdir -p "$STATE"
git -C "$WORK" rev-parse origin/main > "$STATE/last_sha"
echo two > "$WORK/b.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "unpushed work"
run_reviewer ""
if grep -q "reviewed 1 " "$STATE/nightly.log" 2>/dev/null; then
    pass "the 2026-09-07 blindness is closed — unpushed local main is reviewed"
else
    fail "unpushed commit was not reviewed: $(cat "$STATE/nightly.log" 2>/dev/null | tr '\n' ' ')"
fi

echo "== 2: a quiet night is quiet ONCE, then escalates =="
run_reviewer ""
if [ "$(grep -c 'SUBJECT:' "$POSTS")" -eq 1 ]; then
    pass "first quiet night posts nothing new to the channel"
else
    fail "first quiet night should not escalate (posts=$(grep -c 'SUBJECT:' "$POSTS"))"
fi
run_reviewer ""
if grep -q "SUBJECT: nightly review: 2 quiet nights" "$POSTS"; then
    pass "a SECOND consecutive quiet night escalates to the channel"
else
    fail "two quiet nights did not escalate: $(grep 'SUBJECT:' "$POSTS" | tr '\n' '|')"
fi

echo "== 3: an ERRORED commit is retried, not skipped forever =="
echo three > "$WORK/c.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "errors here"
ERRSHA=$(git -C "$WORK" rev-parse --short=8 HEAD)
run_reviewer "$ERRSHA"
if [ "$(cat "$STATE/unreviewed_shas" 2>/dev/null)" = "$ERRSHA" ]; then
    pass "the unreviewed commit is queued for retry"
else
    fail "errored commit was not queued: '$(cat "$STATE/unreviewed_shas" 2>/dev/null)'"
fi
if grep -q "SUBJECT:.*1 UNREVIEWED" "$POSTS"; then
    pass "the channel subject says UNREVIEWED out loud"
else
    fail "unreviewed count never reached the subject line"
fi
run_reviewer ""
if grep -q "$ERRSHA" "$(ls -td "$STATE"/2*/ | head -1)".alsocommits 2>/dev/null \
   || grep -rq "$ERRSHA" "$STATE"/*.alsocommits 2>/dev/null; then
    pass "the next run actually passes it back via --also-commits"
else
    fail "retry queue was not handed to the reviewer"
fi

echo "== 4: a permanently-failing commit is abandoned, loudly, not looped =="
: > "$POSTS"
echo four > "$WORK/d.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "always errors"
BADSHA=$(git -C "$WORK" rev-parse --short=8 HEAD)
MAX_RETRIES=2 run_reviewer "$BADSHA"
MAX_RETRIES=2 run_reviewer "$BADSHA"
if grep -q "SUBJECT:.*abandoned" "$POSTS"; then
    pass "abandonment after MAX_RETRIES is announced, never silent"
else
    fail "a permanently-failing commit vanished quietly: $(grep 'SUBJECT:' "$POSTS" | tr '\n' '|')"
fi

echo "== 5: a clean retry in the SAME MINUTE does not inherit stale verdicts =="
# codex #1160. stamp is YYYYMMDD-HHMM and the python mkdirs exist_ok, so two
# runs inside one minute shared an output directory and the flagged/errors
# greps counted the FIRST run's .md files. A clean retry straight after an
# ERROR is exactly when that happens.
: > "$POSTS"
echo five > "$WORK/e.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "errors then clean"
ESHA=$(git -C "$WORK" rev-parse --short=8 HEAD)
run_reviewer "$ESHA"                      # run A: one ERROR
run_reviewer ""                           # run B: same minute, all clean
LAST_SUBJECT=$(grep 'SUBJECT:' "$POSTS" | tail -1)
if echo "$LAST_SUBJECT" | grep -q "UNREVIEWED"; then
    fail "the clean retry inherited the previous run's ERROR: $LAST_SUBJECT"
else
    pass "the clean retry gets its own output directory and its own counts"
fi

echo "== 6: a retry-only run reports what it reviewed, never a negative =="
# codex #1160: `quiet = count - flagged - errors` with count=0 on a
# retry-only run went negative as soon as a carried-forward commit errored.
if grep -hoE 'quiet -[0-9]+' "$STATE"/*.digest.md 2>/dev/null | head -1 | grep -q .; then
    fail "a digest reported a negative quiet count"
else
    pass "no digest reports a negative quiet count"
fi

echo
echo "════════════════════════════════════════════════"
echo "Tests passed: $PASSES"
echo "Tests failed: $FAILS"
echo "════════════════════════════════════════════════"
[ "$FAILS" -eq 0 ]
