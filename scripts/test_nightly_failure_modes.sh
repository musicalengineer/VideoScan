#!/usr/bin/env bash
# test_nightly_failure_modes.sh — Simulate every failure path through
# the nightly script's publish_row pipeline and assert that a row
# (live or queued) is produced in EVERY case.
#
# This DOES NOT touch origin/metrics. It builds a throwaway local
# bare repo, points the publish_row helpers at it, and exercises
# them in isolation.
#
# Usage:  scripts/test_nightly_failure_modes.sh                 # every section, in order
#         SELFTEST_SECTIONS="1 2 3 7b" scripts/test_nightly_failure_modes.sh
#         scripts/test_nightly_failure_modes.sh --list-sections  # "<section> [needs…]" per line
# Exit:   0 if all assertions pass, 1 if any fail, 2 if SELFTEST_SECTIONS
#         names an unknown section or leaves out a section's prerequisite.
#
# Sections (2026-11-20, Rick: "we do not want to serialize when we can
# parallelize"): each "== Test N ==" block is a function section_N, run in
# script order. SELFTEST_SECTIONS picks a subset; each run builds its own
# mktemp sandbox, so concurrent runs share no path, port or HOME
# (tests/test_nightly_failure_modes_<group>.py run the groups at once).
# Fixtures several sections read (an extracted nightly function, row_fields.py,
# the fake metrics repo, the fake rota HOME) are built on first use by a
# need_* function, so a section run alone builds what it reads. State one
# section LEAVES for another (row counts on origin, the pending queue) is a
# real dependency: SECTION_NEEDS names it, and a selection without the
# prerequisite is refused rather than run half-set-up.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Script order. A new section is a section_<name> function AND a word here
# (tests/test_nightly_shell_selftests.py pins both, and every word in a group).
SECTIONS="1 2 3 4 5 6 7 7b 8 9 9b 10 11 12 12b 13 14 14b 15 16 17 18"
# "<section>:<prerequisite>" — the prerequisite left state this section asserts on.
#   2:1, 3:2  origin row counts (Test 2 asserts >= 3 rows: Test 1's + its own)
#   6:5       Test 6 drains the row Test 5 queued in pending.jsonl
SECTION_NEEDS="2:1 3:2 6:5"

section_needs() {   # section → its prerequisites, space separated
    local pair out=""
    for pair in $SECTION_NEEDS; do
        [ "${pair%%:*}" = "$1" ] && out="$out ${pair#*:}"
    done
    echo "${out# }"
}

if [ "${1:-}" = "--list-sections" ]; then
    for s in $SECTIONS; do echo "$s $(section_needs "$s")" | sed 's/ $//'; done
    exit 0
fi

has_word() {   # word list → 0 when word is in list
    local w
    for w in $2; do [ "$w" = "$1" ] && return 0; done
    return 1
}

if [ -n "${SELFTEST_SECTIONS:-}" ]; then
    for s in $SELFTEST_SECTIONS; do
        if ! has_word "$s" "$SECTIONS"; then
            echo "SELFTEST_SECTIONS: unknown section '$s' (known: $SECTIONS)" >&2
            exit 2
        fi
        for need in $(section_needs "$s"); do
            if ! has_word "$need" "$SELFTEST_SECTIONS"; then
                echo "SELFTEST_SECTIONS: section $s needs section $need (it asserts on state $need leaves); select both" >&2
                exit 2
            fi
        done
    done
    RUN_SECTIONS="$SELFTEST_SECTIONS"
else
    RUN_SECTIONS="$SECTIONS"
fi

# mktemp, never a fixed or PID-derived name: a run killed before its EXIT trap
# leaves its sandbox behind, and a later run that reused the name would start
# on a stale origin.git.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/nightly-failure-mode-sandbox.XXXXXX")" || exit 2
trap 'rm -rf "$SANDBOX"' EXIT
# Nothing relative may land in the caller's directory (the repo, under pytest).
cd "$SANDBOX" || exit 2

FAILS=0
PASSES=0
RESULTS=()

pass() { PASSES=$((PASSES + 1)); RESULTS+=("PASS: $*"); echo "  PASS: $*"; }
fail() { FAILS=$((FAILS + 1));  RESULTS+=("FAIL: $*"); echo "  FAIL: $*"; }

# ───────────────────────────────────────────────────────────────────
# Setup: a fake "origin" bare repo with a `metrics` branch that has
# one prior row, plus a workspace repo with `metrics` available.
# Built once, on first use by a publish section (1–6).
# ───────────────────────────────────────────────────────────────────
PUBLISH_SANDBOX_READY=false
need_publish_sandbox() {
$PUBLISH_SANDBOX_READY && return 0
PUBLISH_SANDBOX_READY=true
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
}

# ── Fixtures more than one section reads, built on first use ────────
# (each is idempotent; in the full run the first reader builds it at the
# point the old serial script did).

WATCHDOG_LIB="$SANDBOX/watchdog_lib.sh"
need_watchdog_lib() {   # Tests 11, 12, 12b, 14, 14b, 15
    [ -e "$WATCHDOG_LIB" ] && return 0
    # The watchdog itself lives in scripts/lib/process_group_watchdog.sh (lifted
    # 2026-10-01); the nightly sources it. Test the real lib plus the nightly's
    # own helpers around it, minus the nightly's `source` line (it resolves
    # relative to the nightly script, not to this extracted copy).
    cat "$SCRIPT_DIR/lib/process_group_watchdog.sh" > "$WATCHDOG_LIB"
    awk '/^nightly_timeout_reason\(\)/,/^# Refresh the privacy-safe person-recognition fields/' \
        "$SCRIPT_DIR/nightly_local_tests.sh" | sed '$ d' \
        | grep -v '^source .*process_group_watchdog\.sh' >> "$WATCHDOG_LIB"
    grep -q '^source .*lib/process_group_watchdog\.sh' "$SCRIPT_DIR/nightly_local_tests.sh" \
        || fail "nightly_local_tests.sh no longer sources lib/process_group_watchdog.sh"
}

PERSON_LIB="$SANDBOX/person_lib.sh"
need_person_lib() {   # Tests 9, 9b
    [ -e "$PERSON_LIB" ] && return 0
    awk '/^with_person_metrics\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" > "$PERSON_LIB"
}

need_row_fields() {   # Tests 9b, 14, 14b: print the named keys of a JSON row, '|'-joined
    [ -e "$SANDBOX/row_fields.py" ] && return 0
    cat > "$SANDBOX/row_fields.py" <<'PYF'
import json, sys
r = json.load(sys.stdin)
print("|".join(str(r.get(k)) for k in sys.argv[1:]))
PYF
}

CORE_LIB="$SANDBOX/core_lib.sh"
need_core_lib() {   # Tests 14, 14b: the watchdog lib + the nightly's lane functions
    [ -e "$CORE_LIB" ] && return 0
    need_watchdog_lib
    cat "$WATCHDOG_LIB" > "$CORE_LIB"
    awk '/^with_person_metrics\(\)/,/^log "=== Nightly local test run starting/' \
        "$SCRIPT_DIR/nightly_local_tests.sh" | sed '$ d' >> "$CORE_LIB"
}

need_wiring_lines() {   # Tests 14, 14b: where the nightly builds and classifies
    BUILD_CALL_LINE=$(grep -n '^run_nightly_build$' "$SCRIPT_DIR/nightly_local_tests.sh" | head -1 | cut -d: -f1)
    CLASSIFY_LINE=$(grep -n '^classify_nightly_test_result \\$' "$SCRIPT_DIR/nightly_local_tests.sh" | cut -d: -f1)
}

# The fake rota machine for Tests 16–18: copies of the real guard, installers
# and rota in $RT/scripts, a sandbox HOME, fake scutil / launchctl / crontab.
RT="$SANDBOX/rota"
need_rota() {
    [ -d "$RT/scripts" ] && return 0
    mkdir -p "$RT/scripts" "$RT/bin" "$RT/home/Library/LaunchAgents"
    cp "$SCRIPT_DIR/nightly_guarded.sh" "$SCRIPT_DIR/install_nightly.sh" "$SCRIPT_DIR/nightly_rota.py" "$SCRIPT_DIR/nightly_rota.json" "$RT/scripts/"
    printf '%s\n' '#!/bin/sh' 'echo "$FAKE_HOST"' > "$RT/bin/scutil"
    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_LAUNCHCTL_LOG"' > "$RT/bin/launchctl"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$RT/bin/crontab"
    chmod +x "$RT/bin"/*
}
rota_run() {
    # args: host script -> rc; logs in $RT
    : > "$RT/launchctl.log"; : > "$RT/git.log"
    HOME="$RT/home" FAKE_HOST="$1" FAKE_LAUNCHCTL_LOG="$RT/launchctl.log" FAKE_GIT_LOG="$RT/git.log" \
        PATH="$RT/bin:$PATH" bash "$RT/scripts/$2" > "$RT/out.log" 2>&1
}

# Tests 17, 18: a git whose `show` prints $FAKE_ROWS and whose `rev-parse`
# says where origin/main is ($FAKE_MAIN; 2026-11-10: the guard skips only for
# a green row of THAT commit); a caffeinate that records the run.
GUARD_FAKES_READY=false
need_guard_fakes() {
    $GUARD_FAKES_READY && return 0
    GUARD_FAKES_READY=true
    need_rota
    TODAY_UTC="$(date -u +%Y-%m-%d)"
    MAIN_NOW=4dc4eb2a6c5ef9c4baf812d8b6b068abeb853fce
    MAIN_BEFORE=25bcbab2e3f8ecfe7b3701bcefdc5c29ce2b35c5
    printf '%s\n' '#!/bin/sh' 'case "$1" in show) cat "$FAKE_ROWS" ;; rev-parse) echo "${FAKE_MAIN:-}" ;; esac' 'exit 0' > "$RT/bin/git"
    printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_CAFF_LOG"' 'exit 0' > "$RT/bin/caffeinate"
    chmod +x "$RT/bin/git" "$RT/bin/caffeinate"
    M4_GREEN="{\"ts\":\"${TODAY_UTC}T06:47:12Z\",\"host\":\"RicksM4\",\"commit\":\"${MAIN_NOW:0:9}\",\"status\":\"ok\",\"total\":12632}"
    ULTRA_GREEN="{\"ts\":\"${TODAY_UTC}T09:50:00Z\",\"host\":\"RicksUltra\",\"commit\":\"${MAIN_NOW:0:9}\",\"status\":\"ok\",\"total\":12632}"
    ULTRA_GREEN_BEFORE="{\"ts\":\"${TODAY_UTC}T05:40:00Z\",\"host\":\"RicksUltra\",\"commit\":\"${MAIN_BEFORE:0:9}\",\"status\":\"ok\",\"total\":12632}"
}
guard_ran() {
    # args: host rows-json-lines -> 0 when the guard started the nightly
    printf '%s\n' "$2" > "$RT/rows.jsonl"; : > "$RT/caff.log"
    HOME="$RT/home" FAKE_HOST="$1" FAKE_ROWS="$RT/rows.jsonl" FAKE_CAFF_LOG="$RT/caff.log" FAKE_MAIN="$MAIN_NOW" \
        PATH="$RT/bin:$PATH" bash "$RT/scripts/nightly_guarded.sh" > "$RT/out.log" 2>&1
    grep -q 'nightly_local_tests.sh' "$RT/caff.log"
}

# Section bodies are not indented inside their functions: several carry
# heredocs whose text and terminator must stay at column 0.

# ───────────────────────────────────────────────────────────────────
# Test 1: Happy path — publish a single row to a healthy metrics branch.
# ───────────────────────────────────────────────────────────────────
section_1() {
need_publish_sandbox
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

}

# ───────────────────────────────────────────────────────────────────
# Test 2: Worktree on WRONG BRANCH — script should rebuild it.
# ───────────────────────────────────────────────────────────────────
section_2() {
need_publish_sandbox
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

}

# ───────────────────────────────────────────────────────────────────
# Test 3: Corrupted worktree dir (.git missing) — should rebuild.
# ───────────────────────────────────────────────────────────────────
section_3() {
need_publish_sandbox
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

}

# ───────────────────────────────────────────────────────────────────
# Test 4: Push CONFLICT — another writer added a row between our
# fetch and push. Should rebase+retry and end up with BOTH rows.
#
# Simulation strategy: push our row through publish_row normally, but
# BEFORE the function calls `git push`, sneak a competing commit into
# origin. We do that by patching a competitor commit in via a separate
# clone, then running publish_row.
# ───────────────────────────────────────────────────────────────────
section_4() {
need_publish_sandbox
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

}

# ───────────────────────────────────────────────────────────────────
# Test 5: ORIGIN UNREACHABLE — push fails entirely. Row should be
# queued in PENDING_QUEUE for next-run replay.
# ───────────────────────────────────────────────────────────────────
section_5() {
need_publish_sandbox
echo
echo "== Test 5: origin unreachable =="
(cd "$WORK" && rm -rf "$METRICS_WT_TEST")
# Break the remote by pointing it at a nonexistent path.
(cd "$WORK" && git remote set-url origin "$SANDBOX/does-not-exist.git")
(
    cd "$WORK"
    source "$PUBLISH_LIB"
    # All six push attempts and their rebase/fetch retries still run; only
    # the jittered backoff between them (2+4+…+12 s plus jitter, ~54 s of
    # waiting on a remote that cannot appear) is not slept.
    sleep() { :; }
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

}

# ───────────────────────────────────────────────────────────────────
# Test 6: NEXT RUN drains the pending queue along with the new row.
# ───────────────────────────────────────────────────────────────────
section_6() {
need_publish_sandbox
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

}

# ───────────────────────────────────────────────────────────────────
# Test 7: make_status_row produces VALID JSON for every failure mode.
# ───────────────────────────────────────────────────────────────────
section_7() {
echo
echo "== Test 7: make_status_row JSON validity for every reason code =="
# Use the function from the real script via shell extraction.
MAKE_LIB="$SANDBOX/make_lib.sh"
{
    echo "HOST=\"TestHost\""
    echo "NIGHTLY_SCRIPT_VERSION=\"test\""
    echo "NIGHTLY_CONFIGURATION=\"Release\""
    awk '/^make_status_row\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh"
} > "$MAKE_LIB"

# 2026-09-30 (release-r1): every row also carries the build configuration.
for reason in "off-main:feature/foo" "dirty-tree:scripts/x.sh,VideoScan/y.swift" "ahead-of-origin:5" "build-rc:65" "ui-runner-hung" "zero-tests-ran:test-rc=70" "failed-tests:12" "unexpected:weird thing"; do
    out=$(bash -c "source $MAKE_LIB; make_status_row failed \"$reason\" true abcd123 2026-06-13 main")
    if echo "$out" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("configuration") == "Release" else 1)' 2>/dev/null; then
        pass "valid JSON with configuration=Release for reason='$reason'"
    else
        fail "INVALID JSON or missing configuration for reason='$reason': $out"
    fi
done

}

# ───────────────────────────────────────────────────────────────────
# Test 7b: a row builder sourced WITHOUT NIGHTLY_CONFIGURATION under set -u
# (exactly how this harness and any future extractor use it) must still emit
# valid JSON — configuration "unknown", never an unbound-variable abort that
# would lose the night's row.
# ───────────────────────────────────────────────────────────────────
section_7b() {
echo
echo "== Test 7b: make_status_row without NIGHTLY_CONFIGURATION under set -u =="
MAKE_LIB_NOCFG="$SANDBOX/make_lib_nocfg.sh"
{
    echo "HOST=\"TestHost\""
    echo "NIGHTLY_SCRIPT_VERSION=\"test\""
    awk '/^make_status_row\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh"
} > "$MAKE_LIB_NOCFG"
NOCFG_OUT=$(bash -c "set -u; source $MAKE_LIB_NOCFG; make_status_row failed build-rc:65 true abcd123 2026-06-13 main" 2>/dev/null)
if echo "$NOCFG_OUT" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("configuration") == "unknown" else 1)' 2>/dev/null; then
    pass "unset NIGHTLY_CONFIGURATION publishes configuration=unknown under set -u"
else
    fail "unset NIGHTLY_CONFIGURATION broke the row under set -u: '$NOCFG_OUT'"
fi

}

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
section_8() {
echo
echo "== Test 8: parse_test_counts fixture counts =="
PARSE_LIB="$SANDBOX/parse_lib.sh"
awk '/^parse_test_counts\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" > "$PARSE_LIB"
# parse_test_counts delegates the crash block to parse_crashed_tests; without
# it the extracted lib would silently leave CRASHED unset.
awk '/^parse_crashed_tests\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" >> "$PARSE_LIB"
FIXTURE_DIR="$SCRIPT_DIR/../tests/fixtures/logs"

# Runs parse_test_counts on a log in a subshell and echoes
# "PASSED|FAILED|SKIPPED|FAILED_NAMES_JSON" for main-shell comparison.
run_parse() {
    # shellcheck disable=SC1090
    ( source "$PARSE_LIB"
      parse_test_counts "$1"
      echo "$PASSED|$FAILED|$SKIPPED|$FAILED_NAMES_JSON" )
}

# Same, but reporting the crash columns: "CRASHED|CRASHED_NAMES_JSON".
run_parse_crashed() {
    # shellcheck disable=SC1090
    ( source "$PARSE_LIB"
      parse_test_counts "$1"
      echo "$CRASHED|$CRASHED_NAMES_JSON" )
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

    # 8d: THE 2026-09-07 REGRESSION SENSOR. Four tests trapped (SIGTRAP) and
    # printed no per-test failure line at all; their names exist only in
    # xcodebuild's "Failing tests:" block. The fixture also carries ONE
    # ordinary failure listed in BOTH places, suite-qualified in the block
    # ("VideoScanTests.PerfTests.performanceRebuildUnderBudget()") and bare on
    # its own failure line — it must count once as a failure and NEVER as a
    # crash, which is what the bare-method-token match is for.
    got=$(run_parse "$FIXTURE_DIR/nightly_excerpt_crash.log")
    want='6|1|4|["performanceRebuildUnderBudget()"]'
    if [ "$got" = "$want" ]; then
        pass "crash fixture: the one real failure still counts exactly once"
    else
        fail "crash fixture counts: got '$got', want '$want'"
    fi
    got=$(run_parse_crashed "$FIXTURE_DIR/nightly_excerpt_crash.log")
    want='4|["HallieAppositionVitalsTests.aDeathOnlyThePeopleTabKnowsMakesTheTensepast()", "HallieAppositionVitalsTests.theAsideSpeaksTheCorrectedYear()", "HallieAppositionVitalsTests.theTwoStoresGenuinelyDisagreeAboutHerYear()", "HallieAppositionVitalsTests.withNoProfilesTheTreesOwnYearStands()"]'
    if [ "$got" = "$want" ]; then
        pass "crash fixture: 4 trapped tests recovered from the Failing-tests block, dual-listed failure excluded"
    else
        fail "crashed-test recovery broke: got '$got', want '$want'"
    fi

    # 8e: a run where every failure announced itself normally must report NO
    # crashes — the new parser may not invent them from an ordinary block.
    for f in nightly_excerpt_green.log nightly_excerpt_one_failure.log; do
        got=$(run_parse_crashed "$FIXTURE_DIR/$f")
        if [ "$got" = "0|[]" ]; then
            pass "$f: no phantom crashes"
        else
            fail "$f invented crashes: got '$got', want '0|[]'"
        fi
    done

    # 8f: GH #208 (2026-10-02). A busy-machine timing miss within 3x is a
    # Swift Testing KNOWN ISSUE. A test that passed with known issues prints
    # "━ Test … passed after … with N known issue(s)." (real swift-testing
    # shape) and must count as PASSED — not vanish from the total — and be
    # counted in KNOWN_ISSUE_TESTS. Its "recorded a known issue" lines, the
    # "━ Suite …" and "━ Test run with …" summaries must not count at all.
    # A test that FAILED with a known issue among its issues is a failure
    # only; the over-3x miss is a real failure and counts exactly once.
    cat > "$SANDBOX/known_issue.log" <<'LOG'
━ Test "settled keystroke" recorded a known issue at CatalogSearchBudgetSensorTests.swift:120:13: Issue recorded
↳ [timing-budget] 100k settled keystroke 'mov' (median of 5): budget 165.0 ms, measured 210.4 ms (1.28×), load 9.1→9.4 on 16 cores, busy (busy) → known-issue
━ Test settledKeystrokeBudgetAndAgreementAt100k() passed after 41.2 seconds with 1 known issue.
━ Test "mapping" recorded a known issue at TimingBudgetTests.swift:147:30: Issue recorded
━ Test "mapping" recorded a known issue at TimingBudgetTests.swift:149:34: Issue recorded
━ Test "mapping: pass records nothing" passed after 0.001 seconds with 2 known issues.
━ Suite "TimingBudget — shared test-budget rule" passed after 0.502 seconds with 2 known issues.
✘ Test "tree walk" recorded an issue at TreeWalkScaleTests.swift:64:13: Issue recorded
↳ [timing-budget] 100k tree walk: budget 8000.0 ms, measured 30100.0 ms (3.76×), load 12.0→12.2 on 16 cores, busy (busy) → fail
✘ Test hundredThousandPeopleWalkAndCheckOffMain() failed after 30.4 seconds with 1 issue.
✘ Test mixedIssues() failed after 1.0 seconds with 2 issues (including 1 known issue).
✔ Test quietIsStrict() passed after 0.001 seconds.
━ Test run with 5 tests in 2 suites passed after 72.0 seconds with 3 known issues.
LOG
    got=$(run_parse "$SANDBOX/known_issue.log")
    want='3|2|0|["hundredThousandPeopleWalkAndCheckOffMain()", "mixedIssues()"]'
    if [ "$got" = "$want" ]; then
        pass "known-issue passes count as PASSED (3), failures count once (2), summaries ignored"
    else
        fail "known-issue fixture: got '$got', want '$want'"
    fi
    got=$( ( source "$PARSE_LIB"; parse_test_counts "$SANDBOX/known_issue.log"; echo "$KNOWN_ISSUE_TESTS" ) )
    if [ "$got" = "2" ]; then
        pass "KNOWN_ISSUE_TESTS=2 (tests that passed with known issues; issue lines and summaries excluded)"
    else
        fail "KNOWN_ISSUE_TESTS: got '$got', want '2'"
    fi
    # Every existing fixture has no known issues: the count must be a plain 0.
    for f in "$FIXTURE_DIR/nightly_excerpt_green.log" "$FIXTURE_DIR/nightly_excerpt_one_failure.log" "$SANDBOX/empty.log"; do
        got=$( ( source "$PARSE_LIB"; parse_test_counts "$f"; echo "$KNOWN_ISSUE_TESTS" ) )
        if [ "$got" = "0" ]; then
            pass "$(basename "$f"): KNOWN_ISSUE_TESTS=0"
        else
            fail "$(basename "$f"): KNOWN_ISSUE_TESTS got '$got', want '0'"
        fi
    done
fi

# 8g: GH #208 — the nightly pins strict timing (both spellings: swift test
# reads the plain name, xcodebuild forwards TEST_RUNNER_<NAME> as <NAME>).
if grep -qx 'export VIDEOSCAN_TIMING_STRICT=1' "$SCRIPT_DIR/nightly_local_tests.sh" &&
   grep -qx 'export TEST_RUNNER_VIDEOSCAN_TIMING_STRICT=1' "$SCRIPT_DIR/nightly_local_tests.sh"; then
    pass "nightly exports VIDEOSCAN_TIMING_STRICT=1 (+ TEST_RUNNER_ form)"
else
    fail "nightly no longer pins strict timing budgets (VIDEOSCAN_TIMING_STRICT=1)"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 9: every nightly row can carry additive person and POI-cycle fields.
# This pins the sensor that keeps the red 0 visible even on build/test failure
# rows, without changing their original status or reason.
# ───────────────────────────────────────────────────────────────────
section_9() {
echo
echo "== Test 9: person metrics merge into failure row =="
need_person_lib
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

}

# ───────────────────────────────────────────────────────────────────
# Test 9b: the Hallie replay lane rides in the same row (2026-09-08) and can
# only ADD fields — it must never touch status, reason or the test counts —
# and with the lane unset the merge still yields a valid, unchanged row.
# ───────────────────────────────────────────────────────────────────
section_9b() {
echo
echo "== Test 9b: Hallie replay lane merges additively and never overwrites the verdict =="
need_person_lib
need_row_fields
if [ -s "$PERSON_LIB" ]; then
    replay_merged=$(
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        HALLIE_REPLAY_JSON='{"hallie_replay_status":"failed","hallie_strict_pass":3,"hallie_strict_fail":1,"status":"ok","failed":0,"reason":"tampered"}'
        source "$PERSON_LIB"
        with_person_metrics '{"status":"failed","reason":"failed-tests:2","failed":2,"total":10}'
    )
    got=$(printf '%s' "$replay_merged" | python3 "$SANDBOX/row_fields.py" status reason failed hallie_replay_status hallie_strict_pass hallie_strict_fail)
    if [ "$got" = "failed|failed-tests:2|2|failed|3|1" ]; then
        pass "replay lane merged; a lane carrying status/reason/failed could NOT overwrite the test verdict"
    else
        fail "replay merge broke the row contract: got '$got'"
    fi
    unset_row=$(
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        source "$PERSON_LIB"
        unset HALLIE_REPLAY_JSON
        with_person_metrics '{"status":"ok","reason":""}'
    )
    got=$(printf '%s' "$unset_row" | python3 "$SANDBOX/row_fields.py" status hallie_replay_status)
    if [ "$got" = "ok|None" ]; then
        pass "with the lane unset the row is valid and unchanged (the not-run default lives in the nightly script)"
    else
        fail "unset replay lane corrupted the row: got '$got'"
    fi
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 10: refresh_person_metrics invokes the collector with and without
# --allow-quality under macOS Bash 3.2 set -u. An empty array expansion must
# not abort before python3 is called.
# ───────────────────────────────────────────────────────────────────
section_10() {
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

}

# ───────────────────────────────────────────────────────────────────
# Test 11: process-group watchdog expires deterministically, without Xcode
# or a wall-clock timeout. The injected deadline waits only for the fixture's
# parent to spawn a TERM-ignoring child, then fires immediately. KILL must
# remove both members of the private process group and return 124.
# ───────────────────────────────────────────────────────────────────
section_11() {
echo
echo "== Test 11: deterministic process-group watchdog timeout =="
need_watchdog_lib
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
    MIXED_CHILD_READY="$SANDBOX/watchdog-mixed-child-ready"
    MIXED_CHILD_TERM_SEEN="$SANDBOX/watchdog-mixed-child-term-seen"
    MIXED_CHILD_PID_FILE="$SANDBOX/watchdog-mixed-child.pid"
    SENTINEL_SIGNAL="$SANDBOX/watchdog-sentinel-signal"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '(' \
        '  trap '\''touch "$WATCHDOG_MIXED_CHILD_TERM_SEEN"'\'' TERM' \
        '  : > "$WATCHDOG_MIXED_CHILD_READY"' \
        '  while :; do sleep 1; done' \
        ') &' \
        'printf "%s\n" "$!" > "$WATCHDOG_MIXED_CHILD_PID_FILE"' \
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
        export VIDEOSCAN_WATCHDOG_TEST_DEADLINE_READY_FILE="$MIXED_CHILD_READY"
        export WATCHDOG_MIXED_CHILD_READY="$MIXED_CHILD_READY"
        export WATCHDOG_MIXED_CHILD_TERM_SEEN="$MIXED_CHILD_TERM_SEEN"
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
       [ -e "$MIXED_CHILD_TERM_SEEN" ] &&
       kill -0 "$SENTINEL_PID" 2>/dev/null &&
       [ ! -e "$SENTINEL_SIGNAL" ] &&
       ! grep -q 'CONTAMINATION:' "$SANDBOX/watchdog-mixed-output.log"; then
        pass "child observed/survived TERM, then escalation killed it; unrelated process untouched"
    else
        fail "mixed TERM escalation broke (rc=$MIXED_RC child_alive=$(kill -0 "$MIXED_CHILD_PID" 2>/dev/null && echo yes || echo no) term_seen=$([ -e "$MIXED_CHILD_TERM_SEEN" ] && echo yes || echo no) sentinel_alive=$(kill -0 "$SENTINEL_PID" 2>/dev/null && echo yes || echo no) contamination=$(grep -c 'CONTAMINATION:' "$SANDBOX/watchdog-mixed-output.log" || true))"
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

}

# ───────────────────────────────────────────────────────────────────
# Test 12: timeout classification has precedence over zero tests, failures,
# and an ordinary xcodebuild rc. This is the row reason the dashboard sees.
# ───────────────────────────────────────────────────────────────────
section_12() {
echo
echo "== Test 12: timeout reason and classification precedence =="
need_watchdog_lib
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

}

# ───────────────────────────────────────────────────────────────────
# Test 12b: THE 2026-09-07 FALSE-GREEN SENSOR. A crashing test host prints no
# failure line, so `failed` stays 0 while xcodebuild exits 65. Before this,
# classify_nightly_test_result read test_rc only in the total-eq-0 branch and
# published status=ok / failed=0 for a run that died five times.
#
# The ladder under test, in order:
#   crashed>0            → failed  (outranks the ui-runner-hung excuse)
#   ui_runner_hung       → failed  (incomplete execution, never green)
#   test_rc != 0         → failed  (nothing explained it; fail closed)
# ───────────────────────────────────────────────────────────────────
section_12b() {
echo
echo "== Test 12b: a crashed host and an unexplained rc can never publish green =="
need_watchdog_lib
classify_case() {
    # shellcheck disable=SC1090
    ( source "$WATCHDOG_LIB"
      classify_nightly_test_result "$@"
      printf '%s|%s' "$STATUS" "$REASON" )
}

#            timed_out timeout total failed ui_hung rc  crashed
INCIDENT=$(classify_case  false 900 6886    0      false 65  4)
UNEXPLAINED=$(classify_case false 900 6886  0      false 65  0)
UI_HANG=$(classify_case    false 900 6886   0      true  65  0)
UI_HANG_CRASH=$(classify_case false 900 6886 0     true  65  2)
CLEAN=$(classify_case      false 900 6886   0      false 0   0)
COUNTED_WINS=$(classify_case false 900 6886 3      false 65  4)
LEGACY_6ARG=$(classify_case false 900 6886  0      false 0)

if [ "$INCIDENT" = "failed|crashed-tests:4" ]; then
    pass "2026-09-07 incident: 4 trapped tests + rc=65 + failed=0 publishes FAILED, not ok"
else
    fail "the false-green hole is still open: got '$INCIDENT', want 'failed|crashed-tests:4'"
fi
if [ "$UNEXPLAINED" = "failed|test-rc:65" ]; then
    pass "an unexplained nonzero test rc fails closed"
else
    fail "unexplained rc does not fail closed: got '$UNEXPLAINED'"
fi
if [ "$UI_HANG" = "failed|ui-runner-hung" ]; then
    pass "a runner hang cannot waive an incomplete run into green"
else
    fail "UI-runner-hang classification regressed: got '$UI_HANG', want 'failed|ui-runner-hung'"
fi
if [ "$UI_HANG_CRASH" = "failed|crashed-tests:2" ]; then
    pass "a real crash outranks the ui-runner-hung excuse"
else
    fail "a hung UI runner masked a crash: got '$UI_HANG_CRASH'"
fi
if [ "$CLEAN" = "ok|" ]; then
    pass "a genuinely clean run still publishes ok with an empty reason"
else
    fail "clean-run classification regressed: got '$CLEAN', want 'ok|'"
fi
if [ "$COUNTED_WINS" = "failed|failed-tests:3" ]; then
    pass "counted failures keep precedence over the crash rung"
else
    fail "failure precedence regressed: got '$COUNTED_WINS'"
fi
if [ "$LEGACY_6ARG" = "ok|" ]; then
    pass "the 7th argument is optional — 6-arg callers still classify"
else
    fail "adding crashed broke 6-arg callers under set -u: got '$LEGACY_6ARG'"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 13: a test timeout publishes its partial counts immediately with null
# coverage and the pre-build readiness snapshot. Neither xccov nor the live
# person evaluator may run before that durable-row path returns.
# ───────────────────────────────────────────────────────────────────
section_13() {
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
    KNOWN_ISSUE_TESTS=1   # GH #208: one of the 4 passes carried a known issue
    ELAPSED=9
    STATUS="failed"
    REASON="test-timeout:7s"
    NIGHTLY_SCRIPT_VERSION="test"
    NIGHTLY_CONFIGURATION="Release"
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
    row["configuration"], str(row.get("known_issue_tests")),
]))
PY
)
if [ "$TIMEOUT_PUBLISH_RC" -eq 0 ] &&
   [ "$TIMEOUT_ROW_SUMMARY" = "failed|test-timeout:7s|4|1|2|7|None|not-configured|0|Release|1" ] &&
   [ ! -e "$OPTIONAL_WORK_FILE" ]; then
    pass "timeout row retains partial counts/readiness and bypasses coverage + live evaluator"
else
    fail "timeout publication broke (rc=$TIMEOUT_PUBLISH_RC row=$TIMEOUT_ROW_SUMMARY optional=$([ -e "$OPTIONAL_WORK_FILE" ] && echo ran || echo skipped))"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 14 (2026-10-18): the VideoScanCore package lane. A fake lane script
# (VIDEOSCAN_NIGHTLY_CORE_LANE; since 2026-11-20 the lane runs
# scripts/core_lane.py, two phases, not `swift test --no-parallel` — the real
# script is tested by tests/test_core_lane.py) prints a fixture log and exits
# with a chosen rc, so the REAL run_core_package_tests (watchdog,
# parse_test_counts, classification, row builder) runs end to end without
# compiling anything. Pins: the Release configuration, package and scratch
# paths reach core_lane.py and nothing serializes the whole lane again; the
# two phases' counts are summed; a phase that did not run its plan is red by
# name; counts use the app lane's rules; a failure, a
# silent crash (rc only) and a build error (zero tests) each publish red; the
# Core verdict turns a green app row red and never rewrites a red one; only
# core_* keys merge into the row; the lane runs BEFORE the app build.
# ───────────────────────────────────────────────────────────────────
section_14() {
echo
echo "== Test 14: VideoScanCore package lane =="
need_core_lib
need_row_fields
need_wiring_lines
CORE_BIN="$SANDBOX/core-bin"
mkdir -p "$CORE_BIN"
cat > "$CORE_BIN/core_lane.py" <<'CFL'
import os, sys, time
with open(os.environ["CORE_FAKE_ARGS"], "w") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
with open(os.environ["CORE_FAKE_LOG"]) as f:
    sys.stdout.write(f.read())
sys.stdout.flush()
if os.environ.get("CORE_FAKE_HANG"):
    time.sleep(float(os.environ["CORE_FAKE_HANG"]))
sys.exit(int(os.environ["CORE_FAKE_RC"]))
CFL
# A `swift` that fails loudly: the nightly itself must no longer call it for
# the Core lane (core_lane.py owns the build and both phases).
printf '%s\n' '#!/bin/sh' 'echo "nightly called swift $*" >> "$CORE_FAKE_ARGS.swift"' 'exit 97' > "$CORE_BIN/swift"
chmod +x "$CORE_BIN/swift"
ZW=$(printf '\342\200\213')   # U+200B, the indent Swift Testing really prints
cat > "$SANDBOX/core-green.log" <<CGL
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testOpenCreatesSchema]' passed (0.010 seconds).
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testCommitIsAtomic]' passed (0.020 seconds).
Test Suite 'All tests' passed at 2026-10-18 02:10:00.000.
${ZW}✔ Test importRoundTrip() passed after 0.010 seconds.
✔ Test commitHighWater() passed after 0.020 seconds.
━ Test loadQuarantine() passed after 0.030 seconds with 1 known issue.
✔ Test run with 3 tests in 1 suite passed after 0.100 seconds.
CGL
# The real shape since 2026-11-20: two phases in one log, each with its own
# run summary and core_lane.py's own lines (which are not tests).
cat > "$SANDBOX/core-two-phase.log" <<CTL
core-lane: phase A (parallel, timing not strict): 3 tests planned (1 XCTest + 2 Swift Testing)
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testOpenCreatesSchema]' passed (0.010 seconds).
${ZW}✔ Test importRoundTrip() passed after 0.010 seconds.
➜ Test needsFfmpeg() skipped.
✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.
core-lane: phase B (serial, quiet machine, VIDEOSCAN_TIMING_STRICT=1): 3 tests planned (1 XCTest + 2 Swift Testing)
Test Case '-[VideoScanCoreTests.GedcomPerfBaselineTests testMemory100k]' passed (2.010 seconds).
✔ Test hundredThousandAdvances() passed after 20.000 seconds.
━ Test oneHundredThousandRowsLoadWithinBudget() passed after 3.030 seconds with 1 known issue.
━ Test run with 2 tests in 1 suite passed after 23.100 seconds with 1 known issue.
core-lane: phase A (parallel, timing not strict): 2 passed / 0 failed / 1 skipped — 3 of 3 planned, 0 with known issues, 1 s, largest test process so far 1800 MB
core-lane: phase B (serial, quiet machine, strict): 3 passed / 0 failed / 0 skipped — 3 of 3 planned, 1 with known issues, 25 s
core-lane: total 5 passed / 0 failed / 1 skipped — 6 of 6 planned, 26 s → GREEN
CTL
# 2026-11-21: phase B as serial strands. A test that failed beside the other
# strands has NO verdict line there (core_lane.py replaces it with its own
# note) and exactly one from the alone pass; the AMBER line names it.
cat > "$SANDBOX/core-strands.log" <<CSL
core-lane: phase A (parallel, timing not strict): 3 tests planned (1 XCTest + 2 Swift Testing)
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testOpenCreatesSchema]' passed (0.010 seconds).
${ZW}✔ Test importRoundTrip() passed after 0.010 seconds.
➜ Test needsFfmpeg() skipped.
✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.
core-lane: phase B (serial, quiet machine, VIDEOSCAN_TIMING_STRICT=1): 3 tests planned (1 XCTest + 2 Swift Testing)
core-lane: phase B runs as 2 serial strands (--quiet-jobs 4); a test whose only failures beside the others are budget judgements is run again alone before it is judged — strand 1: 2 tests, ~22 s recorded; strand 2: 1 tests, ~3 s recorded
Test Case '-[VideoScanCoreTests.GedcomPerfBaselineTests testMemory100k]' passed (2.010 seconds).
✘ Test hundredThousandAdvances() recorded an issue at AdvanceTests.swift:9:5: Issue recorded: [quiet-budget] 31.0 s is over the 30 s budget
core-lane: strand 1: failed beside the other strands — to be run again alone: hundredThousandAdvances()
✘ Test run with 1 test in 1 suite failed after 31.100 seconds with 1 issue.
━ Test oneHundredThousandRowsLoadWithinBudget() passed after 3.030 seconds with 1 known issue.
━ Test run with 1 test in 1 suite passed after 3.100 seconds with 1 known issue.
core-lane: phase B: every strand has ended; running 1 test(s) again ALONE (one at a time, nothing else of the lane running)
✔ Test hundredThousandAdvances() passed after 20.000 seconds.
✔ Test run with 1 test in 1 suite passed after 20.100 seconds.
core-lane: phase A (parallel, timing not strict): 2 passed / 0 failed / 1 skipped — 3 of 3 planned, 0 with known issues, 1 s, largest test process so far 1800 MB
core-lane: phase B (serial, quiet machine, strict): 3 passed / 0 failed / 0 skipped — 3 of 3 planned, 1 with known issues, 54 s, 2 strands, 1 passed alone after failing beside the others
core-lane: AMBER — phase B (serial, quiet machine): passed alone after failing beside 1 other strand: VideoScanCoreTests.AdvanceTests/hundredThousandAdvances()
core-lane: total 5 passed / 0 failed / 1 skipped — 6 of 6 planned, 55 s → GREEN
CSL
cat > "$SANDBOX/core-phase-short.log" <<CPL
core-lane: phase A (parallel, timing not strict): 3 tests planned (1 XCTest + 2 Swift Testing)
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testOpenCreatesSchema]' passed (0.010 seconds).
✔ Test importRoundTrip() passed after 0.010 seconds.
✔ Test commitHighWater() passed after 0.020 seconds.
core-lane: phase B (serial, quiet machine, VIDEOSCAN_TIMING_STRICT=1): 3 tests planned (1 XCTest + 2 Swift Testing)
core-lane: phase A (parallel, timing not strict): 3 passed / 0 failed / 0 skipped — 3 of 3 planned, 0 with known issues, 1 s, largest test process so far 1800 MB
core-lane: phase B (serial, quiet machine, strict): 0 passed / 0 failed / 0 skipped — 0 of 3 planned, 0 with known issues, 0 s
core-lane: total 3 passed / 0 failed / 0 skipped — 3 of 6 planned, 1 s → RED
core-lane: RED — phase B (serial, quiet machine): XCTest ran ZERO of its 1 tests
core-lane: RED — phase B (serial, quiet machine): Swift Testing ran ZERO of its 2 tests
CPL
cat > "$SANDBOX/core-red.log" <<CRL
Test Case '-[VideoScanCoreTests.GRDBCatalogRepositoryTests testOpenCreatesSchema]' passed (0.010 seconds).
✔ Test importRoundTrip() passed after 0.010 seconds.
✘ Test commitHighWater() recorded an issue at CatalogCommitTests.swift:9:5: Expectation failed: x failed after y
✘ Test commitHighWater() failed after 0.020 seconds with 1 issue.
✘ Test run with 2 tests in 1 suite failed after 0.100 seconds with 1 issue.
CRL
cat > "$SANDBOX/core-build-error.log" <<CBL
error: emit-module command failed with exit code 1 (use -v to see invocation)
CBL
run_core_case() {   # log rc app_status app_reason → status|reason|core_*… line
    (
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        log() { [ -n "${CORE_CASE_LOG:-}" ] && printf '%s\n' "$*" >> "$CORE_CASE_LOG"; :; }
        export PATH="$CORE_BIN:$PATH"
        export VIDEOSCAN_NIGHTLY_CORE_LANE="${VIDEOSCAN_NIGHTLY_CORE_LANE_UNDER_TEST:-$CORE_BIN/core_lane.py}"
        export CORE_FAKE_LOG="$1" CORE_FAKE_RC="$2" CORE_FAKE_ARGS="$SANDBOX/core-args.txt"
        NIGHTLY_CONFIGURATION="Release"
        NIGHTLY_CORE_LOG="$SANDBOX/core-run.log"
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        # The lane copies swift's log into the nightly log (stdout); not here.
        run_core_package_tests "/pkg/VideoScanCore" "/caches/core-build" > /dev/null
        STATUS="$3"; REASON="$4"
        apply_core_package_verdict
        row=$(with_person_metrics "{\"status\":\"$STATUS\",\"reason\":\"$REASON\",\"passed\":7,\"total\":7}")
        printf '%s' "$row" | python3 -c '
import json, sys
r = json.load(sys.stdin)
keys = ["status", "reason", "passed", "total", "core_status", "core_reason", "core_passed",
        "core_failed", "core_skipped", "core_total", "core_known_issue_tests", "core_rc",
        "core_configuration", "core_failed_names"]
if "'"${CORE_CASE_AMBER:-}"'":
    keys += ["core_amber_count", "core_amber_names"]
print("|".join(json.dumps(r.get(k)) if isinstance(r.get(k), list) else str(r.get(k)) for k in keys))'
    )
}
if ! grep -q '^run_core_package_tests()' "$CORE_LIB"; then
    fail "run_core_package_tests could not be extracted from nightly_local_tests.sh"
else
    got=$(run_core_case "$SANDBOX/core-green.log" 0 ok "")
    want='ok||7|7|ok||5|0|0|5|1|0|release|[]'
    [ "$got" = "$want" ] && pass "green Core lane: 2 XCTest + 3 Swift Testing (1 known issue) counted, row stays green" \
        || fail "green Core lane: got '$got' want '$want'"
    args=$(cat "$SANDBOX/core-args.txt" 2>/dev/null)
    [ "$args" = "run --package-path /pkg/VideoScanCore -c release --scratch-path /caches/core-build" ] \
        && pass "core_lane.py run gets the package path, -c release and the private scratch path" \
        || fail "core_lane.py arguments changed: '$args'"
    [ ! -e "$SANDBOX/core-args.txt.swift" ] \
        && pass "the nightly no longer runs swift for the Core lane itself (core_lane.py owns the build and both phases)" \
        || fail "the nightly called swift directly: $(cat "$SANDBOX/core-args.txt.swift")"
    # Without the override the lane is the script beside the nightly, found
    # from the package path (<repo>/VideoScan/VideoScanCore → <repo>/scripts).
    grep -q 'core_lane="${VIDEOSCAN_NIGHTLY_CORE_LANE:-$package_path/../../scripts/core_lane.py}"' "$SCRIPT_DIR/nightly_local_tests.sh" \
        && [ -f "$SCRIPT_DIR/core_lane.py" ] \
        && pass "the default lane is scripts/core_lane.py of the checkout under test" \
        || fail "the nightly's default Core lane script moved or is missing"
    # A checkout from before core_lane.py (the testbed can test any commit) has
    # no quiet-machine marks to split on: it gets the old single serial pass,
    # and only it.
    got=$(VIDEOSCAN_NIGHTLY_CORE_LANE_UNDER_TEST="$SANDBOX/no-such-core_lane.py" run_core_case "$SANDBOX/core-green.log" 97 ok "")
    args=$(cat "$SANDBOX/core-args.txt.swift" 2>/dev/null)
    rm -f "$SANDBOX/core-args.txt.swift"
    [ "$args" = "nightly called swift test --package-path /pkg/VideoScanCore -c release --scratch-path /caches/core-build --no-parallel" ] \
        && pass "a checkout without scripts/core_lane.py still gets swift test --no-parallel (one serial pass)" \
        || fail "fallback for a checkout without core_lane.py: swift got '$args' (row '$got')"
    # Two phases in one log: the row is their SUM, and the per-phase lines
    # reach the nightly log.
    got=$(CORE_CASE_LOG="$SANDBOX/core-case.log"; export CORE_CASE_LOG; : > "$CORE_CASE_LOG"; run_core_case "$SANDBOX/core-two-phase.log" 0 ok "")
    want='ok||7|7|ok||5|0|1|6|1|0|release|[]'
    [ "$got" = "$want" ] && pass "two phases: 2+1 skipped (parallel) and 3 (serial, 1 known issue) sum to 5p/0f/1s of 6" \
        || fail "two-phase Core lane: got '$got' want '$want'"
    grep -q 'core-lane: phase B (serial, quiet machine, strict): 3 passed / 0 failed / 0 skipped — 3 of 3 planned' "$SANDBOX/core-case.log" \
        && grep -q 'core-lane: phase A (parallel, timing not strict): 2 passed' "$SANDBOX/core-case.log" \
        && pass "each phase's counts and seconds are logged on their own line" \
        || fail "the per-phase lines did not reach the nightly log: $(cat "$SANDBOX/core-case.log")"
    # Phase B in strands (2026-11-21): a test that failed beside the other
    # strands and passed alone is ONE passed test in the row (its withheld
    # failing line is not a verdict, the issue line never was), the row is
    # green, and the AMBER line that names it reaches the nightly log.
    got=$(CORE_CASE_LOG="$SANDBOX/core-case.log"; export CORE_CASE_LOG; : > "$CORE_CASE_LOG"; CORE_CASE_AMBER=1 run_core_case "$SANDBOX/core-strands.log" 0 ok "")
    want='ok||7|7|ok||5|0|1|6|1|0|release|[]|1|["VideoScanCoreTests.AdvanceTests/hundredThousandAdvances()"]'
    [ "$got" = "$want" ] && pass "strands: failed beside / passed alone is counted once, as passed: 5p/0f/1s of 6, row ok" \
        || fail "strands Core lane: got '$got' want '$want'"
    grep -q 'core-lane: AMBER — phase B (serial, quiet machine): passed alone after failing beside 1 other strand: VideoScanCoreTests.AdvanceTests/hundredThousandAdvances()' "$SANDBOX/core-case.log" \
        && grep -q '2 strands, 1 passed alone after failing beside the others' "$SANDBOX/core-case.log" \
        && pass "the test that passed only alone is named in the nightly log (AMBER), with the count on the phase line" \
        || fail "the AMBER line did not reach the nightly log: $(cat "$SANDBOX/core-case.log")"
    # …and a run with no AMBER says so in the row: 0 and an empty list, never a missing field.
    got=$(CORE_CASE_AMBER=1 run_core_case "$SANDBOX/core-two-phase.log" 0 ok "")
    case "$got" in *'|release|[]|0|[]') pass "a run with no AMBER has core_amber_count 0 and an empty core_amber_names" ;;
        *) fail "amber fields on a clean run: '$got'" ;; esac
    # A phase that ran zero of its plan: core_lane.py exits 2 with no failed
    # test. The row is red BY NAME, not a bare rc.
    got=$(CORE_CASE_LOG="$SANDBOX/core-case.log"; export CORE_CASE_LOG; : > "$CORE_CASE_LOG"; run_core_case "$SANDBOX/core-phase-short.log" 2 ok "")
    case "$got" in
        "failed|core-phase-count-mismatch|7|7|failed|phase-count-mismatch|3|0|0|3|"*)
            grep -q 'core-lane: RED — phase B (serial, quiet machine): Swift Testing ran ZERO of its 2 tests' "$SANDBOX/core-case.log" \
                && pass "a phase that ran zero of its plan is red (phase-count-mismatch) and the log names the phase" \
                || fail "phase-count red did not log which phase: $(cat "$SANDBOX/core-case.log")" ;;
        *) fail "a serial phase that ran nothing: got '$got'" ;;
    esac
    # 2026-11-20: the lane's environment sampler naps in a child `sleep 300`.
    # Killing the sampler left that sleep alive, holding the caller's output,
    # so whoever reads the nightly's output waited up to five minutes after
    # the lane returned (here: pytest, 291 of this self-test's 365 s; on the
    # fleet: an ssh session running the on-demand nightly). Nothing the lane
    # started may still hold its output once it has returned.
    HOLD_OUT="$SANDBOX/core-output-holders.txt"
    ( run_core_case "$SANDBOX/core-green.log" 0 ok "" ) > "$HOLD_OUT" 2>&1
    holders=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        holders=$(lsof -t -- "$HOLD_OUT" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
        [ -z "$holders" ] && break
        sleep 0.2
    done
    if [ -z "$holders" ]; then
        pass "the Core lane leaves nothing holding its caller's output when it returns"
    else
        fail "the Core lane left PID(s) $holders holding its output: $(ps -o command= -p "${holders// /,}" | tr '\n' ';')"
        # Ours (spawned by this case): stop them so this red run ends now.
        kill $holders 2>/dev/null || true
    fi
    got=$(run_core_case "$SANDBOX/core-red.log" 1 ok "")
    want='failed|core-failed-tests:1|7|7|failed|failed-tests:1|2|1|0|3|0|1|release|["commitHighWater()"]'
    [ "$got" = "$want" ] && pass "a Core failure turns a green app row red (core-failed-tests:1) and names the test" \
        || fail "red Core lane: got '$got' want '$want'"
    got=$(run_core_case "$SANDBOX/core-green.log" 134 ok "")
    case "$got" in
        "failed|core-test-rc:134|"*"|ok"*) fail "crashed Core lane published core ok: '$got'" ;;
        "failed|core-test-rc:134|7|7|failed|test-rc:134|5|0|0|5|"*) pass "a Core run that dies without a failure line (rc 134) fails closed" ;;
        *) fail "crashed Core lane: got '$got'" ;;
    esac
    got=$(run_core_case "$SANDBOX/core-build-error.log" 1 ok "")
    case "$got" in
        "failed|core-zero-tests-ran:test-rc=1|7|7|failed|zero-tests-ran:test-rc=1|0|0|0|0|"*) pass "a Core build error (zero tests) fails closed" ;;
        *) fail "Core build error: got '$got'" ;;
    esac
    got=$(run_core_case "$SANDBOX/core-red.log" 1 failed "failed-tests:2")
    case "$got" in
        "failed|failed-tests:2|"*) pass "an already-red app verdict keeps its own reason; core_* still say what Core did" ;;
        *) fail "app reason was rewritten by the Core lane: '$got'" ;;
    esac
    # 2026-10-22: a hung Core test is stopped by the output-stall watchdog
    # in seconds (here 2 s; the nightly uses 900 s), not at the deadline,
    # the row says test-stall, and the group was sampled before the kill.
    cat > "$SANDBOX/core-hang.log" <<CHL
Test Case '-[VideoScanCoreTests.FileBackedCatalogSourceTests testMissingCatalogYieldsEmpty]' passed (0.000 seconds).
Test Case '-[VideoScanCoreTests.FileBackedCatalogSourceTests testReachabilityIsARuntimeCheckInsideTheImpl]' started.
CHL
    hang_start=$(date +%s)
    got=$(
        export CORE_FAKE_HANG=600
        export VIDEOSCAN_NIGHTLY_CORE_TIMEOUT_SECONDS=300
        export VIDEOSCAN_NIGHTLY_CORE_STALL_SECONDS=2
        export NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS=1 VIDEOSCAN_NIGHTLY_TERM_GRACE_SECONDS=1
        export VIDEOSCAN_NIGHTLY_CORE_SAMPLE_FILE="$SANDBOX/core-hang-sample.txt"
        run_core_case "$SANDBOX/core-hang.log" 0 ok ""
    )
    hang_elapsed=$(( $(date +%s) - hang_start ))
    case "$got" in
        "failed|core-test-stall:2s|7|7|failed|test-stall:2s|1|0|0|1|"*)
            if [ "$hang_elapsed" -lt 120 ] && grep -q "watchdog stall:2s stop" "$SANDBOX/core-hang-sample.txt" 2>/dev/null; then
                pass "a hung Core test is stopped by the stall watchdog in ${hang_elapsed}s (not the deadline), reads test-stall, stacks sampled"
            else
                fail "stall stop took ${hang_elapsed}s or left no sample file"
            fi ;;
        *) fail "hung Core lane: got '$got'" ;;
    esac
    notrun=$(
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        STATUS="ok"; REASON=""
        apply_core_package_verdict
        printf '%s|%s' "$STATUS" "$REASON"
    )
    [ "$notrun" = "failed|core-lane-not-reached" ] && pass "a Core lane that never ran cannot leave the row green" \
        || fail "not-run Core lane: got '$notrun'"
    tampered=$(
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        CORE_TEST_JSON='{"core_status":"ok","status":"ok","reason":"tampered","failed":0}'
        with_person_metrics '{"status":"failed","reason":"failed-tests:2","failed":2}' \
            | python3 "$SANDBOX/row_fields.py" status reason failed core_status
    )
    [ "$tampered" = "failed|failed-tests:2|2|ok" ] && pass "only core_* keys merge; the lane cannot overwrite status/reason/counts" \
        || fail "Core merge broke the row contract: '$tampered'"
fi
CORE_CALL_LINE=$(grep -n '^run_core_package_tests "\$REPO/VideoScan/VideoScanCore"' "$SCRIPT_DIR/nightly_local_tests.sh" | cut -d: -f1)
VERDICT_LINE=$(grep -n '^apply_core_package_verdict$' "$SCRIPT_DIR/nightly_local_tests.sh" | cut -d: -f1)
if [ -n "$CORE_CALL_LINE" ] && [ -n "$BUILD_CALL_LINE" ] && [ "$CORE_CALL_LINE" -lt "$BUILD_CALL_LINE" ] &&
   [ -n "$VERDICT_LINE" ] && [ -n "$CLASSIFY_LINE" ] && [ "$VERDICT_LINE" -gt "$CLASSIFY_LINE" ]; then
    pass "the Core lane runs before the app build and its verdict folds in after classification"
else
    fail "Core lane wiring moved (core=$CORE_CALL_LINE build=$BUILD_CALL_LINE classify=$CLASSIFY_LINE verdict=$VERDICT_LINE)"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 14b (2026-11-05): the MODEL lane. The M5 Ultra ran a week without the
# Whisper weights and every test used a fake. A fake repo (check_models.py
# printing a chosen answer, venv/bin/python printing a chosen pytest summary)
# drives the REAL run_model_smoke_lane. Pins: all present + smoke green keeps
# the row green; a missing model, a red smoke, a smoke that ran zero tests and
# a lane that never ran each turn a green row red (model-smoke-<why>); a red
# app verdict keeps its reason; only model_smoke_* keys merge; the lane runs
# before the app build and its verdict folds in after classification.
# ───────────────────────────────────────────────────────────────────
section_14b() {
echo
echo "== Test 14b: model lane (required weights + real-model audio smoke) =="
need_core_lib
need_row_fields
need_wiring_lines
MS_REPO="$SANDBOX/ms-repo"
mkdir -p "$MS_REPO/scripts" "$MS_REPO/venv/bin" "$MS_REPO/tests"
cat > "$MS_REPO/scripts/check_models.py" <<'MSC'
import os, sys
print(os.environ["MS_FAKE_MODELS"])
sys.exit(int(os.environ["MS_FAKE_MODELS_RC"]))
MSC
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$MS_FAKE_ARGS"' 'printf "%s\n" "$MS_FAKE_SMOKE"' 'exit "$MS_FAKE_SMOKE_RC"' > "$MS_REPO/venv/bin/python"
chmod +x "$MS_REPO/venv/bin/python"
MS_ALL='{"host":"T","ok":true,"models":[],"missing":[]}'
MS_ONE='{"host":"T","ok":false,"models":[],"missing":["mlx-community/whisper-medium-mlx-q4 (hf-hub)"]}'
run_model_case() {   # models_json models_rc smoke_text smoke_rc app_status app_reason → fields
    (
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        log() { :; }
        export MS_FAKE_MODELS="$1" MS_FAKE_MODELS_RC="$2" MS_FAKE_SMOKE="$3" MS_FAKE_SMOKE_RC="$4"
        export MS_FAKE_ARGS="$SANDBOX/ms-args.txt"
        NIGHTLY_MODEL_SMOKE_LOG="$SANDBOX/ms-run.log"
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        run_model_smoke_lane "$MS_REPO" > /dev/null
        STATUS="$5"; REASON="$6"
        apply_model_smoke_verdict
        with_person_metrics "{\"status\":\"$STATUS\",\"reason\":\"$REASON\",\"passed\":7,\"total\":7}" \
            | python3 "$SANDBOX/row_fields.py" status reason passed model_smoke_status model_smoke_reason \
                model_smoke_missing model_smoke_audio_passed model_smoke_audio_failed
    )
}
if ! grep -q '^run_model_smoke_lane()' "$CORE_LIB"; then
    fail "run_model_smoke_lane could not be extracted from nightly_local_tests.sh"
else
    got=$(run_model_case "$MS_ALL" 0 "5 passed in 4.08s" 0 ok "")
    [ "$got" = "ok||7|ok||[]|5|0" ] && pass "all models present + smoke 5/5: the row stays green" \
        || fail "green model lane: got '$got'"
    args=$(cat "$SANDBOX/ms-args.txt" 2>/dev/null)
    [ "$args" = "-m pytest -q -p no:cacheprovider -rA $MS_REPO/tests/test_audio_transcribe_smoke.py" ] \
        && pass "the smoke runs the real-model pytest from the checkout with the repo venv" \
        || fail "smoke arguments changed: '$args'"
    got=$(run_model_case "$MS_ONE" 1 "2 failed, 3 passed in 3s" 1 ok "")
    [ "$got" = "failed|model-smoke-missing:1|7|failed|missing:1|['mlx-community/whisper-medium-mlx-q4 (hf-hub)']|3|2" ] \
        && pass "a missing model turns a green row red (model-smoke-missing:1) and names it" \
        || fail "missing model: got '$got'"
    got=$(run_model_case "$MS_ALL" 0 "2 failed, 3 passed in 3s" 1 ok "")
    [ "$got" = "failed|model-smoke-audio-failed:2|7|failed|audio-failed:2|[]|3|2" ] \
        && pass "a red audio smoke with every model present still turns the row red" \
        || fail "red smoke: got '$got'"
    got=$(run_model_case "$MS_ALL" 0 "no tests ran in 0.01s" 5 ok "")
    [ "$got" = "failed|model-smoke-audio-zero-tests:rc=5|7|failed|audio-zero-tests:rc=5|[]|0|0" ] \
        && pass "a smoke that ran zero tests is red, never green" \
        || fail "zero-test smoke: got '$got'"
    got=$(run_model_case "$MS_ONE" 1 "5 passed in 4s" 0 failed "failed-tests:2")
    case "$got" in
        "failed|failed-tests:2|7|failed|missing:1|"*) pass "an already-red app verdict keeps its reason; model_smoke_* still say why" ;;
        *) fail "app reason was rewritten by the model lane: '$got'" ;;
    esac
    notrun=$(
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        STATUS="ok"; REASON=""
        MODEL_SMOKE_STATUS="not-run"; MODEL_SMOKE_REASON="lane-not-reached"
        apply_model_smoke_verdict
        printf '%s|%s' "$STATUS" "$REASON"
    )
    [ "$notrun" = "failed|model-smoke-lane-not-reached" ] && pass "a model lane that never ran cannot leave the row green" \
        || fail "not-run model lane: got '$notrun'"
    tampered=$(
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        PERSON_METRICS_JSON='{"person_eval_status":"not-configured"}'
        MODEL_SMOKE_JSON='{"model_smoke_status":"ok","status":"ok","reason":"tampered","failed":0}'
        with_person_metrics '{"status":"failed","reason":"failed-tests:2","failed":2}' \
            | python3 "$SANDBOX/row_fields.py" status reason failed model_smoke_status
    )
    [ "$tampered" = "failed|failed-tests:2|2|ok" ] && pass "only model_smoke_* keys merge; the lane cannot overwrite status/reason/counts" \
        || fail "model lane merge broke the row contract: '$tampered'"
fi
MS_CALL_LINE=$(grep -n '^run_model_smoke_lane "\$REPO"$' "$SCRIPT_DIR/nightly_local_tests.sh" | cut -d: -f1)
MS_VERDICT_LINE=$(grep -n '^apply_model_smoke_verdict$' "$SCRIPT_DIR/nightly_local_tests.sh" | cut -d: -f1)
if [ -n "$MS_CALL_LINE" ] && [ -n "$BUILD_CALL_LINE" ] && [ "$MS_CALL_LINE" -lt "$BUILD_CALL_LINE" ] &&
   [ -n "$MS_VERDICT_LINE" ] && [ -n "$CLASSIFY_LINE" ] && [ "$MS_VERDICT_LINE" -gt "$CLASSIFY_LINE" ]; then
    pass "the model lane runs before the app build and its verdict folds in after classification"
else
    fail "model lane wiring moved (lane=$MS_CALL_LINE build=$BUILD_CALL_LINE classify=$CLASSIFY_LINE verdict=$MS_VERDICT_LINE)"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 15 (2026-10-21, GH #360 item 5): machine setup is the machine, not a
# test result. Fake automationmodetool / xcodebuild / xcrun drive the REAL
# check_machine_setup; the M5's real 10/21 log line drives the REAL
# apply_test_host_start_diagnosis. Pins: each failing check names itself as
# machine-setup:<what> (first failure wins); a ready Mac passes; a test host
# that never connected with ZERO tests is machine-setup:test-host-hung (with
# the diagnosis line), while a timeout, a real failure or a run with tests is
# never rewritten; the preflight runs before any build; UI tests stay skipped.
# ───────────────────────────────────────────────────────────────────
section_15() {
echo
echo "== Test 15: machine-setup preflight and test-host-hang diagnosis =="
need_watchdog_lib
MS_BIN="$SANDBOX/ms-bin"
mkdir -p "$MS_BIN"
printf '%s\n' '#!/bin/sh' 'echo "Automation Mode is disabled."' 'echo "This device DOES NOT REQUIRE user authentication to enable Automation Mode."' > "$MS_BIN/amt-ok"
printf '%s\n' '#!/bin/sh' 'echo "Automation Mode is disabled."' 'echo "This device REQUIRES user authentication to enable Automation Mode."' > "$MS_BIN/amt-password"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$MS_BIN/ok"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$MS_BIN/bad"
chmod +x "$MS_BIN"/*
setup_case() {
    # args: automationmodetool xcodebuild xcrun -> "<reason>|<log>"
    ( # shellcheck disable=SC1090
      source "$WATCHDOG_LIB"
      log() { echo "$*" >> "$SANDBOX/ms-case.log"; }
      : > "$SANDBOX/ms-case.log"
      NIGHTLY_AUTOMATIONMODETOOL="$MS_BIN/$1" NIGHTLY_XCODEBUILD="$MS_BIN/$2" NIGHTLY_XCRUN="$MS_BIN/$3"
      export NIGHTLY_AUTOMATIONMODETOOL NIGHTLY_XCODEBUILD NIGHTLY_XCRUN
      check_machine_setup
      printf '%s|%s' "$MACHINE_SETUP_REASON" "$(tr '\n' ' ' < "$SANDBOX/ms-case.log")" )
}
got=$(setup_case amt-ok ok ok)
case "$got" in
    "|Machine setup: automation mode, Xcode first launch and Metal toolchain all ready. ") pass "a ready Mac passes the machine preflight" ;;
    *) fail "ready Mac: got '$got'" ;;
esac
got=$(setup_case amt-password ok ok)
case "$got" in
    "machine-setup:automation-mode|"*"enable-automationmode-without-authentication"*) pass "automation mode behind a password is machine-setup:automation-mode, with the fix" ;;
    *) fail "automation-mode check: got '$got'" ;;
esac
got=$(setup_case amt-ok bad ok)
case "$got" in
    "machine-setup:xcode-first-launch|"*"xcodebuild -runFirstLaunch"*) pass "Xcode first launch not done is machine-setup:xcode-first-launch" ;;
    *) fail "first-launch check: got '$got'" ;;
esac
got=$(setup_case amt-ok ok bad)
case "$got" in
    "machine-setup:metal-toolchain|"*) pass "a missing Metal toolchain is machine-setup:metal-toolchain" ;;
    *) fail "metal check: got '$got'" ;;
esac
got=$(setup_case amt-password bad bad)
case "$got" in
    "machine-setup:automation-mode|"*"runFirstLaunch"*"MetalToolchain"*) pass "every failing check is logged; the first names the row" ;;
    *) fail "multi-failure check: got '$got'" ;;
esac
# The publisher's code allowlist must accept every reason (else it is dropped to its kind).
ms_codes_ok=$(python3 - "$SCRIPT_DIR/../tools/publish_metrics.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pm", sys.argv[1]); pm = importlib.util.module_from_spec(spec); spec.loader.exec_module(pm)
codes = ["machine-setup:automation-mode", "machine-setup:xcode-first-launch", "machine-setup:metal-toolchain",
         "machine-setup:test-host-hung", "machine-setup:sleep-assertion"]
row = lambda r: {"status": "failed", "reason": r, "total": 0}
print("yes" if all(pm.reason_code(c) == c and pm.classify_nightly_row(row(c)) == "did_not_run" for c in codes) else "no")
PY
)
[ "$ms_codes_ok" = "yes" ] && pass "every machine-setup reason survives the publisher and reads did_not_run (the '?' cell)" \
    || fail "a machine-setup reason is rejected or coloured by the publisher"

cat > "$SANDBOX/host-hung.log" <<'HHL'
2026-10-21 05:00:13.843 xcodebuild[36418:28252994]  IDETestOperationsObserverDebug: Failure collecting logarchive: Error Domain=com.apple.dt.xctest.error Code=8 "Timed out after 120.0s while initiating control session with daemon."
Testing failed:
	VideoScan (36530) encountered an error (The test runner hung before establishing connection.)
** TEST FAILED **
HHL
cat > "$SANDBOX/sleep-assertion.log" <<'SAL'
xcodebuild: error: Failed to build project VideoScan with scheme VideoScan.: Failed to prevent system sleep during UI testing. Error code: -536870211
SAL
printf 'xcodebuild: error: Unable to find a destination matching the provided destination specifier\n' > "$SANDBOX/other-zero.log"
diag_case() {
    # args: log total timed_out failed ui_hung rc -> "<status>|<reason>|<diagnosis printed?>"
    ( # shellcheck disable=SC1090
      source "$WATCHDOG_LIB"
      log() { echo "$*" >> "$SANDBOX/diag-case.log"; }
      : > "$SANDBOX/diag-case.log"
      classify_nightly_test_result "$3" 7200 "$2" "$4" "$5" "$6"
      apply_test_host_start_diagnosis "$1" "$2"
      printf '%s|%s|%s' "$STATUS" "$REASON" "$(grep -c 'test host could not start: check `automationmodetool` / Xcode first-launch / Metal toolchain' "$SANDBOX/diag-case.log")" )
}
got=$(diag_case "$SANDBOX/host-hung.log" 0 false 0 true 65)
[ "$got" = "failed|machine-setup:test-host-hung|1" ] && pass "10/21 M5: a test host that never connected is machine-setup:test-host-hung, with the diagnosis line" \
    || fail "host-hung diagnosis: got '$got'"
got=$(diag_case "$SANDBOX/sleep-assertion.log" 0 false 0 false 70)
[ "$got" = "failed|machine-setup:sleep-assertion|1" ] && pass "10/13 M4: no sleep assertion is machine-setup:sleep-assertion" \
    || fail "sleep-assertion diagnosis: got '$got'"
got=$(diag_case "$SANDBOX/other-zero.log" 0 false 0 false 70)
[ "$got" = "failed|zero-tests-ran:test-rc=70|0" ] && pass "a zero-test run with no host-start evidence stays zero-tests-ran" \
    || fail "unexplained zero: got '$got'"
got=$(diag_case "$SANDBOX/host-hung.log" 0 true 0 true 65)
[ "$got" = "failed|test-timeout:7200s|0" ] && pass "a watchdog timeout is never rewritten as machine setup" \
    || fail "timeout precedence: got '$got'"
got=$(diag_case "$SANDBOX/host-hung.log" 12000 false 0 true 65)
[ "$got" = "failed|ui-runner-hung|0" ] && pass "with tests counted, a runner-hang marker keeps its own reason (never machine-setup)" \
    || fail "tests-ran hang: got '$got'"
got=$(diag_case "$SANDBOX/host-hung.log" 12000 false 3 true 65)
[ "$got" = "failed|failed-tests:3|0" ] && pass "real failures are never rewritten by the host diagnosis" \
    || fail "failures + hang: got '$got'"

NIGHTLY="$SCRIPT_DIR/nightly_local_tests.sh"
PREFLIGHT_LINE=$(grep -n '^check_machine_setup$' "$NIGHTLY" | cut -d: -f1)
CORE_LINE2=$(grep -n '^run_core_package_tests "\$REPO/VideoScan/VideoScanCore"' "$NIGHTLY" | cut -d: -f1)
DIAG_LINE=$(grep -n '^    apply_test_host_start_diagnosis "\$NIGHTLY_TEST_LOG" "\$TOTAL"$' "$NIGHTLY" | cut -d: -f1)
ZERO_PUBLISH_LINE=$(grep -n 'publish_row "\$(with_person_metrics "\$(make_status_row "\$STATUS" "\$REASON"' "$NIGHTLY" | cut -d: -f1)
if [ -n "$PREFLIGHT_LINE" ] && [ -n "$CORE_LINE2" ] && [ "$PREFLIGHT_LINE" -lt "$CORE_LINE2" ] &&
   [ -n "$DIAG_LINE" ] && [ -n "$ZERO_PUBLISH_LINE" ] && [ "$DIAG_LINE" -lt "$ZERO_PUBLISH_LINE" ]; then
    pass "the machine preflight runs before any build, and the host diagnosis before the zero-test row"
else
    fail "machine-setup wiring moved (preflight=$PREFLIGHT_LINE core=$CORE_LINE2 diag=$DIAG_LINE zero-publish=$ZERO_PUBLISH_LINE)"
fi
# Item 5: no UI tests in the nightly. The ONE test invocation skips the UI
# target, so a UI runner can never hang the unit run or zero its count.
TEST_INVOCATIONS=$(grep -c '^    xcodebuild test-without-building' "$NIGHTLY")
UI_SKIPS=$(grep -c '^    -skip-testing:VideoScanUITests \\$' "$NIGHTLY")
if [ "$TEST_INVOCATIONS" -eq 1 ] && [ "$UI_SKIPS" -eq 1 ]; then
    pass "the nightly's only test invocation passes -skip-testing:VideoScanUITests"
else
    fail "UI tests may be back in the nightly (test invocations=$TEST_INVOCATIONS, UI skips=$UI_SKIPS)"
fi

}

# ───────────────────────────────────────────────────────────────────
# Test 16 (2026-10-21, GH #360 item 4): the M1 is OFF the nightly rotation.
# scripts/nightly_rota.json is the one source. The REAL guard and installer
# run in a sandbox HOME with fake scutil / launchctl / crontab on PATH: an
# off-rota Mac's guard exits 0 before fetching anything, its installer takes
# the job down (bootout + plist moved aside), an on-rota Mac gets its slot from
# the rotation, and a Mac on neither list is refused.
# ───────────────────────────────────────────────────────────────────
section_16() {
echo
echo "== Test 16: the nightly rotation (M1 off) =="
need_rota
# A git that records it was called: the off-rota guard must exit before it.
# (Tests 17/18 replace it with need_guard_fakes' git.)
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$FAKE_GIT_LOG"' 'exit 1' > "$RT/bin/git"
chmod +x "$RT/bin/git"
[ "$(python3 "$RT/scripts/nightly_rota.py" slot RicksM4)" = "on 14 0" ] &&
[ "$(python3 "$RT/scripts/nightly_rota.py" slot RicksUltra)" = "on 2 0" ] &&
[ "$(python3 "$RT/scripts/nightly_rota.py" slot RicksM5 | cut -c1-4)" = "off " ] &&
[ "$(python3 "$RT/scripts/nightly_rota.py" slot RicksM1 | cut -c1-4)" = "off " ] &&
[ "$(python3 "$RT/scripts/nightly_rota.py" slot SomeoneElse)" = "unknown" ] \
    && pass "the rotation: M4 14:00, M5 Ultra 02:00 (DECISIONS 2026-11-05), M5 and M1 off (laptops), anyone else unknown" \
    || fail "nightly_rota.py slots changed"
rota_run RicksM1 nightly_guarded.sh
GUARD_RC=$?
if [ "$GUARD_RC" -eq 0 ] && [ ! -s "$RT/git.log" ] &&
   grep -q 'off the nightly rotation' "$RT/home/Library/Logs/VideoScan/nightly_guard.log" 2>/dev/null; then
    pass "an off-rota Mac's guard exits 0 before fetching or running anything, and says why"
else
    fail "off-rota guard: rc=$GUARD_RC git calls='$(tr '\n' ' ' < "$RT/git.log")'"
fi
echo '<plist/>' > "$RT/home/Library/LaunchAgents/com.videoscan.nightly-tests.plist"
rota_run RicksM1 install_nightly.sh
INST_RC=$?
if [ "$INST_RC" -eq 0 ] && grep -q '^bootout gui/.*/com.videoscan.nightly-tests$' "$RT/launchctl.log" &&
   [ ! -e "$RT/home/Library/LaunchAgents/com.videoscan.nightly-tests.plist" ] &&
   [ -e "$RT/home/Library/LaunchAgents/com.videoscan.nightly-tests.plist.off-rota" ] &&
   ! grep -q '^bootstrap' "$RT/launchctl.log"; then
    pass "on the M1 the installer takes the job down (bootout, plist moved aside) and installs nothing"
else
    fail "off-rota installer: rc=$INST_RC launchctl='$(tr '\n' ' ' < "$RT/launchctl.log")' out='$(tr '\n' ' ' < "$RT/out.log")'"
fi
rm -f "$RT/home/Library/LaunchAgents/com.videoscan.nightly-tests.plist"
rota_run RicksM4 install_nightly.sh
INST_RC=$?
M4_PLIST="$RT/home/Library/LaunchAgents/com.videoscan.nightly-tests.plist"
if [ "$INST_RC" -eq 0 ] && [ -f "$M4_PLIST" ] &&
   [ "$(plutil -extract StartCalendarInterval.Hour raw "$M4_PLIST" 2>/dev/null)" = "14" ] &&
   [ "$(plutil -extract StartCalendarInterval.Minute raw "$M4_PLIST" 2>/dev/null)" = "0" ]; then
    pass "an on-rota Mac (M4) is installed at its rota slot, 14:00"
else
    fail "on-rota installer: rc=$INST_RC out='$(tr '\n' ' ' < "$RT/out.log")'"
fi
rota_run SomeoneElse install_nightly.sh
INST_RC=$?
[ "$INST_RC" -ne 0 ] && grep -q 'not on scripts/nightly_rota.json' "$RT/out.log" \
    && pass "a Mac on neither list is refused by the installer" \
    || fail "unknown host was installed (rc=$INST_RC)"

}

# ───────────────────────────────────────────────────────────────────
# Test 17 (2026-10-29): every on-rota Studio runs its own nightly. The
# metrics page shows both Studios (DECISIONS 2026-10-28), but the guard
# skipped the Ultra at 05:00 because the M4 had already published green.
# Only this host's own green row today makes the guard a no-op.
# ───────────────────────────────────────────────────────────────────
section_17() {
echo
echo "== Test 17: the guard counts only this host's green row =="
need_guard_fakes
guard_ran RicksUltra "$M4_GREEN" \
    && pass "the Ultra runs its nightly although the M4 is already green today" \
    || fail "the Ultra was skipped because another host was green: $(tail -1 "$RT/home/Library/Logs/VideoScan/nightly_guard.log")"
! guard_ran RicksUltra "$M4_GREEN
$ULTRA_GREEN" \
    && pass "a second launch on the same day and the same main is a no-op once this host is green" \
    || fail "the Ultra ran twice in one day on one commit"
# 2026-11-10: green today, but for the main of this morning; main has moved.
guard_ran RicksUltra "$ULTRA_GREEN_BEFORE" \
    && pass "a green row from today for an OLDER main does not skip the run (by commit, not by date)" \
    || fail "skipped by date although main moved: $(tail -1 "$RT/home/Library/Logs/VideoScan/nightly_guard.log")"

}

# ───────────────────────────────────────────────────────────────────
# Test 18 (2026-10-29): the toolchain update an hour before the nightly.
# (a) the guard waits for its lock, capped; (b) the update runs brew with
# no terminal (no "Y/n", no sudo password), never --greedy, logs what it
# upgraded, writes the summary and releases its lock; (c) the installer
# schedules it one hour before the rota slot.
# ───────────────────────────────────────────────────────────────────
section_18() {
echo
echo "== Test 18: toolchain update before the nightly =="
need_guard_fakes
LOCKDIR="$RT/home/Library/Logs/VideoScan/toolchain_update.lock"
mkdir -p "$LOCKDIR"
printf '%s\n' "$M4_GREEN" > "$RT/rows.jsonl"; : > "$RT/caff.log"
HOME="$RT/home" FAKE_HOST=RicksUltra FAKE_ROWS="$RT/rows.jsonl" FAKE_CAFF_LOG="$RT/caff.log" \
    NIGHTLY_TOOLCHAIN_WAIT_SECONDS=1 PATH="$RT/bin:$PATH" \
    bash "$RT/scripts/nightly_guarded.sh" > "$RT/out.log" 2>&1
if grep -q 'nightly_local_tests.sh' "$RT/caff.log" &&
   grep -q 'toolchain update still running after 1s' "$RT/home/Library/Logs/VideoScan/nightly_guard.log"; then
    pass "the guard waits for a running toolchain update, capped, then runs the nightly"
else
    fail "guard vs toolchain lock: $(tail -1 "$RT/home/Library/Logs/VideoScan/nightly_guard.log")"
fi
rmdir "$LOCKDIR"

cp "$SCRIPT_DIR/update_toolchain.sh" "$SCRIPT_DIR/install_toolchain_update.sh" "$RT/scripts/"
# A brew that records its arguments and whether stdin is a terminal; its
# second `list --versions` reports ffmpeg one version newer.
cat > "$RT/bin/brew" <<'SH'
#!/bin/sh
echo "$* tty=$([ -t 0 ] && echo yes || echo no)" >> "$FAKE_BREW_LOG"
if [ "$1 $2" = "list --versions" ]; then
    n=$(cat "$FAKE_BREW_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_BREW_COUNT"
    [ "$n" -eq 0 ] && echo "ffmpeg 9.0.2" || echo "ffmpeg 9.0.3"
    echo "uv 0.9.1"
fi
exit 0
SH
# GH #499: xcodebuild, xcrun and sudo are fakes that RECORD every call. The
# update resets PATH, so a fake on PATH is never reached — before the
# TOOLCHAIN_XCODEBUILD / TOOLCHAIN_XCRUN / TOOLCHAIN_SUDO overrides this
# section ran the REAL tools (and, on a Mac missing components, would have run
# the real `sudo -n xcodebuild -runFirstLaunch` / a MetalToolchain download).
# A call missing from $RT/tools.log means a real binary answered it.
# $FAKE_XCODE_MISSING=1 plays the Mac that needs first launch and Metal.
cat > "$RT/bin/xcodebuild" <<'SH'
#!/bin/sh
echo "xcodebuild $*" >> "$FAKE_TOOL_LOG"
case "$1" in
    -version) echo "Xcode 27.1"; echo "Build version 27A9275" ;;
    -checkFirstLaunchStatus) [ "${FAKE_XCODE_MISSING:-0}" = 1 ] && exit 69 ;;
esac
exit 0
SH
printf '%s\n' '#!/bin/sh' 'echo "xcrun $*" >> "$FAKE_TOOL_LOG"' '[ "${FAKE_XCODE_MISSING:-0}" = 1 ] && exit 72' 'exit 0' > "$RT/bin/xcrun"
printf '%s\n' '#!/bin/sh' 'echo "sudo $*" >> "$FAKE_TOOL_LOG"' 'exit 0' > "$RT/bin/sudo"
chmod +x "$RT/bin/brew" "$RT/bin/xcodebuild" "$RT/bin/xcrun" "$RT/bin/sudo"
# The "is a nightly running?" pgrep -f pattern must match no real process.
# 2026-11-20: concurrent self-test runs made Test 18 red (SKIPPED: a nightly
# … in progress) — each run's own `pgrep -f <pattern>` carries the pattern in
# its argv, so a sibling run's pgrep matched it. The bracket keeps the regex
# from matching its own text (the `grep [p]attern` idiom). The decoy is that
# sibling: one process (exec -a, so killing it leaves no child) whose command
# line carries this run's pattern.
TC_BUSY='no-such-[p]rocess-xyzzy'
bash -c "exec -a 'tc-decoy $TC_BUSY' sleep 60" > /dev/null 2>&1 &
TC_DECOY=$!
: > "$RT/brew.log"; rm -f "$RT/brew.count"; : > "$RT/tools.log"
HOME="$RT/home" FAKE_HOST=RicksUltra FAKE_BREW_LOG="$RT/brew.log" FAKE_BREW_COUNT="$RT/brew.count" \
    FAKE_TOOL_LOG="$RT/tools.log" \
    TOOLCHAIN_BREW="$RT/bin/brew" TOOLCHAIN_MAS=/nonexistent TOOLCHAIN_BUSY_PATTERN="$TC_BUSY" \
    TOOLCHAIN_XCODEBUILD="$RT/bin/xcodebuild" TOOLCHAIN_XCRUN="$RT/bin/xcrun" TOOLCHAIN_SUDO="$RT/bin/sudo" \
    PATH="$RT/bin:$PATH" bash "$RT/scripts/update_toolchain.sh" < /dev/null > "$RT/out.log" 2>&1
# GH #499: every Xcode question the update asks was answered by a fake — two
# `-version` (before/after), the first-launch check, the Metal check — and on
# this healthy fake Mac nothing was installed and sudo was never called.
if [ "$(grep -c '^xcodebuild -version$' "$RT/tools.log")" = 2 ] &&
   [ "$(grep -c '^xcodebuild -checkFirstLaunchStatus$' "$RT/tools.log")" = 1 ] &&
   [ "$(grep -c '^xcrun -f metal$' "$RT/tools.log")" = 1 ] &&
   [ "$(grep -c . "$RT/tools.log")" = 4 ]; then
    pass "the update's xcodebuild/xcrun calls all went to the fakes (no real Xcode tool ran; nothing installed)"
else
    fail "a REAL xcodebuild/xcrun ran in the self-test (GH #499) — the fakes recorded only: '$(tr '\n' ';' < "$RT/tools.log")'"
fi
TC_LOG="$RT/home/Library/Logs/VideoScan/toolchain_update.log"
TC_SUM="$RT/home/Library/Logs/VideoScan/toolchain_update_latest.json"
if grep -q '^upgrade --formula tty=no$' "$RT/brew.log" && grep -q '^upgrade --cask tty=no$' "$RT/brew.log" &&
   ! grep -q -- '--greedy' "$RT/brew.log" && ! grep -q 'tty=yes' "$RT/brew.log" &&
   grep -q 'upgraded: ffmpeg 9.0.2 -> 9.0.3' "$TC_LOG" && grep -q 'OUTCOME ok: 1 package(s) upgraded' "$TC_LOG" &&
   python3 -c "import json,sys; j=json.load(open(sys.argv[1])); sys.exit(0 if j['status']=='ok' and j['upgraded']==['ffmpeg 9.0.2 -> 9.0.3'] else 1)" "$TC_SUM" &&
   [ ! -d "$LOCKDIR" ]; then
    pass "the update runs brew with no terminal, never --greedy, logs and summarises the upgrade, releases its lock"
else
    fail "toolchain update: brew='$(tr '\n' ';' < "$RT/brew.log")' log='$(tail -3 "$TC_LOG" 2>/dev/null | tr '\n' ' ')'"
fi
mkdir -p "$LOCKDIR"; : > "$RT/brew.log"
HOME="$RT/home" FAKE_HOST=RicksUltra FAKE_BREW_LOG="$RT/brew.log" FAKE_BREW_COUNT="$RT/brew.count" \
    TOOLCHAIN_BREW="$RT/bin/brew" TOOLCHAIN_MAS=/nonexistent TOOLCHAIN_BUSY_PATTERN="$TC_BUSY" \
    PATH="$RT/bin:$PATH" bash "$RT/scripts/update_toolchain.sh" < /dev/null > "$RT/out.log" 2>&1
kill "$TC_DECOY" 2>/dev/null; wait "$TC_DECOY" 2>/dev/null
[ ! -s "$RT/brew.log" ] && [ -d "$LOCKDIR" ] && grep -q 'SKIPPED: another toolchain update holds' "$TC_LOG" \
    && pass "a second update while one holds the lock touches nothing and leaves the lock alone" \
    || fail "concurrent toolchain update ran brew: $(tr '\n' ';' < "$RT/brew.log")"
rmdir "$LOCKDIR"
# GH #499: the Mac that needs first launch and the Metal toolchain. The two
# installing commands are issued — to the fakes, exactly once each — and no
# other sudo command is ever asked for.
: > "$RT/brew.log"; rm -f "$RT/brew.count"; : > "$RT/tools.log"
HOME="$RT/home" FAKE_HOST=RicksUltra FAKE_BREW_LOG="$RT/brew.log" FAKE_BREW_COUNT="$RT/brew.count" \
    FAKE_TOOL_LOG="$RT/tools.log" FAKE_XCODE_MISSING=1 \
    TOOLCHAIN_BREW="$RT/bin/brew" TOOLCHAIN_MAS=/nonexistent TOOLCHAIN_BUSY_PATTERN="$TC_BUSY" \
    TOOLCHAIN_XCODEBUILD="$RT/bin/xcodebuild" TOOLCHAIN_XCRUN="$RT/bin/xcrun" TOOLCHAIN_SUDO="$RT/bin/sudo" \
    PATH="$RT/bin:$PATH" bash "$RT/scripts/update_toolchain.sh" < /dev/null > "$RT/out.log" 2>&1
if [ "$(grep -c '^sudo ' "$RT/tools.log")" = 1 ] &&
   grep -q '^sudo -n /usr/bin/xcodebuild -runFirstLaunch$' "$RT/tools.log" &&
   [ "$(grep -c '^xcodebuild -downloadComponent MetalToolchain$' "$RT/tools.log")" = 1 ] &&
   [ "$(grep -c . "$RT/tools.log")" = 6 ] &&
   grep -q 'Xcode first launch done' "$TC_LOG"; then
    pass "a Mac missing Xcode components: first launch and the Metal download go to the fakes, once each, and nothing else is sudo'd"
else
    fail "missing-components update (GH #499): tools='$(tr '\n' ';' < "$RT/tools.log")' log='$(tail -3 "$TC_LOG" 2>/dev/null | tr '\n' ' ')'"
fi
rota_run RicksM4 install_toolchain_update.sh
TC_PLIST="$RT/home/Library/LaunchAgents/com.videoscan.toolchain-update.plist"
[ "$(plutil -extract StartCalendarInterval.Hour raw "$TC_PLIST" 2>/dev/null)" = "13" ] &&
[ "$(plutil -extract StartCalendarInterval.Minute raw "$TC_PLIST" 2>/dev/null)" = "0" ] &&
grep -q '^bootstrap gui/' "$RT/launchctl.log" \
    && pass "the installer schedules the update one hour before the M4's 14:00 slot (13:00)" \
    || fail "toolchain installer: out='$(tr '\n' ' ' < "$RT/out.log")'"

}

# ───────────────────────────────────────────────────────────────────
# Run the selected sections in script order.
# ───────────────────────────────────────────────────────────────────
for s in $SECTIONS; do
    has_word "$s" "$RUN_SECTIONS" && "section_$s"
done

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
