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
# Plus, since 2026-09-12, the night ricksm5 slept through 04:30 and forty
# commits went to a dead endpoint (cases 7-8): the reviewer preflights
# /api/tags, retries once, and skips loudly with the baseline kept.
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

# Stub ollama: a /api/tags server listing stub-model, so the preflight sees an
# awake host that has the reviewer's model. Cases 7-8 point ENDPOINT elsewhere.
python3 - "$SANDBOX/port" > "$SANDBOX/stub-ollama.log" 2>&1 <<'STUB' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"models": [{"name": "stub-model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
STUB
STUB_PID=$!
# The `wait` swallows bash's "Terminated" notice for the reaped stub.
trap 'kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$SANDBOX/port" ] && break; sleep 0.2; done
STUB_ENDPOINT="http://127.0.0.1:$(cat "$SANDBOX/port")"

run_reviewer() {
    ( cd "$WORK"
      REVIEW_STATE="$STATE" REPO="$WORK" POSTS_FILE="$POSTS" \
      STUB_ERRORS="${1:-}" MAX_RETRIES="${MAX_RETRIES:-3}" \
      ENDPOINT="${ENDPOINT:-$STUB_ENDPOINT}" REVIEW_MODEL="${REVIEW_MODEL:-stub-model}" \
      REVIEW_PREFLIGHT_RETRY_SECONDS=1 \
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

echo "== 7: an asleep host is ONE skip line, the baseline is kept, nothing is asked per commit =="
# The 2026-09-11->12 night: ricksm5 asleep at 04:30, forty commits each
# timing out or erroring on urlopen, digest posted as if reviewed.
: > "$POSTS"
echo seven > "$WORK/g.txt"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m "lands while the M5 sleeps"
BEFORE_SHA=$(cat "$STATE/last_sha"); BEFORE_DIRS=$(ls -d "$STATE"/2*/ 2>/dev/null | wc -l | tr -d ' ')
start=$(date +%s)
ENDPOINT=http://127.0.0.1:1 run_reviewer ""; rc=$?
took=$(( $(date +%s) - start ))
AFTER_DIRS=$(ls -d "$STATE"/2*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -ne 0 ] && tail -1 "$STATE/nightly.log" | grep -q "SKIPPED — host http://127.0.0.1:1 asleep or unreachable"; then
    pass "the skip is one line in nightly.log with the host named (rc=$rc, ${took}s)"
else
    fail "no skip line (rc=$rc): $(tail -1 "$STATE/nightly.log")"
fi
if [ "$(cat "$STATE/last_sha")" = "$BEFORE_SHA" ]; then
    pass "the baseline did not advance past the unreviewed commit"
else
    fail "baseline moved while the host was asleep"
fi
if [ "$AFTER_DIRS" = "$BEFORE_DIRS" ]; then
    pass "no per-commit review was attempted against the dead endpoint"
else
    fail "a review directory was created for a dead endpoint ($BEFORE_DIRS -> $AFTER_DIRS)"
fi
if grep -q "SUBJECT: nightly review: SKIPPED — host http://127.0.0.1:1 asleep" "$POSTS"; then
    pass "the channel hears 'asleep', not a digest"
else
    fail "channel subject missing or wrong: $(grep 'SUBJECT:' "$POSTS" | tr '\n' '|')"
fi
if grep -q "1 commit(s) (.*) not reviewed, baseline kept" "$STATE/nightly.log"; then
    pass "the skip line counts what was left unreviewed"
else
    fail "skip line does not count the pending commits: $(tail -1 "$STATE/nightly.log")"
fi

echo "== 8: an awake host WITHOUT the reviewer's model also skips, with its own reason =="
: > "$POSTS"
REVIEW_MODEL=absent-model run_reviewer ""; rc=$?
if [ "$rc" -ne 0 ] && tail -1 "$STATE/nightly.log" | grep -q "SKIPPED — host $STUB_ENDPOINT is up but does not list absent-model (has: stub-model"; then
    pass "a missing model is named, with what the host has"
else
    fail "missing-model skip not reported (rc=$rc): $(tail -1 "$STATE/nightly.log")"
fi

echo "== 9: once the host answers, the pending commit is reviewed on the next run =="
: > "$POSTS"
run_reviewer ""
if grep -q "reviewed 1 " <(tail -1 "$STATE/nightly.log"); then
    pass "the commit skipped in case 7 is reviewed as soon as the host is back"
else
    fail "pending commit was not reviewed after the host returned: $(tail -1 "$STATE/nightly.log")"
fi

echo
echo "════════════════════════════════════════════════"
echo "Tests passed: $PASSES"
echo "Tests failed: $FAILS"
echo "════════════════════════════════════════════════"
[ "$FAILS" -eq 0 ]
