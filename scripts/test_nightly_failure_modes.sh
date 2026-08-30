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
#
# r2 hardenings additionally pinned by the one-failure fixture:
#   * an XCTest-shape failure ("Test Case '-[X y]' failed (0.052 s).")
#     exercises the XCTest failed alternation + the second sed branch;
#   * an issue line whose expectation MESSAGE contains " failed after "
#     (near-miss in the wild: MediaFileOperationsTests.swift:556 asserts
#     a job reached .failed after the stall watchdog) contributes 0 —
#     only its test's own "failed after N seconds" line counts the 1,
#     and no message text leaks into failed_names.
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
    # 8a: failure excerpt — the diagnosed inflation case plus the r2
    # hardenings. Exactly 3 real failures (1 Swift Testing perf test,
    # 1 Swift Testing test whose ISSUE MESSAGE contains " failed after "
    # — must not double-count to 4 — and 1 XCTest-shape failure pinning
    # the second sed branch). Names must be the three test names only,
    # no issue-message fragments.
    got=$(run_parse "$FIXTURE_DIR/nightly_excerpt_one_failure.log")
    want='8|3|4|["-[VideoScanTests.MediaFileOperationsTests testStallWatchdogFreezesDurationClock]", "performanceRebuildUnderBudget()", "stallWatchdogStampsFinishedAt()"]'
    if [ "$got" = "$want" ]; then
        pass "failure fixture: PASSED=8 FAILED=3 SKIPPED=4, failed_names correct (issue line excluded, XCTest branch pinned)"
    else
        fail "failure fixture: got '$got', want '$want'"
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
# Test 9: every nightly row can carry additive person and POI-cycle fields.
# This pins the sensor that keeps the red 0 visible even on build/test failure
# rows, without changing their original status or reason.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 9: person metrics merge into failure row =="
PERSON_LIB="$SANDBOX/person_lib.sh"
awk '/^with_person_metrics\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" > "$PERSON_LIB"
if [ ! -s "$PERSON_LIB" ]; then
    fail "with_person_metrics could not be extracted from nightly_local_tests.sh"
else
    merged=$(
        PERSON_METRICS_JSON='{"person_eval_readiness_pct":0,"person_eval_readiness_band":"red","person_eval_quality_score":null,"poi_cycle_stream_status":"ok","poi_cycle_production_label":"C3"}'
        source "$PERSON_LIB"
        with_person_metrics '{"status":"failed","reason":"build-rc:65","total":0}'
    )
    got=$(printf '%s' "$merged" | python3 -c '
import json,sys
r=json.load(sys.stdin)
print(f"{r.get('"'"'status'"'"')}|{r.get('"'"'reason'"'"')}|{r.get('"'"'person_eval_readiness_pct'"'"')}|{r.get('"'"'person_eval_quality_score'"'"')}|{r.get('"'"'poi_cycle_stream_status'"'"')}|{r.get('"'"'poi_cycle_production_label'"'"')}")
')
    if [ "$got" = "failed|build-rc:65|0|None|ok|C3" ]; then
        pass "failure row preserves status and gains person + POI cycle sensors"
    else
        fail "person metric merge broke row contract: got '$got'"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Test 10: refresh_person_metrics invokes the collector with and without
# --allow-quality under macOS Bash 3.2 set -u. An empty array expansion must
# not abort before python3 is called.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 10: person collector optional quality flag under set -u =="
REFRESH_LIB="$SANDBOX/refresh_lib.sh"
awk '/^refresh_person_metrics\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" > "$REFRESH_LIB"

run_refresh_case() {
    local allow_quality="$1"
    local args_file="$2"
    (
        set -u
        LOGFILE="$SANDBOX/person-collector.log"
        PERSON_EVAL_MANIFEST="$SANDBOX/manifest.json"
        PERSON_EVAL_REPORT="$SANDBOX/report.json"
        PERSON_METRICS_JSON='{}'
        VIDEOSCAN_PERSON_EVAL_ALLOW_QUALITY="$allow_quality"
        # shellcheck disable=SC1090
        source "$REFRESH_LIB"
        log() { :; }
        python3() {
            printf '%s\n' "$*" > "$args_file"
            printf '%s\n' '{"person_eval_status":"ok"}'
        }
        refresh_person_metrics "$SANDBOX/VideoScan"
        [ "$PERSON_METRICS_JSON" = '{"person_eval_status":"ok"}' ]
    )
}

if [ ! -s "$REFRESH_LIB" ]; then
    fail "refresh_person_metrics could not be extracted from nightly_local_tests.sh"
else
    NO_QUALITY_ARGS="$SANDBOX/person-args-no-quality.txt"
    if run_refresh_case 0 "$NO_QUALITY_ARGS" &&
       [ -s "$NO_QUALITY_ARGS" ] &&
       ! grep -q -- '--allow-quality' "$NO_QUALITY_ARGS"; then
        pass "collector invoked without --allow-quality under set -u"
    else
        fail "collector aborted or received --allow-quality when opt-in was disabled"
    fi

    WITH_QUALITY_ARGS="$SANDBOX/person-args-with-quality.txt"
    if run_refresh_case 1 "$WITH_QUALITY_ARGS" &&
       [ -s "$WITH_QUALITY_ARGS" ] &&
       grep -q -- '--allow-quality' "$WITH_QUALITY_ARGS"; then
        pass "collector invoked with --allow-quality under set -u"
    else
        fail "collector aborted or omitted --allow-quality when opt-in was enabled"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Test 11: process-group watchdog expires deterministically, without Xcode
# or a wall-clock timeout. The injected deadline waits only for the fixture's
# parent to spawn a TERM-ignoring child, then fires immediately. KILL must
# remove both members of the private process group and return 124.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 11: deterministic process-group watchdog timeout =="
WATCHDOG_LIB="$SANDBOX/watchdog_lib.sh"
awk '/^nightly_timeout_reason\(\)/,/^# Run developer-tool maintenance/' \
    "$SCRIPT_DIR/nightly_local_tests.sh" | sed '$ d' > "$WATCHDOG_LIB"
WATCHDOG_FIXTURE="$SANDBOX/watchdog-fixture.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'trap "" TERM' \
    '( trap "" TERM; while :; do sleep 1; done ) &' \
    'printf "%s\n" "$!" > "$WATCHDOG_CHILD_PID_FILE"' \
    ': > "$WATCHDOG_FIXTURE_READY"' \
    'while :; do sleep 1; done' \
    > "$WATCHDOG_FIXTURE"
chmod +x "$WATCHDOG_FIXTURE"

run_watchdog_fixture() {
    local force_contamination="$1"
    local output_file="$2"
    (
        # shellcheck disable=SC1090
        source "$WATCHDOG_LIB"
        log() { echo "[watchdog-test] $*"; }
        export VIDEOSCAN_WATCHDOG_TEST_TIMEOUT_IMMEDIATELY=1
        export VIDEOSCAN_WATCHDOG_TEST_DEADLINE_READY_FILE="$WATCHDOG_FIXTURE_READY"
        if [ "$force_contamination" = "true" ]; then
            # Deterministically exercise the fail-open publication path for a
            # kernel-blocked, unreapable leader without creating one for real.
            export VIDEOSCAN_WATCHDOG_TEST_UNREAPABLE=1
        fi
        run_with_process_group_watchdog \
            999 0 "$SANDBOX/watchdog-command.log" "$WATCHDOG_FIXTURE"
    ) > "$output_file" 2>&1
}

if [ ! -s "$WATCHDOG_LIB" ]; then
    fail "watchdog helpers could not be extracted from nightly_local_tests.sh"
else
    NORMAL_OUTPUT="$SANDBOX/watchdog-normal-command.log"
    (
        # shellcheck disable=SC1090
        source "$WATCHDOG_LIB"
        log() { echo "[watchdog-test] $*"; }
        run_with_process_group_watchdog \
            5 0 "$NORMAL_OUTPUT" /bin/sh -c 'printf normal-output; exit 7'
    ) > "$SANDBOX/watchdog-normal-wrapper.log" 2>&1
    NORMAL_RC=$?
    if [ "$NORMAL_RC" -eq 7 ] && [ "$(cat "$NORMAL_OUTPUT")" = "normal-output" ]; then
        pass "watchdog preserves a prompt command's exit status and output"
    else
        fail "watchdog normal path broke (rc=$NORMAL_RC output=$(cat "$NORMAL_OUTPUT" 2>/dev/null))"
    fi

    export WATCHDOG_FIXTURE_READY="$SANDBOX/watchdog-fixture-ready"
    export WATCHDOG_CHILD_PID_FILE="$SANDBOX/watchdog-child.pid"
    rm -f "$WATCHDOG_FIXTURE_READY" "$WATCHDOG_CHILD_PID_FILE"
    WATCHDOG_OUTPUT="$SANDBOX/watchdog-output.log"
    run_watchdog_fixture false "$WATCHDOG_OUTPUT"
    WATCHDOG_RC=$?
    CHILD_PID=$(cat "$WATCHDOG_CHILD_PID_FILE" 2>/dev/null || echo 0)
    attempts=0
    while kill -0 "$CHILD_PID" 2>/dev/null && [ "$attempts" -lt 100 ]; do
        sleep 0.01
        attempts=$((attempts + 1))
    done
    if [ "$WATCHDOG_RC" -eq 124 ] && ! kill -0 "$CHILD_PID" 2>/dev/null; then
        pass "watchdog returned 124 and killed the TERM-ignoring process group"
    else
        fail "watchdog contract broke (rc=$WATCHDOG_RC child=$CHILD_PID still_alive=$(kill -0 "$CHILD_PID" 2>/dev/null && echo yes || echo no))"
    fi

    # Discriminating escalation case: the process-group leader accepts TERM
    # and exits during grace, but its descendant ignores TERM. The retained
    # leader must keep the PGID reserved until the descendant receives KILL.
    MIXED_FIXTURE="$SANDBOX/watchdog-mixed-term-fixture.sh"
    MIXED_READY="$SANDBOX/watchdog-mixed-ready"
    MIXED_CHILD_PID_FILE="$SANDBOX/watchdog-mixed-child.pid"
    SENTINEL_SIGNAL="$SANDBOX/watchdog-sentinel-signal"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '( trap "" TERM; while :; do sleep 1; done ) &' \
        'printf "%s\n" "$!" > "$WATCHDOG_MIXED_CHILD_PID_FILE"' \
        ': > "$WATCHDOG_MIXED_READY"' \
        'while :; do sleep 1; done' \
        > "$MIXED_FIXTURE"
    chmod +x "$MIXED_FIXTURE"
    (
        trap 'touch "$SENTINEL_SIGNAL"' TERM
        while :; do sleep 1; done
    ) &
    SENTINEL_PID=$!
    (
        # shellcheck disable=SC1090
        source "$WATCHDOG_LIB"
        log() { echo "[watchdog-test] $*"; }
        export VIDEOSCAN_WATCHDOG_TEST_TIMEOUT_IMMEDIATELY=1
        export VIDEOSCAN_WATCHDOG_TEST_DEADLINE_READY_FILE="$MIXED_READY"
        export WATCHDOG_MIXED_READY="$MIXED_READY"
        export WATCHDOG_MIXED_CHILD_PID_FILE="$MIXED_CHILD_PID_FILE"
        run_with_process_group_watchdog \
            999 0.05 "$SANDBOX/watchdog-mixed-command.log" "$MIXED_FIXTURE"
    ) > "$SANDBOX/watchdog-mixed-output.log" 2>&1
    MIXED_RC=$?
    MIXED_CHILD_PID=$(cat "$MIXED_CHILD_PID_FILE" 2>/dev/null || echo 0)
    attempts=0
    while kill -0 "$MIXED_CHILD_PID" 2>/dev/null && [ "$attempts" -lt 100 ]; do
        sleep 0.01
        attempts=$((attempts + 1))
    done
    if [ "$MIXED_RC" -eq 124 ] &&
       ! kill -0 "$MIXED_CHILD_PID" 2>/dev/null &&
       kill -0 "$SENTINEL_PID" 2>/dev/null &&
       [ ! -e "$SENTINEL_SIGNAL" ] &&
       ! grep -q 'CONTAMINATION:' "$SANDBOX/watchdog-mixed-output.log"; then
        pass "leader TERM exit still escalates TERM-ignoring child; unrelated process untouched"
    else
        fail "mixed TERM escalation broke (rc=$MIXED_RC child_alive=$(kill -0 "$MIXED_CHILD_PID" 2>/dev/null && echo yes || echo no) sentinel_alive=$(kill -0 "$SENTINEL_PID" 2>/dev/null && echo yes || echo no) contamination=$(grep -c 'CONTAMINATION:' "$SANDBOX/watchdog-mixed-output.log" || true))"
    fi
    kill -KILL "$SENTINEL_PID" 2>/dev/null || true
    wait "$SENTINEL_PID" 2>/dev/null || true

    rm -f "$WATCHDOG_FIXTURE_READY" "$WATCHDOG_CHILD_PID_FILE"
    CONTAMINATION_OUTPUT="$SANDBOX/watchdog-contamination.log"
    run_watchdog_fixture true "$CONTAMINATION_OUTPUT"
    CONTAMINATION_RC=$?
    if [ "$CONTAMINATION_RC" -eq 124 ] &&
       grep -q 'CONTAMINATION: watchdog could not reap PID/PGID' "$CONTAMINATION_OUTPUT"; then
        pass "ps-free unreapable PID/PGID is logged without blocking timeout return"
    else
        fail "contamination path broke (rc=$CONTAMINATION_RC output=$(tr '\n' ' ' < "$CONTAMINATION_OUTPUT"))"
    fi

    # The child exits after Python has declared the deadline but before the
    # supervisor signals its retained (unreaped) process group. No TERM trap
    # may fire, and the deadline still owns the 124 classification.
    RACE_READY="$SANDBOX/watchdog-race-presignal-ready"
    RACE_RELEASE="$SANDBOX/watchdog-race-presignal-release"
    RACE_SIGNAL="$SANDBOX/watchdog-race-signal"
    RACE_FIXTURE="$SANDBOX/watchdog-race-fixture.sh"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'trap '\''touch "$WATCHDOG_RACE_SIGNAL"'\'' TERM' \
        'while [ ! -e "$WATCHDOG_RACE_READY" ]; do sleep 0.01; done' \
        ': > "$WATCHDOG_RACE_RELEASE"' \
        'exit 0' \
        > "$RACE_FIXTURE"
    chmod +x "$RACE_FIXTURE"
    (
        # shellcheck disable=SC1090
        source "$WATCHDOG_LIB"
        log() { echo "[watchdog-test] $*"; }
        export VIDEOSCAN_WATCHDOG_TEST_TIMEOUT_IMMEDIATELY=1
        export VIDEOSCAN_WATCHDOG_TEST_PRE_SIGNAL_READY_FILE="$RACE_READY"
        export VIDEOSCAN_WATCHDOG_TEST_PRE_SIGNAL_RELEASE_FILE="$RACE_RELEASE"
        export WATCHDOG_RACE_READY="$RACE_READY"
        export WATCHDOG_RACE_RELEASE="$RACE_RELEASE"
        export WATCHDOG_RACE_SIGNAL="$RACE_SIGNAL"
        run_with_process_group_watchdog \
            999 0 "$SANDBOX/watchdog-race-command.log" "$RACE_FIXTURE"
    ) > "$SANDBOX/watchdog-race-output.log" 2>&1
    RACE_RC=$?
    if [ "$RACE_RC" -eq 124 ] && [ ! -e "$RACE_SIGNAL" ]; then
        pass "completion-at-deadline keeps PGID reserved and sends no post-completion signal"
    else
        fail "completion-at-deadline race broke (rc=$RACE_RC signal_seen=$([ -e "$RACE_SIGNAL" ] && echo yes || echo no) output=$(tr '\n' ' ' < "$SANDBOX/watchdog-race-output.log"))"
    fi
fi

# ───────────────────────────────────────────────────────────────────
# Test 12: timeout classification has precedence over zero tests, failures,
# and an ordinary xcodebuild rc. This is the row reason the dashboard sees.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 12: timeout reason and classification precedence =="
(
    # shellcheck disable=SC1090
    source "$WATCHDOG_LIB"
    classify_nightly_test_result true 7 0 0 false 70
    printf '%s|%s\n' "$STATUS" "$REASON"
) > "$SANDBOX/classify-timeout-zero.txt"
(
    # shellcheck disable=SC1090
    source "$WATCHDOG_LIB"
    classify_nightly_test_result true 7 9 2 true 65
    printf '%s|%s\n' "$STATUS" "$REASON"
) > "$SANDBOX/classify-timeout-failures.txt"
TIMEOUT_ZERO=$(cat "$SANDBOX/classify-timeout-zero.txt")
TIMEOUT_FAILURES=$(cat "$SANDBOX/classify-timeout-failures.txt")
BUILD_REASON=$(bash -c "source '$WATCHDOG_LIB'; nightly_timeout_reason build 11")
if [ "$TIMEOUT_ZERO" = "failed|test-timeout:7s" ] &&
   [ "$TIMEOUT_FAILURES" = "failed|test-timeout:7s" ] &&
   [ "$BUILD_REASON" = "build-timeout:11s" ]; then
    pass "build/test timeout reasons are explicit and timeout outranks zero/failure rc"
else
    fail "timeout classification broke (zero=$TIMEOUT_ZERO failures=$TIMEOUT_FAILURES build=$BUILD_REASON)"
fi

# ───────────────────────────────────────────────────────────────────
# Test 13: a test timeout publishes its partial counts immediately with null
# coverage and the pre-build readiness snapshot. Neither xccov nor the live
# person evaluator may run before that durable-row path returns.
# ───────────────────────────────────────────────────────────────────
echo
echo "== Test 13: timeout publishes partial row before optional metrics =="
TIMEOUT_PUBLISH_LIB="$SANDBOX/timeout_publish_lib.sh"
awk '/^with_person_metrics\(\)/,/^log "=== Nightly local test run starting/' \
    "$SCRIPT_DIR/nightly_local_tests.sh" | sed '$ d' > "$TIMEOUT_PUBLISH_LIB"
TIMEOUT_ROW_FILE="$SANDBOX/timeout-row.json"
OPTIONAL_WORK_FILE="$SANDBOX/timeout-optional-work-ran"
(
    # shellcheck disable=SC1090
    source "$TIMEOUT_PUBLISH_LIB"
    HOST="TestHost"
    BRANCH="main"
    COMMIT="abc123"
    COMMIT_DATE="2026-08-30"
    DIRTY=false
    PASSED=4
    FAILED=1
    SKIPPED=2
    TOTAL=7
    ELAPSED=9
    STATUS="failed"
    REASON="test-timeout:7s"
    NIGHTLY_SCRIPT_VERSION="test"
    FAILED_NAMES_JSON='["heldSensor()"]'
    COV_LOGIC="91.2"
    PERSON_METRICS_JSON='{"person_eval_status":"not-configured","person_eval_readiness_pct":0,"person_eval_readiness_band":"red"}'
    PUBLISH_RC=99
    log() { :; }
    publish_row() { printf '%s\n' "$1" > "$TIMEOUT_ROW_FILE"; return 0; }
    xcrun() { : > "$OPTIONAL_WORK_FILE"; return 99; }
    refresh_person_metrics() { : > "$OPTIONAL_WORK_FILE"; return 99; }
    orchestrate_post_test_result true 7
    ROUTE_RC=$?
    [ "$ROUTE_RC" -eq 124 ] && [ "$PUBLISH_RC" -eq 0 ]
)
TIMEOUT_PUBLISH_RC=$?
TIMEOUT_ROW_SUMMARY=$(python3 - "$TIMEOUT_ROW_FILE" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    row = json.load(stream)
print("|".join([
    row["status"], row["reason"], str(row["passed"]), str(row["failed"]),
    str(row["skipped"]), str(row["total"]), str(row.get("coverage_logic_pct")),
    row["person_eval_status"], str(row["person_eval_readiness_pct"]),
]))
PY
)
if [ "$TIMEOUT_PUBLISH_RC" -eq 0 ] &&
   [ "$TIMEOUT_ROW_SUMMARY" = "failed|test-timeout:7s|4|1|2|7|None|not-configured|0" ] &&
   [ ! -e "$OPTIONAL_WORK_FILE" ]; then
    pass "timeout row retains partial counts/readiness and bypasses coverage + live evaluator"
else
    fail "timeout publication broke (rc=$TIMEOUT_PUBLISH_RC row=$TIMEOUT_ROW_SUMMARY optional=$([ -e "$OPTIONAL_WORK_FILE" ] && echo ran || echo skipped))"
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
