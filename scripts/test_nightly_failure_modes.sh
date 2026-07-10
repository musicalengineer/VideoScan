#!/usr/bin/env bash
# test_nightly_failure_modes.sh — Simulate every failure path through
# the nightly script's publish_row pipeline and assert that a row
# (live or queued) is produced in EVERY case.
#
# This DOES NOT touch origin/metrics. It builds a throwaway local
# bare repo, points the publish_row helpers at it, and exercises
# them in isolation.
#
# Usage:  scripts/test_nightly_failure_modes.sh
# Exit:   0 if all assertions pass, 1 if any fail.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX="${TMPDIR:-/tmp}/nightly-failure-mode-sandbox-$$"
mkdir -p "$SANDBOX"
trap "rm -rf $SANDBOX" EXIT

FAILS=0
PASSES=0
RESULTS=()

pass() { PASSES=$((PASSES + 1)); RESULTS+=("PASS: $*"); echo "  PASS: $*"; }
fail() { FAILS=$((FAILS + 1));  RESULTS+=("FAIL: $*"); echo "  FAIL: $*"; }

# ───────────────────────────────────────────────────────────────────
# Setup: a fake "origin" bare repo with a `metrics` branch that has
# one prior row, plus a workspace repo with `metrics` available.
# ───────────────────────────────────────────────────────────────────
echo "== Setting up sandbox at $SANDBOX =="
ORIGIN="$SANDBOX/origin.git"
WORK="$SANDBOX/work"
git init --bare --quiet "$ORIGIN"

git init --quiet "$WORK"
cd "$WORK"
git config user.email "test@nightly"
git config user.name  "Test Nightly"
git remote add origin "$ORIGIN"

# Bootstrap main with a single commit so HEAD is valid.
echo "stub" > README.md
git add README.md
git commit -q -m "initial"
git branch -M main
git push -q origin main

# Bootstrap orphan `metrics` branch with one prior row.
git checkout --orphan metrics --quiet
git rm -rf . --quiet 2>/dev/null || true
mkdir -p metrics
echo '{"ts":"2026-06-13T06:00:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1000,"failed":0,"total":1000}' > metrics/testdriver.jsonl
git add metrics/testdriver.jsonl
git commit -q -m "bootstrap"
git push -q origin metrics
git checkout main --quiet

# ───────────────────────────────────────────────────────────────────
# Source the publish helpers from the real nightly script, but
# override the constants to point at the sandbox. We accomplish this
# by extracting the relevant functions to a small library, then in
# each test override REPO / METRICS_WT / PENDING_QUEUE.
# Simpler: we re-implement a thin test driver that calls the real
# functions via an isolated subshell with overridden env.
# ───────────────────────────────────────────────────────────────────

PENDING_Q="$SANDBOX/pending.jsonl"
METRICS_WT_TEST="$SANDBOX/metrics-wt"

# Helper: run publish_row inside the work repo, but with the real
# script's helpers patched in. We do this by sourcing the script with
# `set -u` AND short-circuiting the runtime via $TEST_HARNESS_MODE.
# To avoid invasive script edits, we instead carve out the publish_row
# function into a sourceable lib.
PUBLISH_LIB="$SANDBOX/publish_lib.sh"
# Extract from line `# ── Row publisher with backlog queue` to line
# `# ── Branch + dirty-tree handling`, exclusive.
awk '/^# ── Row publisher with backlog queue/,/^# ── Branch \+ dirty-tree handling/' \
    "$SCRIPT_DIR/nightly_local_tests.sh" \
    | sed '$ d' > "$PUBLISH_LIB"

# Inject minimal globals the function expects.
{
    echo "REPO=\"$WORK\""
    echo "METRICS_WT=\"$METRICS_WT_TEST\""
    echo "PENDING_QUEUE=\"$PENDING_Q\""
    echo "HOST=\"TestHost\""
    echo "NIGHTLY_SCRIPT_VERSION=\"test\""
    echo "log() { echo \"[harness] \$*\"; }"
    cat "$PUBLISH_LIB"
} > "$PUBLISH_LIB.full"
mv "$PUBLISH_LIB.full" "$PUBLISH_LIB"

# ───────────────────────────────────────────────────────────────────
# Test 1: Happy path — publish a single row to a healthy metrics branch.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 1: happy path =="
(
    cd "$WORK"
    # shellcheck disable=SC1090
    source "$PUBLISH_LIB"
    : > "$PENDING_Q"
    ROW='{"ts":"2026-06-14T06:00:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    if publish_row "$ROW"; then
        echo "  publish_row returned 0"
    else
        echo "  publish_row returned NON-ZERO"
        exit 1
    fi
)
TEST1_RC=$?
# Check origin received the row.
TIP_ROWS=$(cd "$WORK" && git fetch origin metrics --quiet && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"ts"' || true)
if [ "$TEST1_RC" -eq 0 ] && [ "$TIP_ROWS" -ge 2 ]; then
    pass "happy path published row (origin now has $TIP_ROWS rows)"
else
    fail "happy path FAILED (rc=$TEST1_RC, origin rows=$TIP_ROWS)"
fi
if [ -s "$PENDING_Q" ]; then
    fail "happy path: pending queue should be empty, but has $(wc -l < "$PENDING_Q") rows"
else
    pass "happy path: pending queue is empty"
fi

# ───────────────────────────────────────────────────────────────────
# Test 2: Worktree on WRONG BRANCH — script should rebuild it.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 2: worktree on wrong branch =="
# Simulate a poisoned worktree: existing dir, but on `main` (not metrics).
rm -rf "$METRICS_WT_TEST"
(cd "$WORK" && git worktree add "$METRICS_WT_TEST" main --quiet)
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    : > "$PENDING_Q"
    ROW='{"ts":"2026-06-14T06:01:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    if publish_row "$ROW"; then
        echo "  publish_row recovered"
    else
        echo "  publish_row FAILED"
        exit 1
    fi
)
TEST2_RC=$?
TIP_ROWS=$(cd "$WORK" && git fetch origin metrics --quiet && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"ts"' || true)
if [ "$TEST2_RC" -eq 0 ] && [ "$TIP_ROWS" -ge 3 ]; then
    pass "wrong-branch worktree rebuilt and row published (origin rows=$TIP_ROWS)"
else
    fail "wrong-branch worktree recovery FAILED (rc=$TEST2_RC, origin rows=$TIP_ROWS)"
fi

# ───────────────────────────────────────────────────────────────────
# Test 3: Corrupted worktree dir (.git missing) — should rebuild.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 3: corrupted worktree =="
rm -rf "$METRICS_WT_TEST"
mkdir -p "$METRICS_WT_TEST"
echo "garbage" > "$METRICS_WT_TEST/something.txt"
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    : > "$PENDING_Q"
    ROW='{"ts":"2026-06-14T06:02:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    publish_row "$ROW"
)
TEST3_RC=$?
TIP_ROWS=$(cd "$WORK" && git fetch origin metrics --quiet && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"ts"' || true)
if [ "$TEST3_RC" -eq 0 ] && [ "$TIP_ROWS" -ge 4 ]; then
    pass "corrupted worktree recovered (origin rows=$TIP_ROWS)"
else
    fail "corrupted worktree recovery FAILED (rc=$TEST3_RC, origin rows=$TIP_ROWS)"
fi

# ───────────────────────────────────────────────────────────────────
# Test 4: Push CONFLICT — another writer added a row between our
# fetch and push. Should rebase+retry and end up with BOTH rows.
#
# Simulation strategy: push our row through publish_row normally, but
# BEFORE the function calls `git push`, sneak a competing commit into
# origin. We do that by patching a competitor commit in via a separate
# clone, then running publish_row.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 4: push conflict (concurrent writer) =="
# First step: clean up any leftover worktree from prior tests so we
# can use a separate clone for the competitor.
(cd "$WORK" && git worktree remove --force "$METRICS_WT_TEST" 2>/dev/null || true)
(cd "$WORK" && git worktree prune)

# Build a SEPARATE clone for the competitor (different .git, different
# worktree namespace) so we can add `metrics` there without colliding.
COMPETITOR_CLONE="$SANDBOX/competitor-clone"
git clone --quiet "$ORIGIN" "$COMPETITOR_CLONE"
(cd "$COMPETITOR_CLONE" && git config user.email "competitor@t" && git config user.name "Competitor")
(cd "$COMPETITOR_CLONE" && git fetch origin metrics --quiet && git checkout -B metrics origin/metrics --quiet)
echo '{"ts":"2026-06-14T06:03:00Z","source":"adhoc-m1","host":"OtherHost","status":"ok","reason":"","passed":1234,"failed":0,"total":1234}' \
    >> "$COMPETITOR_CLONE/metrics/testdriver.jsonl"
(cd "$COMPETITOR_CLONE" && git add metrics/testdriver.jsonl \
    && git commit -q -m "competing row" \
    && git push -q origin metrics)

# Now stage OUR side to think it's at the OLD origin/metrics tip, then
# call publish_row. The function's internal fetch should see the new
# competitor row and rebase past it. If it doesn't fetch fresh, the
# push will reject and the function should retry.
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    : > "$PENDING_Q"
    ROW='{"ts":"2026-06-14T06:03:30Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    publish_row "$ROW"
)
TEST4_RC=$?
TIP_ROWS=$(cd "$WORK" && git fetch origin metrics --quiet && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"ts"' || true)
COMPETITOR_PRESENT=$(cd "$WORK" && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"adhoc-m1"' || true)
OURS_PRESENT=$(cd "$WORK" && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"2026-06-14T06:03:30Z"' || true)
if [ "$TEST4_RC" -eq 0 ] && [ "$COMPETITOR_PRESENT" -ge 1 ] && [ "$OURS_PRESENT" -ge 1 ]; then
    pass "push conflict resolved, both rows present (origin rows=$TIP_ROWS)"
else
    fail "push conflict FAILED (rc=$TEST4_RC, competitor=$COMPETITOR_PRESENT, ours=$OURS_PRESENT)"
fi

# ───────────────────────────────────────────────────────────────────
# Test 5: ORIGIN UNREACHABLE — push fails entirely. Row should be
# queued in PENDING_QUEUE for next-run replay.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 5: origin unreachable =="
(cd "$WORK" && rm -rf "$METRICS_WT_TEST")
# Break the remote by pointing it at a nonexistent path.
(cd "$WORK" && git remote set-url origin "$SANDBOX/does-not-exist.git")
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    : > "$PENDING_Q"
    ROW='{"ts":"2026-06-14T06:04:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    publish_row "$ROW"
) >/dev/null 2>&1
TEST5_RC=$?
QUEUE_SIZE=$(wc -l < "$PENDING_Q" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$TEST5_RC" -ne 0 ] && [ "$QUEUE_SIZE" -ge 1 ]; then
    pass "origin unreachable: row queued for retry (queue=$QUEUE_SIZE)"
else
    fail "origin unreachable handling FAILED (rc=$TEST5_RC, queue=$QUEUE_SIZE)"
fi
# Restore origin.
(cd "$WORK" && git remote set-url origin "$ORIGIN")

# ───────────────────────────────────────────────────────────────────
# Test 6: NEXT RUN drains the pending queue along with the new row.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 6: queue drain on next successful run =="
# The pending queue from Test 5 still has 1 row. Now publish a new row;
# both should land.
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    ROW='{"ts":"2026-06-14T06:05:00Z","source":"nightly-local","host":"TestHost","status":"ok","reason":"","passed":1851,"failed":0,"total":1860}'
    publish_row "$ROW"
)
TEST6_RC=$?
TIP_ROWS=$(cd "$WORK" && git fetch origin metrics --quiet && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"ts"' || true)
ROW_5_PRESENT=$(cd "$WORK" && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"2026-06-14T06:04:00Z"' || true)
ROW_6_PRESENT=$(cd "$WORK" && git show origin/metrics:metrics/testdriver.jsonl | grep -c '"2026-06-14T06:05:00Z"' || true)
QUEUE_AFTER=$(wc -l < "$PENDING_Q" 2>/dev/null | tr -d ' ' || echo 0)
if [ "$TEST6_RC" -eq 0 ] && [ "$ROW_5_PRESENT" -ge 1 ] && [ "$ROW_6_PRESENT" -ge 1 ] && [ "$QUEUE_AFTER" -eq 0 ]; then
    pass "queue drain succeeded: backlog row + new row published, queue cleared"
else
    fail "queue drain FAILED (rc=$TEST6_RC, backlog=$ROW_5_PRESENT, new=$ROW_6_PRESENT, queue=$QUEUE_AFTER)"
fi

# ───────────────────────────────────────────────────────────────────
# Test 7: make_status_row produces VALID JSON for every failure mode.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 7: make_status_row JSON validity for every reason code =="
# Use the function from the real script via shell extraction.
MAKE_LIB="$SANDBOX/make_lib.sh"
{
    echo "HOST=\"TestHost\""
    echo "NIGHTLY_SCRIPT_VERSION=\"test\""
    awk '/^make_status_row\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh"
} > "$MAKE_LIB"

for reason in "off-main:feature/foo" "dirty-tree:scripts/x.sh,VideoScan/y.swift" "ahead-of-origin:5" "build-rc:65" "ui-runner-hung" "zero-tests-ran:test-rc=70" "failed-tests:12" "unexpected:weird thing"; do
    out=$(bash -c "source $MAKE_LIB; make_status_row failed \"$reason\" true abcd123 2026-06-13 main")
    if echo "$out" | python3 -m json.tool > /dev/null 2>&1; then
        pass "valid JSON for reason='$reason'"
    else
        fail "INVALID JSON for reason='$reason': $out"
    fi
done

# ───────────────────────────────────────────────────────────────────
# Test 8: parse_test_counts — fixture-driven count + failed_names check.
#
# Regression for 2026-07-09: one failing Swift Testing test published
# failed:3 because the old grep matched the issue line, the per-test
# "failed after" line AND the "✘ Test run with …" summary. The fixtures
# are saved excerpts of real nightly xcodebuild output (including the
# zero-width-space-indented "➜ Test … skipped:" lines and started-lines
# whose display names contain the word "skipped").
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 8: parse_test_counts fixture counts =="
PARSE_LIB="$SANDBOX/parse_lib.sh"
awk '/^parse_test_counts\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" > "$PARSE_LIB"
FIXTURE_DIR="$SCRIPT_DIR/../tests/fixtures/logs"

# Runs parse_test_counts on a log in a subshell and echoes
# "PASSED|FAILED|SKIPPED|FAILED_NAMES_JSON" for main-shell comparison.
run_parse() {
    # shellcheck disable=SC1090
    ( source "$PARSE_LIB"
      parse_test_counts "$1"
      echo "$PASSED|$FAILED|$SKIPPED|$FAILED_NAMES_JSON" )
}

if [ ! -s "$PARSE_LIB" ]; then
    fail "parse_test_counts could not be extracted from nightly_local_tests.sh"
else
    # 8a: single-failure excerpt — the diagnosed inflation case. FAILED
    # MUST be exactly 1 (old pattern said 3), names must carry the test.
    got=$(run_parse "$FIXTURE_DIR/nightly_excerpt_one_failure.log")
    want='8|1|4|["performanceRebuildUnderBudget()"]'
    if [ "$got" = "$want" ]; then
        pass "one-failure fixture: PASSED=8 FAILED=1 SKIPPED=4, failed_names correct"
    else
        fail "one-failure fixture: got '$got', want '$want'"
    fi

    # 8b: green excerpt — the "✔ Test run with …" summary and started-
    # lines with "skipped" in their display names must NOT count;
    # failed_names must be [].
    got=$(run_parse "$FIXTURE_DIR/nightly_excerpt_green.log")
    want='8|0|4|[]'
    if [ "$got" = "$want" ]; then
        pass "green fixture: PASSED=8 FAILED=0 SKIPPED=4, failed_names=[]"
    else
        fail "green fixture: got '$got', want '$want'"
    fi

    # 8c: empty input — counts must be plain integer zeros (the
    # 2026-06-14 "0\n0" arithmetic-crash guard), names must be [].
    : > "$SANDBOX/empty.log"
    got=$(run_parse "$SANDBOX/empty.log")
    if [ "$got" = "0|0|0|[]" ]; then
        pass "empty log: all counts 0, failed_names=[]"
    else
        fail "empty log parsing broke: got '$got' (counts must be plain integers)"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════"
echo "Tests passed: $PASSES"
echo "Tests failed: $FAILS"
echo "════════════════════════════════════════════════════════════════"
if [ "$FAILS" -gt 0 ]; then
    echo "FAILURES:"
    for r in "${RESULTS[@]}"; do
        case "$r" in FAIL:*) echo "  $r" ;; esac
    done
    exit 1
fi
exit 0
