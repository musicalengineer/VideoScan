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
SECTIONS="1 2 3 4 5 6 7 7b 8 9 9b 10 11 12 12b 13 14 14b 15 16 17 18 19"
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
# … and both name readers share one rule (2026-11-21).
awk '/^nightly_name_token_py\(\) \{/,/^}$/' "$SCRIPT_DIR/nightly_local_tests.sh" >> "$PARSE_LIB"
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
# Test 19 (2026-11-21): the app phase as K test hosts. A fake xctest_shards.py
# (VIDEOSCAN_NIGHTLY_APP_SHARDS; the real one is tested by
# tests/test_xctest_shards.py) lays down a chosen run — each shard's log, the
# summary JSON, the result bundles — so the REAL run_app_tests_sharded,
# parse_test_counts, read_app_shards_summary, classify_nightly_test_result,
# apply_test_host_start_diagnosis and union_app_shards_coverage (the real
# scripts/xccov_union.py over a fake xccov) run end to end
# with no test host. Pins: the same outcome gets the same row as one host
# (green, a failed test, a crashed test, a host that never started); the
# counts are the bundles' when a verdict line was glued away, and a failure
# only a bundle names is counted and named; a shard that times out, dies,
# comes up short or leaves no verdict is red by name, in the ladder's order;
# the watchdog's stop leaves no host alive and the row is test-timeout with
# the logs' partial counts; coverage is merged from every bundle or not
# published; NIGHTLY_APP_JOBS=1 and a checkout without the sharder are the
# single host, the same command byte for byte.
# ───────────────────────────────────────────────────────────────────
section_19() {
echo
echo "== Test 19: the app phase as K test hosts =="
need_core_lib
NIGHTLY="$SCRIPT_DIR/nightly_local_tests.sh"
SH="$SANDBOX/shards"
mkdir -p "$SH/bin" "$SH/fix"
# The fake sharder. $SHARD_FAKE_FIX/<n>.log → <run-dir>/000<n>/strand.log, a
# result bundle beside each, $SHARD_FAKE_FIX/summary.json → --summary (absent:
# none written). SHARD_FAKE_HOST_STOP=<s>: leave a "test host" running in a
# session of its own, as the strand runner does, and on TERM take <s> seconds
# to stop it — the watchdog must wait for that.
cat > "$SH/bin/xctest_shards.py" <<'FSH'
NIGHTLY_SUMMARY_VERSION = 1
import json, os, shutil, signal, subprocess, sys, time
a = sys.argv[1:]
fix = os.environ["SHARD_FAKE_FIX"]
with open(os.environ["SHARD_FAKE_ARGS"], "w") as f:
    f.write(" ".join(a) + "\n")
run_dir = a[a.index("--run-dir") + 1]
n = 0
while os.path.exists(os.path.join(fix, "%d.log" % n)):
    d = os.path.join(run_dir, "%04d" % n)
    os.makedirs(os.path.join(d, "tmp"))
    shutil.copy(os.path.join(fix, "%d.log" % n), os.path.join(d, "strand.log"))
    bundle = os.path.join(d, "shard.xcresult")
    os.makedirs(bundle)
    # Coverage as xccov prints it. One logic file of 4 executable lines (2-5): host n ran line n+2,
    # and every host ran line 2; one SwiftUI-named file the logic filter leaves out. The union over
    # three hosts is lines 2,3,4 of 4 = 75%; no host alone has more than 2 of 4.
    # SHARD_FAKE_COV_SKEW: host 1 was built from other sources (line 6 is executable there).
    skew = os.environ.get("SHARD_FAKE_COV_SKEW") and n == 1
    ran = {2, min(n + 2, 5)}
    logic = [{"line": 1, "isExecutable": False}] + [
        {"line": k, "isExecutable": True, "executionCount": 3 if k in ran else 0,
         "subranges": [{"column": 1, "length": 4, "executionCount": 1}]} for k in range(2, 7 if skew else 6)]
    view = [{"line": 1, "isExecutable": True, "executionCount": 9}]
    json.dump({"/src/Ledger.swift": logic, "/src/LedgerView.swift": view, "/dep/Other.swift": view},
              open(os.path.join(bundle, "archive.json"), "w"))
    json.dump({"targets": [
        {"name": "VideoScan.app", "files": [
            {"path": "/src/Ledger.swift", "coveredLines": len(ran) + 1, "executableLines": 6},
            {"path": "/src/LedgerView.swift", "coveredLines": 1, "executableLines": 1}]},
        {"name": "Other", "files": [{"path": "/dep/Other.swift", "coveredLines": 1, "executableLines": 1}]}]},
        open(os.path.join(bundle, "report.json"), "w"))
    n += 1
print("xctest-shards: 9 suites, ~9 tests → %d test hosts at once (jobs %s)" % (n, a[a.index("--jobs") + 1]), flush=True)
stop = float(os.environ.get("SHARD_FAKE_HOST_STOP") or 0)
if stop:
    host = subprocess.Popen(["sleep", "300"], start_new_session=True)
    with open(os.environ["SHARD_FAKE_HOST_PID"], "w") as f:
        f.write(str(host.pid))
    def term(signum, frame):
        time.sleep(stop)
        host.kill()
        host.wait()
        sys.exit(130)
    signal.signal(signal.SIGTERM, term)
    time.sleep(300)
if os.path.exists(os.path.join(fix, "summary.json")):
    shutil.copy(os.path.join(fix, "summary.json"), a[a.index("--summary") + 1])
print("xctest-shards: shard-01: verdict line", flush=True)
sys.exit(int(os.environ["SHARD_FAKE_RC"]))
FSH
# shard_fixture <name> <summary-spec-json or -> <log0> [<log1> …]: a fixture
# folder. The spec is {"shards": [{…}], …}; every shard defaults to a green one
# whose bundle was read, and the totals are the shards' sums.
cat > "$SH/fixture.py" <<'FXP'
import json, os, sys
out, spec, logs = sys.argv[1], sys.argv[2], sys.argv[3:]
os.makedirs(out)
for i, text in enumerate(logs):
    with open(os.path.join(out, "%d.log" % i), "w") as f:
        f.write(text.replace("\\n", "\n").replace("\\t", "\t"))
if spec != "-":
    d = json.loads(spec)
    shards = []
    for i, s in enumerate(d.get("shards", [])):
        base = {"name": "shard-%02d" % (i + 1), "serial": None, "rc": 0, "timed_out": False, "seconds": 1.0,
                "passed": 0, "failed": 0, "skipped": 0, "expected": 0, "green": True, "codes": [], "problems": [],
                "notes": [], "log": "/run/%04d/strand.log" % i, "bundle": "/run/%04d/shard.xcresult" % i,
                "bundle_read": True, "suites": 1}
        base.update(s)
        shards.append(base)
    top = {"version": 1, "verdict": "GREEN" if all(s["green"] for s in shards) else "RED", "jobs": 8, "wall_s": 1.0,
           "passed": sum(s["passed"] for s in shards), "failed": sum(s["failed"] for s in shards),
           "skipped": sum(s["skipped"] for s in shards), "expected": sum(s["expected"] for s in shards),
           "expected_failures": 0, "counts_from": "bundles", "undealable_files": 0, "failures": [], "shards": shards}
    top.update({k: v for k, v in d.items() if k != "shards"})
    with open(os.path.join(out, "summary.json"), "w") as f:
        json.dump(top, f)
FXP
shard_fixture() { rm -rf "$SH/fix/$1"; python3 "$SH/fixture.py" "$SH/fix/$@"; }
# Run the sharded phase the way the nightly's main flow does (the wiring pins
# at the end of this section keep the two in step).
# args: fixture rc → status|reason|passed|failed|skipped|known|names|crashed|complete|hosts
shard_case() {
    (
        # shellcheck disable=SC1090
        source "$CORE_LIB"
        log() { printf '%s\n' "$*" >> "$SH/case.log"; }
        : > "$SH/case.log"
        export SHARD_FAKE_FIX="$SH/fix/$1" SHARD_FAKE_RC="$2" SHARD_FAKE_ARGS="$SH/args.txt"
        export NIGHTLY_XCRUN="$SH/bin/xcrun"
        NIGHTLY_ON_DEMAND="${SHARD_CASE_ON_DEMAND:-0}"
        NIGHTLY_TEST_TIMEOUT_SECONDS="${SHARD_CASE_TIMEOUT:-60}"
        NIGHTLY_APP_SHARDS_DIR="$SH/run"
        NIGHTLY_APP_SHARDS_TIMINGS="$SH/timings.json"
        NIGHTLY_TEST_LOG="$SH/app-test.log"
        NIGHTLY_XCRESULT="$SH/merged.xcresult"
        export VIDEOSCAN_NIGHTLY_COVERAGE_UNION="${SHARD_CASE_UNION_TOOL:-$SCRIPT_DIR/xccov_union.py}"
        HOME="$SH/home"
        NIGHTLY_APP_SHARDS_USED=true
        APP_TEST_HOSTS=8
        run_app_tests_sharded "$SH/bin/xctest_shards.py" "/dd/Build/Products" 8 > /dev/null
        TEST_RC=$?
        TEST_TIMED_OUT=$NIGHTLY_WATCHDOG_DID_TIMEOUT
        parse_test_counts "$NIGHTLY_TEST_LOG"
        if $NIGHTLY_APP_SHARDS_USED && ! $TEST_TIMED_OUT; then
            read_app_shards_summary "$NIGHTLY_APP_SHARDS_DIR/summary.json"
        fi
        TOTAL=$((PASSED + FAILED + SKIPPED))
        UI_RUNNER_HUNG=false
        grep -qE 'test runner hung|Timed out while enabling automation' "$NIGHTLY_TEST_LOG" 2>/dev/null && UI_RUNNER_HUNG=true
        classify_nightly_test_result "$TEST_TIMED_OUT" "$NIGHTLY_TEST_TIMEOUT_SECONDS" \
            "$TOTAL" "$FAILED" "$UI_RUNNER_HUNG" "$TEST_RC" "${CRASHED:-0}" "$APP_SHARD_REASON"
        apply_test_host_start_diagnosis "$NIGHTLY_TEST_LOG" "$TOTAL"
        if [ -n "${SHARD_CASE_MERGE:-}" ]; then
            COV_BASIS=""
            union_app_shards_coverage > /dev/null
            printf '%s|%s|%s|' "$?" "$COV_LOGIC" "$COV_BASIS"
        fi
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$STATUS" "$REASON" "$PASSED" "$FAILED" "$SKIPPED" \
            "$KNOWN_ISSUE_TESTS" "$FAILED_NAMES_JSON" "${CRASHED_NAMES_JSON:-[]}" "$APP_SHARDS_COMPLETE" "$APP_TEST_HOSTS"
    )
}
# A fake xcrun for the coverage union: `xccov view --report|--archive --json <bundle>` prints the
# bundle's report.json / archive.json; every call is recorded. SHARD_FAKE_XCCOV_FAILS: it cannot.
cat > "$SH/bin/xcrun" <<'FXR'
#!/bin/sh
echo "$*" >> "$SHARD_FAKE_ARGS.xcrun"
[ -n "${SHARD_FAKE_XCCOV_FAILS:-}" ] && { echo "error: cannot read the result bundle" >&2; exit 1; }
[ "$1 $2 $4" = "xccov view --json" ] || { echo "unexpected: $*" >&2; exit 64; }
case "$3" in
    --report) cat "$5/report.json" ;;
    --archive) cat "$5/archive.json" ;;
    *) exit 64 ;;
esac
FXR
chmod +x "$SH/bin/xcrun"
mkdir -p "$SH/home"
P1='✔ Test a() passed after 0.010 seconds.'
P2='✔ Test b() passed after 0.010 seconds.'
PX="Test Case '-[VideoScanTests.OldTests testOld]' passed (0.010 seconds)."
SK='➜ Test needsFfmpeg() skipped: "no ffmpeg"'
KI='━ Test budget() passed after 0.030 seconds with 1 known issue.'
RUNSUM='✔ Test run with 2 tests in 1 suite passed after 0.100 seconds.'
F1='✘ Test ledgerKeepsEveryRow() recorded an issue at L.swift:9:5: Expectation failed: a == b\n✘ Test ledgerKeepsEveryRow() failed after 0.020 seconds with 1 issue.'

if ! grep -q '^run_app_tests_sharded()' "$CORE_LIB" || ! grep -q '^read_app_shards_summary()' "$CORE_LIB"; then
    fail "the sharded app-phase functions could not be extracted from nightly_local_tests.sh"
else
    # ── the same outcome, the same row ──
    shard_fixture green '{"shards":[{"passed":3,"skipped":1,"expected":4},{"passed":2,"expected":2},{"passed":1,"expected":1,"serial":"1 suites that must not run beside another test host (timing budget)"}]}' \
        "# strand shard-01: xcodebuild …\n$P1\n$P2\n$SK\n$KI\n$RUNSUM\n" "$P1\n$PX\n" "$P2\n"
    got=$(shard_case green 0)
    want='ok||6|0|1|1|[]|[]|true|2'
    [ "$got" = "$want" ] && pass "green: three shards' logs and bundles sum to one row (6p/0f/1s, 1 known issue), every shard complete" \
        || fail "green sharded run: got '$got' want '$want'"
    args=$(cat "$SH/args.txt" 2>/dev/null)
    want="--products /dd/Build/Products --all --stages all --jobs 8 --run-dir $SH/run/run --stream --timeout 1800 --timings $SH/timings.json --summary $SH/run/summary.json --coverage"
    [ "$args" = "$want" ] && pass "the sharder gets every stage, K, its run folder, --stream, the shard deadline, the nightly's own timings, --summary and --coverage" \
        || fail "xctest_shards arguments: got '$args' want '$want'"
    grep -q '^xctest-shards: shard-01: verdict line$' "$SH/case.log" \
        && pass "the sharder's own lines (the deal, each shard's verdict) reach the nightly log" \
        || fail "xctest-shards lines missing from the nightly log: $(cat "$SH/case.log")"
    [ "$(cat "$SH/fix/green/0.log" "$SH/fix/green/1.log" "$SH/fix/green/2.log" | cksum)" = "$(cksum < "$SH/run/hosts.log")" ] \
        && pass "the log the parsers read is the shards' own logs, whole and in order, without the sharder's lines" \
        || fail "the parsed log is not the shards' logs: $(cat "$SH/run/hosts.log")"
    grep -q '^xctest-shards: 9 suites' "$SH/app-test.log" \
        && pass "the live log a reader tails during the phase (run_tests --full, m4_run status) is the sharder's stream" \
        || fail "the live app test log is not the sharder's stream: $(cat "$SH/app-test.log")"
    got=$(SHARD_CASE_ON_DEMAND=1 shard_case green 0)
    args=$(cat "$SH/args.txt" 2>/dev/null)
    case "$got|$args" in
        "ok||6|0|1|1|"*"--coverage"*) fail "an on-demand run recorded coverage: '$args'" ;;
        "ok||6|0|1|1|"*"--summary $SH/run/summary.json") pass "on demand: the same verdict, no --coverage (no profile, green bundles not kept)" ;;
        *) fail "on-demand sharded run: got '$got' args '$args'" ;;
    esac

    # A verdict line glued into an app log line: the logs count 5, the bundles 6.
    shard_fixture glued '{"shards":[{"passed":4,"skipped":1,"expected":5},{"passed":2,"expected":2}]}' \
        "$P1\n$P2\n$SK\n2026-11-20 21:15:39.799 VideoScan[1:2] [logging] os_unix.c:52992: (2) open(/private/var/TEST_HOST_HEARTBEAT epoch=1795227328.334 elapsed=40.0s\n$PX\n" "$P1\n$P2\n"
    got=$(shard_case glued 0)
    case "$got" in
        "ok||6|0|1|0|[]|[]|true|2")
            grep -q 'App shards: counts trued up from the result bundles: logs said 5 passed / 1 skipped, bundles 6 / 1' "$SH/case.log" \
                && pass "a verdict line lost from a log: the row's counts are the result bundles' (6 passed, not 5), and the log says so" \
                || fail "counts were trued up without a word: $(cat "$SH/case.log")" ;;
        *) fail "lost verdict line: got '$got'" ;;
    esac

    shard_fixture onered '{"shards":[{"passed":2,"expected":2},{"passed":1,"failed":1,"expected":2,"green":false,"rc":65}],"failures":[{"id":"LedgerTests/ledgerKeepsEveryRow()","name":"ledgerKeepsEveryRow()","shard":"shard-02"}]}' \
        "$P1\n$P2\n" "$P1\n$F1\n"
    got=$(shard_case onered 1)
    want='failed|failed-tests:1|3|1|0|0|["ledgerKeepsEveryRow()"]|[]|true|2'
    [ "$got" = "$want" ] && pass "one shard red on a failing test: failed-tests:1, named once as one host names it (the bundle's copy is not a second failure)" \
        || fail "one red shard: got '$got' want '$want'"

    shard_fixture bundleonly '{"shards":[{"passed":2,"expected":2},{"passed":1,"failed":1,"expected":2,"green":false,"rc":65}],"failures":[{"id":"LedgerTests/ledgerKeepsEveryRow()","name":"ledgerKeepsEveryRow()","shard":"shard-02"}]}' \
        "$P1\n$P2\n" "$P1\n"
    got=$(shard_case bundleonly 1)
    want='failed|failed-tests:1|3|1|0|0|["LedgerTests.ledgerKeepsEveryRow()"]|[]|true|2'
    [ "$got" = "$want" ] && pass "a failure only a result bundle names (its verdict line lost from the log) is counted and named by its bundle identifier" \
        || fail "bundle-only failure: got '$got' want '$want'"

    # A host that DIED: xcodebuild's own "Failing tests:" block is the only
    # place the test is named — crashed-tests, as with one host.
    shard_fixture crashed '{"shards":[{"passed":2,"expected":2},{"passed":1,"failed":1,"expected":2,"green":false,"rc":65}],"failures":[{"id":"VitalsTests/theAsideSpeaksTheCorrectedYear()","name":"theAsideSpeaksTheCorrectedYear()","shard":"shard-02"}]}' \
        "$P1\n$P2\n" "$P1\nFailing tests:\n\tVitalsTests.theAsideSpeaksTheCorrectedYear()\n\n** TEST EXECUTE FAILED **\n"
    got=$(shard_case crashed 1)
    want='failed|crashed-tests:1|3|0|0|0|[]|["VitalsTests.theAsideSpeaksTheCorrectedYear()"]|true|2'
    [ "$got" = "$want" ] && pass "a test host that died in one shard: crashed-tests:1 by name, not counted again as a failure" \
        || fail "crashed shard: got '$got' want '$want'"

    # ── what only a sharded run can do ──
    shard_fixture died '{"shards":[{"passed":2,"expected":2},{"passed":1,"expected":1,"green":false,"rc":65,"codes":["died"],"bundle_read":false,"problems":["xcodebuild exit 65 with no failed test (a crash, a dead test host or an xcodebuild error)"]}],"counts_from":"mixed","expected_failures":null}' \
        "$P1\n$P2\n" "$P1\n"
    got=$(SHARD_CASE_MERGE=1 shard_case died 1)
    want='1|null||failed|shard-died:1|3|0|0|0|[]|[]|false|2'
    if [ "$got" = "$want" ] && grep -q 'App shards: RED shard-02: xcodebuild exit 65 with no failed test' "$SH/case.log" \
        && grep -q 'Coverage NOT published' "$SH/case.log"; then
        pass "a shard that dies with no failed test: shard-died:1, the shard and its log named, and no coverage number from a partial run"
    else
        fail "died shard: got '$got' want '$want' ($(cat "$SH/case.log"))"
    fi

    shard_fixture timeout '{"shards":[{"passed":1,"failed":1,"expected":2,"green":false,"rc":65},{"passed":1,"expected":3,"green":false,"rc":-15,"timed_out":true,"codes":["timeout","short"],"bundle_read":false,"problems":["TIMEOUT after 1800s (its process group was stopped)","ran 1 of 3 tests"]}],"counts_from":"mixed","expected_failures":null}' \
        "$P1\n$F1\n" "$P2\n"
    got=$(shard_case timeout 1)
    want='failed|shard-timeout:1800s|2|1|0|0|["ledgerKeepsEveryRow()"]|[]|false|2'
    [ "$got" = "$want" ] && pass "a shard that times out: shard-timeout:1800s outranks a failure elsewhere (the run is incomplete); the failure is still counted and named" \
        || fail "timed-out shard: got '$got' want '$want'"

    shard_fixture short '{"shards":[{"passed":2,"expected":2},{"passed":1,"expected":3,"green":false,"codes":["short"],"problems":["ran 1 of 3 tests"]}]}' \
        "$P1\n$P2\n" "$P1\n"
    got=$(shard_case short 1)
    want='failed|shard-short:1|3|0|0|0|[]|[]|false|2'
    [ "$got" = "$want" ] && grep -q 'App shards: RED shard-02: ran 1 of 3 tests' "$SH/case.log" \
        && pass "counts short (a shard ran 1 of its 3 tests, every one green): shard-short:1, never ok" \
        || fail "short shard: got '$got' want '$want'"

    shard_fixture noverdict - "$P1\n$P2\n"
    got=$(shard_case noverdict 1)
    want='failed|shard-no-verdict|2|0|0|0|[]|[]|false|8'
    [ "$got" = "$want" ] && pass "the sharder died before its verdict: the logs' counts, reason shard-no-verdict" \
        || fail "no summary: got '$got' want '$want'"
    got=$(shard_case noverdict 0)
    case "$got" in
        "failed|shard-no-verdict|"*) pass "exit 0 with no summary is still not green (nothing proves the shards)" ;;
        *) fail "no summary, rc 0: got '$got'" ;;
    esac

    # Every host hung before its first test (10/21 on the M5), K times over:
    # zero tests is the machine, exactly as with one host (Test 15).
    HUNG='Testing failed:\n\tVideoScan (36530) encountered an error (The test runner hung before establishing connection.)\n** TEST FAILED **'
    shard_fixture hung '{"shards":[{"expected":2,"green":false,"rc":65,"codes":["short","died"],"bundle_read":false},{"expected":2,"green":false,"rc":65,"codes":["short","died"],"bundle_read":false}],"counts_from":"logs","expected_failures":null}' \
        "$HUNG\n" "$HUNG\n"
    got=$(shard_case hung 1)
    case "$got" in
        "failed|machine-setup:test-host-hung|0|0|0|0|"*)
            grep -q 'test host could not start: check `automationmodetool`' "$SH/case.log" \
                && pass "every shard's host hung before a test: machine-setup:test-host-hung with the diagnosis line, as with one host" \
                || fail "host-hung diagnosis line missing: $(cat "$SH/case.log")" ;;
        *) fail "all hosts hung: got '$got'" ;;
    esac

    # ── the watchdog ──
    # The hosts are in process groups of their own; the sharder stops them on
    # TERM, and that takes it seconds. The watchdog must give it that long
    # before its KILL, or the hosts outlive the run.
    rm -f "$SH/host.pid"
    stop_start=$(date +%s)
    got=$(
        export SHARD_FAKE_HOST_STOP=3 SHARD_FAKE_HOST_PID="$SH/host.pid"
        export NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS=1 NIGHTLY_APP_SHARDS_STOP_SECONDS=5
        SHARD_CASE_TIMEOUT=2 shard_case green 0
    )
    stop_elapsed=$(( $(date +%s) - stop_start ))
    host_pid=$(cat "$SH/host.pid" 2>/dev/null)
    case "$got" in
        "failed|test-timeout:2s|6|0|1|1|[]|[]|false|"*)
            if [ -n "$host_pid" ] && ! kill -0 "$host_pid" 2>/dev/null; then
                pass "the watchdog's deadline: test-timeout with the logs' partial counts, and no test host left alive (${stop_elapsed}s)"
            else
                fail "the watchdog stop left test host PID '$host_pid' alive"
                kill "$host_pid" 2>/dev/null || true
            fi ;;
        *) fail "watchdog over a sharded run: got '$got'"; kill "$host_pid" 2>/dev/null || true ;;
    esac
    stop_default=$(sed -n 's/^NIGHTLY_APP_SHARDS_STOP_SECONDS="\${NIGHTLY_APP_SHARDS_STOP_SECONDS:-\([0-9]*\)}"$/\1/p' "$NIGHTLY")
    strands_stop=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import testbed_strands as t; print(int(t.TERM_GRACE_S + 5.0))' "$SCRIPT_DIR")
    [ -n "$stop_default" ] && [ -n "$strands_stop" ] && [ "$stop_default" -gt "$strands_stop" ] \
        && pass "the watchdog's extra grace (${stop_default}s) is longer than the strand runner's TERM+KILL (${strands_stop}s)" \
        || fail "the watchdog's extra grace '${stop_default}' is not above the strand runner's stop time '${strands_stop}'"

    # ── coverage ──
    # The number is the exact union (scripts/xccov_union.py, the real one, over a fake xccov): a
    # line is covered when it ran in ANY host. Three hosts ran lines {2}, {2,3}, {2,4} of the logic
    # file's four: 3 of 4 = 75%, where no host alone has more than 2 (and Xcode's own merge, which
    # this replaces, is neither). The SwiftUI-named file is left out, as the awk leaves it out.
    rm -f "$SH/args.txt.xcrun"
    got=$(SHARD_CASE_MERGE=1 shard_case green 0)
    case "$got" in
        "0|75.000|lines|ok||"*)
            [ "$(grep -c -- '--archive --json' "$SH/args.txt.xcrun")" = 3 ] && [ "$(grep -c -- '--report --json' "$SH/args.txt.xcrun")" = 3 ] \
                && ! grep -q 'xcresulttool' "$SH/args.txt.xcrun" \
                && grep -q 'Coverage: coverage-union: 75.000% (3/4 distinct lines of VideoScan.app, logic only; union of 3 bundle(s)' "$SH/case.log" \
                && pass "coverage: the exact union over every shard's bundle (the tail's too) — 3 of 4 lines, where the best single host has 2; never xcresulttool merge" \
                || fail "coverage union calls or log line: $(cat "$SH/args.txt.xcrun"; cat "$SH/case.log")" ;;
        *) fail "coverage union on a green run: got '$got'" ;;
    esac
    got=$(SHARD_FAKE_XCCOV_FAILS=1 SHARD_CASE_MERGE=1 shard_case green 0)
    case "$got" in
        "1|null||ok||"*) grep -q 'Coverage NOT published: coverage-union: REFUSED — .*xccov view --report failed' "$SH/case.log" \
            && pass "a bundle xccov cannot read publishes no coverage number, and the log says which and why" \
            || fail "unreadable bundle was silent: $(cat "$SH/case.log")" ;;
        *) fail "unreadable bundle: got '$got'" ;;
    esac
    # A bundle from another build (its file has an executable line the others do not): no union.
    got=$(SHARD_FAKE_COV_SKEW=1 SHARD_CASE_MERGE=1 shard_case green 0)
    case "$got" in
        "1|null||ok||"*) grep -q 'Coverage NOT published: coverage-union: REFUSED — .*0001/shard.xcresult: /src/Ledger.swift has 5 executable lines, .*0000/shard.xcresult has 4' "$SH/case.log" \
            && pass "a shard whose file has other executable lines than the first shard's refuses the union (not one build): no number, the file and both bundles named" \
            || fail "a skewed denominator was not refused by name: $(cat "$SH/case.log")" ;;
        *) fail "skewed denominators: got '$got'" ;;
    esac
    got=$(SHARD_CASE_UNION_TOOL="$SH/no-such-tool.py" SHARD_CASE_MERGE=1 shard_case green 0)
    case "$got" in
        "2|null||ok||"*) pass "a checkout without scripts/xccov_union.py publishes no sharded coverage number (never Xcode's merge)" ;;
        *) fail "sharded coverage without the union tool: got '$got'" ;;
    esac
    # After the union a green shard's bundle goes (620 MB each for real); a red shard's stays.
    shard_case onered 1 > /dev/null
    kept=$( # shellcheck disable=SC1090
        source "$CORE_LIB"; NIGHTLY_APP_SHARDS_DIR="$SH/run"; prune_green_shard_bundles
        ls -d "$SH"/run/run/*/shard.xcresult 2>/dev/null | tr '\n' ' ')
    [ "$kept" = "$SH/run/run/0001/shard.xcresult " ] && [ -f "$SH/run/run/0000/strand.log" ] \
        && pass "after the union a green shard's result bundle is removed, a red shard's bundle and every log stay" \
        || fail "bundle pruning kept '$kept'"
    # The paths that never reach a summary (the watchdog, zero tests): nothing is known green, so a
    # plain prune keeps everything and `all` (what remove_test_artifacts asks on a red run) removes
    # every bundle — the logs stay.
    shard_case noverdict 1 > /dev/null
    kept=$( # shellcheck disable=SC1090
        source "$CORE_LIB"; NIGHTLY_APP_SHARDS_DIR="$SH/run"
        prune_green_shard_bundles; ls -d "$SH"/run/run/*/shard.xcresult 2>/dev/null | wc -l | tr -d ' '
        prune_green_shard_bundles all; ls -d "$SH"/run/run/*/shard.xcresult 2>/dev/null | wc -l | tr -d ' '
        [ -f "$SH/run/run/0000/strand.log" ] && echo log)
    [ "$(echo $kept)" = "1 0 log" ] \
        && pass "with no summary no bundle is known green: kept by default, all removed on the red no-summary paths, logs kept" \
        || fail "bundle pruning without a summary: '$(echo $kept)' want '1 0 log'"
    rm -f "$SH/args.txt.xcrun"
    got=$(SHARD_CASE_MERGE=1 shard_case timeout 1)
    case "$got" in
        "1|null||failed|shard-timeout:1800s|"*) [ ! -e "$SH/args.txt.xcrun" ] \
            && pass "a run with an unfinished shard is never measured: no partial coverage number" \
            || fail "an incomplete run was measured: $(cat "$SH/args.txt.xcrun")" ;;
        *) fail "incomplete run coverage: got '$got'" ;;
    esac

    # ── review 2026-11-21, round 1: R1–R5 (each seen red on fec3dc1ea) ──
    # R1 — read_app_shards_summary's `extra` match.
    # ONE parameterized Swift Testing test fails. parse_test_counts names it as the log does
    # ("parse(_:) with 20 test cases"); the bundle names the function ("parse(_:)"); no key matches,
    # so the bundle's copy is added as a second failure: failed-tests:2, two names, total one too many.
    PF='✘ Test parse(_:) recorded an issue with 1 argument value → 3 at P.swift:9:5: Expectation failed: a == b\n✘ Test parse(_:) with 20 test cases failed after 0.120 seconds with 1 issue.'
    shard_fixture r1param '{"shards":[{"passed":2,"expected":2},{"passed":1,"failed":1,"expected":2,"green":false,"rc":65}],"failures":[{"id":"GedcomDateTests/parse(_:)","name":"parse(_:)","shard":"shard-02"}]}' \
        "$P1\n$P2\n" "$P1\n$PF\n"
    got=$(shard_case r1param 1)
    want='failed|failed-tests:1|3|1|0|0|["parse(_:) with 20 test cases"]|[]|true|2'
    [ "$got" = "$want" ] && pass "R1 one failed parameterized test is one failure, named once (as one host names it)" \
        || fail "R1 parameterized failure counted twice: got '$got' want '$want'"

    # R2 — APP_SHARDS_COMPLETE left "short" out.
    # A shard that ran 1 of its 900 tests is a partial profile; the header promises "NO coverage
    # number, never a low one". It is merged and published.
    shard_fixture r2short '{"shards":[{"passed":2,"expected":2},{"passed":1,"expected":900,"green":false,"codes":["short"],"problems":["ran 1 of 900 tests"]}]}' \
        "$P1\n$P2\n" "$P1\n"
    rm -f "$SH/args.txt.xcrun"
    got=$(SHARD_CASE_MERGE=1 shard_case r2short 1)
    case "$got" in
        "1|null||failed|shard-short:1|"*) pass "R2 a shard that came up short publishes no coverage number" ;;
        *) fail "R2 a shard that ran 1 of 900 tests was merged into the coverage number: got '$got'" ;;
    esac

    # R3 — classify_nightly_test_result with tools/publish_metrics.py's WATCH rule. One test failed AND another shard's host died after 1 of
    # 900 tests (or the sharder left no verdict). The reason is the plain failed-tests:1, which the
    # page reads as "the suite ran to the end" → WATCH (yellow). The run was cut short: red.
    page_colour() { python3 - "$SCRIPT_DIR/../tools/publish_metrics.py" "$1" "$2" "$3" <<'PYC'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pm", sys.argv[1]); pm = importlib.util.module_from_spec(spec); spec.loader.exec_module(pm)
print(pm.classify_nightly_row({"status": "failed", "reason": sys.argv[2], "total": int(sys.argv[3]), "failed": int(sys.argv[4])}))
PYC
    }
    shard_fixture r3faildied '{"shards":[{"passed":1,"failed":1,"expected":2,"green":false,"rc":65},{"passed":1,"expected":900,"green":false,"rc":65,"codes":["short","died"],"problems":["xcodebuild exit 65 with no failed test (a crash, a dead test host or an xcodebuild error)","ran 1 of 900 tests"]}],"failures":[{"id":"LedgerTests/ledgerKeepsEveryRow()","name":"ledgerKeepsEveryRow()","shard":"shard-01"}]}' \
        "$P1\n$F1\n" "$P2\n"
    got=$(shard_case r3faildied 1)
    reason=$(printf '%s' "$got" | cut -d'|' -f2); names=$(printf '%s' "$got" | cut -d'|' -f7)
    colour=$(page_colour "$reason" 3 1)
    [ "$colour" = "red" ] && [ "$names" = '["ledgerKeepsEveryRow()"]' ] \
        && pass "R3 a failed test beside a dead shard: the page is red and the failure is still named" \
        || fail "R3 a failed test beside a shard that ran 1 of 900: reason '$reason' reads '$colour' on the page (899 tests never ran)"
    shard_fixture r3noverdict - "$P1\n$F1\n"
    got=$(shard_case r3noverdict 130)
    reason=$(printf '%s' "$got" | cut -d'|' -f2); colour=$(page_colour "$reason" 2 1)
    [ "$colour" = "red" ] && pass "R3b a failed test in the logs of a sharder that left no verdict: red" \
        || fail "R3b the sharder died (rc 130, no summary) with one failed test in its partial logs: reason '$reason' reads '$colour'"

    # R4 — short was asked before died.
    # fan_in codes a dead host BOTH died and short (it always ran fewer than declared), so
    # shard-died is unreachable for the case it is named for; the row says "short".
    shard_fixture r4died '{"shards":[{"passed":2,"expected":2},{"passed":1,"expected":900,"green":false,"rc":65,"codes":["short","died"],"problems":["xcodebuild exit 65 with no failed test","ran 1 of 900 tests"]}]}' \
        "$P1\n$P2\n" "$P1\n"
    got=$(shard_case r4died 1)
    case "$got" in
        "failed|shard-died:1|"*) pass "R4 a host that died is shard-died by name" ;;
        *) fail "R4 a host that died (codes short+died, as fan_in writes them) is published as: '$got'" ;;
    esac

    # R5 — the summary was not checked against the run.
    # Three hosts wrote logs; the summary lists two shards. Trusted: ok, and coverage merged.
    shard_fixture r5fewer '{"shards":[{"passed":1,"expected":1},{"passed":1,"expected":1}]}' "$P1\n" "$P2\n" "$P1\n$P2\n"
    got=$(shard_case r5fewer 0)
    case "$got" in
        "ok|"*) fail "R5 a summary naming 2 shards for a run of 3 hosts is published green: '$got'" ;;
        *) pass "R5 a summary that does not account for every host is not green" ;;
    esac

    # ── review 2026-11-21, round 2: RED-1, RED-2 (each seen red on 77e82ef03) ──
    # RED-1 — APP_SHARDS_COMPLETE ignored undealable_files.
    # Two files could not be dealt to any host: their tests ran nowhere. The header promises "NO coverage
    # number, never a low one" for a run that did not run its whole plan; this one is merged and published.
    shard_fixture v2undeal '{"undealable_files":2,"verdict":"RED","shards":[{"passed":1,"expected":1},{"passed":1,"expected":1}]}' "$P1\n" "$P2\n"
    got=$(SHARD_CASE_MERGE=1 shard_case v2undeal 1)
    case "$got" in
        "1|null|"*"|failed|shard-undealable:2|"*) pass "RED-1 a run with undealable files publishes no coverage number" ;;
        *) fail "RED-1 two test files ran in no host and the union is still published as the suite's coverage: got '$got'" ;;
    esac

    # RED-2 — `union_app_shards_coverage || true` then an unconditional prune_green_shard_bundles.
    # The union REFUSES (host 1's bundle has other executable lines). That is the one night someone must open
    # the bundles; every shard is green, so the very next line deletes all of them.
    shard_fixture v2skew '{"shards":[{"passed":1,"expected":1},{"passed":1,"expected":1}]}' "$P1\n" "$P2\n"
    left=$(
        source "$CORE_LIB"; log() { :; }
        export SHARD_FAKE_FIX="$SH/fix/v2skew" SHARD_FAKE_RC=0 SHARD_FAKE_ARGS="$SH/args.txt" SHARD_FAKE_COV_SKEW=1
        export NIGHTLY_XCRUN="$SH/bin/xcrun" VIDEOSCAN_NIGHTLY_COVERAGE_UNION="$SCRIPT_DIR/xccov_union.py"
        NIGHTLY_ON_DEMAND=0; NIGHTLY_TEST_TIMEOUT_SECONDS=60; NIGHTLY_APP_SHARDS_DIR="$SH/run"
        NIGHTLY_APP_SHARDS_TIMINGS="$SH/timings.json"; NIGHTLY_TEST_LOG="$SH/app-test.log"; NIGHTLY_XCRESULT="$SH/merged.xcresult"
        HOME="$SH/home"; NIGHTLY_APP_SHARDS_USED=true
        run_app_tests_sharded "$SH/bin/xctest_shards.py" /dd/Build/Products 8 > /dev/null
        parse_test_counts "$NIGHTLY_TEST_LOG"; read_app_shards_summary "$NIGHTLY_APP_SHARDS_DIR/summary.json"
        # collect_optional_post_test_metrics' sharded lines, the very text of the nightly:
        eval "$(sed -n '/^        if union_app_shards_coverage; then$/,/^        fi$/p' "$NIGHTLY")" > /dev/null
        printf '%s|%s' "$COV_LOGIC" "$(ls -d "$SH"/run/run/*/shard.xcresult 2>/dev/null | wc -l | tr -d ' ')"
    )
    [ "$left" = "null|2" ] && pass "RED-2 a refused union keeps the bundles it refused" \
        || fail "RED-2 the union refused and the bundles that would say why are gone: coverage|bundles left = '$left' (want null|2)"
    grep -q "Coverage: the shards' result bundles are kept for a look: " "$NIGHTLY" \
        && [ "$(grep -c '^        if union_app_shards_coverage; then$' "$NIGHTLY")" = 1 ] \
        && [ "$(grep -c '^        union_app_shards_coverage || true$' "$NIGHTLY")" = 0 ] \
        && pass "the nightly prunes green bundles only after a union that returned 0, and says where a refused union's bundles are" \
        || fail "the prune is not conditional on the union in nightly_local_tests.sh"
    # app_test_hosts is the hosts that ran at once: 2 parallel shards and a tail here, though 8 were asked for.
    got=$(shard_case green 0)
    [ "${got##*|}" = 2 ] && pass "app_test_hosts is the number of hosts that actually ran side by side (2 of the 8 asked for), the tail not counted" \
        || fail "app_test_hosts: got '${got##*|}' want 2 ($got)"

    # A host killed mid-line leaves its log without a newline: the next host's first line must
    # not be glued to it (an XCTest verdict line is anchored at the line start: glued, it is lost).
    shard_fixture nonewline '{"shards":[{"passed":1,"expected":1},{"passed":1,"expected":1}]}' "$P1\n◇ Test cut() star" "$PX\n"
    got=$(shard_case nonewline 0)
    [ "$got" = 'ok||2|0|0|0|[]|[]|true|2' ] && [ "$(grep -c '^Test Case ' "$SH/run/hosts.log")" = 1 ] \
        && ! grep -q 'counts trued up' "$SH/case.log" \
        && pass "a shard log that ends mid-line is closed with a newline in the join: the next host's first verdict line stays a line (the logs alone count both tests)" \
        || fail "log join without a newline guard: got '$got' ($(cat "$SH/case.log"))"
    # On a watchdog stop the hosts still running are named, each with the test it was in.
    shard_fixture stopnames '{"shards":[{"passed":1,"expected":1},{"passed":1,"expected":1}]}' \
        "# strand shard-01: xcodebuild …\n$P1\n** TEST EXECUTE SUCCEEDED **\n" "# strand serial-tail: xcodebuild …\n$P2\n◇ Test hundredThousandRows() started.\n"
    got=$(
        export SHARD_FAKE_HOST_STOP=0.2 SHARD_FAKE_HOST_PID="$SH/host.pid"
        export NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS=1 NIGHTLY_APP_SHARDS_STOP_SECONDS=1
        SHARD_CASE_TIMEOUT=2 shard_case stopnames 0
    )
    kill "$(cat "$SH/host.pid" 2>/dev/null)" 2>/dev/null || true
    case "$got" in
        "failed|test-timeout:2s|2|0|0|0|"*)
            grep -q 'App shards at the watchdog stop: serial-tail had not finished (.*/0001/strand.log); last test started: ◇ Test hundredThousandRows() started.' "$SH/case.log" \
                && ! grep -q 'watchdog stop: shard-01' "$SH/case.log" \
                && pass "a watchdog stop names each host that had not finished and the test it was running; a finished host is not named" \
                || fail "watchdog stop did not name the running host: $(cat "$SH/case.log")" ;;
        *) fail "watchdog stop naming: got '$got'" ;;
    esac
fi

# ── the ladder itself, with a shard reason ──
ladder() {   # timed_out total failed ui_hung rc crashed shard_reason → status|reason
    ( # shellcheck disable=SC1090
      source "$WATCHDOG_LIB"
      classify_nightly_test_result "$1" 7200 "$2" "$3" "$4" "$5" "$6" "${7:-}"
      printf '%s|%s' "$STATUS" "$REASON" )
}
ladder_ok=yes
while IFS='~' read -r args want; do
    [ -z "$args" ] && continue
    # shellcheck disable=SC2086
    got=$(ladder $args)
    [ "$got" = "$want" ] || { ladder_ok=no; fail "ladder($args): got '$got' want '$want'"; }
done <<'LAD'
false 100 0 false 0 0~ok|
true 100 3 false 1 0 shard-timeout:1800s~failed|test-timeout:7200s
false 0 0 false 1 0 shard-timeout:1800s~failed|shard-timeout:1800s
false 100 3 false 1 2 shard-timeout:1800s~failed|shard-timeout:1800s
false 0 0 false 1 0 shard-died:2~failed|zero-tests-ran:test-rc=1
false 100 3 false 1 2 shard-short:1~failed|shard-short:1
false 100 0 false 1 2 shard-short:1~failed|shard-short:1
false 100 3 false 1 0 shard-died:1~failed|shard-died:1
false 100 3 false 1 0 shard-no-verdict~failed|shard-no-verdict
false 100 3 false 1 0 shard-summary-mismatch~failed|shard-summary-mismatch
false 100 3 false 65 2~failed|failed-tests:3
false 100 0 false 65 2~failed|crashed-tests:2
false 100 0 true 1 0 shard-died:1~failed|shard-died:1
false 100 0 false 0 0 shard-unproven:1~failed|shard-unproven:1
false 100 0 true 65 0~failed|ui-runner-hung
false 100 0 false 65 0~failed|test-rc:65
LAD
[ "$ladder_ok" = yes ] && pass "verdict ladder: watchdog > shard-timeout > zero tests > every other shard reason (an incomplete run) > failed > crashed > runner-hang > rc; unchanged without a shard reason"
codes_ok=$(python3 - "$SCRIPT_DIR/../tools/publish_metrics.py" <<'PYCODES'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pm", sys.argv[1]); pm = importlib.util.module_from_spec(spec); spec.loader.exec_module(pm)
codes = ["shard-timeout:1800s", "shard-short:1", "shard-died:2", "shard-unproven:1", "shard-undealable:1", "shard-no-verdict",
         "shard-red", "shard-summary-mismatch"]
row = lambda r, failed: {"status": "failed", "reason": r, "total": 100, "failed": failed}
# red with no failed test, and red with ONE (which a plain failed-tests:1 would read as yellow "watch")
print("yes" if all(pm.reason_code(c) == c and pm.classify_nightly_row(row(c, n)) == "red" for c in codes for n in (0, 1)) else "no")
PYCODES
)
[ "$codes_ok" = "yes" ] && pass "every shard reason survives the publisher and reads red with or without a failed test (a run cut short, never yellow or green)" \
    || fail "a shard reason is rejected or miscoloured by the publisher"

# ── how many hosts, and the fallback ──
jobs_case() {   # NIGHTLY_APP_JOBS value ("" = unset) → the count
    ( # shellcheck disable=SC1090
      source "$CORE_LIB"
      printf '%s\n' '#!/bin/sh' 'echo 16' > "$SH/bin/sysctl"; chmod +x "$SH/bin/sysctl"
      PATH="$SH/bin:$PATH"
      if [ -n "$1" ]; then NIGHTLY_APP_JOBS="$1"; else unset NIGHTLY_APP_JOBS; fi
      nightly_app_jobs )
}
got="$(jobs_case "")|$(jobs_case 1)|$(jobs_case 4)|$(jobs_case 0)|$(jobs_case many)"
rm -f "$SH/bin/sysctl"
[ "$got" = "8|1|4|1|8" ] && pass "hosts: half the cores by default (16 → 8), NIGHTLY_APP_JOBS as given, 0 → 1, not a number → the default" \
    || fail "nightly_app_jobs: got '$got' want '8|1|4|1|8'"
usable() { ( source "$CORE_LIB"; app_shards_usable "$1" && echo yes || echo no ); }
printf 'import sys\nprint("an xctest_shards.py from before the nightly wiring")\n' > "$SH/old_shards.py"
got="$(usable "$SH/bin/xctest_shards.py")|$(usable "$SH/old_shards.py")|$(usable "$SH/no-such.py")|$(usable "$SCRIPT_DIR/xctest_shards.py")"
[ "$got" = "yes|no|no|yes" ] && pass "only a sharder that writes the nightly summary is used: an older copy or none is the single host; this checkout's qualifies" \
    || fail "app_shards_usable: got '$got' want 'yes|no|no|yes'"
# The single host is the command it always was, byte for byte — plus the sealed
# home (TEST_RUNNER_*, 72cc6ee4e): the test host never sees the real App Support.
SINGLE=$(awk '/^# ── Test ──/ {seen=1} seen && /^run_with_process_group_watchdog \\$/ {on=1} on {print} on && /^    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=$/ {exit}' "$NIGHTLY")
WANT_SINGLE='run_with_process_group_watchdog \
    "$NIGHTLY_TEST_TIMEOUT_SECONDS" \
    "$NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS" \
    "$NIGHTLY_TEST_LOG" \
    env TEST_RUNNER_HOME="$APP_HOME" TEST_RUNNER_CFFIXED_USER_HOME="$APP_HOME" \
    TEST_RUNNER_TMPDIR="$APP_HOME/tmp/" TEST_RUNNER_VIDEOSCAN_TEST_TMP="$APP_HOME/tmp/" \
    xcodebuild test-without-building \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration "$NIGHTLY_CONFIGURATION" \
    -destination '"'"'platform=macOS,arch=arm64'"'"' \
    -derivedDataPath "$NIGHTLY_DD" \
    -enableCodeCoverage YES \
    -resultBundlePath "$NIGHTLY_XCRESULT" \
    -skip-testing:VideoScanUITests \
    ENABLE_TESTABILITY=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS='
[ "$SINGLE" = "$WANT_SINGLE" ] && pass "the single-host command is unchanged, byte for byte (the fallback)" \
    || fail "the single-host test command changed: $SINGLE"
GATE_LINE=$(grep -n '^if \[ "\$APP_JOBS" -gt 1 \] && app_shards_usable "\$APP_SHARDS_SCRIPT"; then$' "$NIGHTLY" | cut -d: -f1)
SHARD_CALL_LINE=$(grep -n '^    run_app_tests_sharded "\$APP_SHARDS_SCRIPT" "\$NIGHTLY_DD/Build/Products" "\$APP_JOBS"$' "$NIGHTLY" | cut -d: -f1)
SINGLE_LINE=$(grep -n '^    xcodebuild test-without-building \\$' "$NIGHTLY" | cut -d: -f1)
READ_LINE=$(grep -n '^    read_app_shards_summary "\$NIGHTLY_APP_SHARDS_DIR/summary.json"$' "$NIGHTLY" | cut -d: -f1)
PARSE_LINE=$(grep -n '^parse_test_counts "\$NIGHTLY_TEST_LOG"$' "$NIGHTLY" | cut -d: -f1)
CLASSIFY19_LINE=$(grep -n '"\$TOTAL" "\$FAILED" "\$UI_RUNNER_HUNG" "\$TEST_RC" "\${CRASHED:-0}" "\$APP_SHARD_REASON"$' "$NIGHTLY" | cut -d: -f1)
if [ -n "$GATE_LINE" ] && [ -n "$SHARD_CALL_LINE" ] && [ -n "$SINGLE_LINE" ] && [ -n "$READ_LINE" ] && [ -n "$PARSE_LINE" ] && [ -n "$CLASSIFY19_LINE" ] \
    && [ "$GATE_LINE" -lt "$SHARD_CALL_LINE" ] && [ "$SHARD_CALL_LINE" -lt "$SINGLE_LINE" ] \
    && [ "$SINGLE_LINE" -lt "$PARSE_LINE" ] && [ "$PARSE_LINE" -lt "$READ_LINE" ] && [ "$READ_LINE" -lt "$CLASSIFY19_LINE" ] \
    && grep -q '^APP_SHARDS_SCRIPT="\${VIDEOSCAN_NIGHTLY_APP_SHARDS:-\$REPO/scripts/xctest_shards.py}"$' "$NIGHTLY" \
    && grep -q '^if \$NIGHTLY_APP_SHARDS_USED && ! \$TEST_TIMED_OUT; then$' "$NIGHTLY" \
    && [ "$(grep -A2 '^        if union_app_shards_coverage; then$' "$NIGHTLY" | grep -c '^            prune_green_shard_bundles$')" = 1 ] \
    && [ "$(grep -c 'xcresulttool merge' <(grep -v '^ *#' "$NIGHTLY"))" = 0 ] \
    && [ "$(grep -B3 '^    exit 1$' "$NIGHTLY" | grep -c '^    \$NIGHTLY_APP_SHARDS_USED && remove_test_artifacts$')" = 1 ]; then
    pass "wiring: K hosts only past the gate (jobs > 1 and a usable sharder of the checkout under test), else the single host; parse, then the bundles' true-up (never after the watchdog), then the ladder with the shard reason"
else
    fail "sharded app-phase wiring moved (gate=$GATE_LINE shards=$SHARD_CALL_LINE single=$SINGLE_LINE parse=$PARSE_LINE read=$READ_LINE classify=$CLASSIFY19_LINE)"
fi
# The row: app_test_hosts only when the phase was sharded.
row_case() {   # sharded? → the row
    ( # shellcheck disable=SC1090
      source "$CORE_LIB"
      HOST=h BRANCH=b COMMIT=c COMMIT_DATE=d DIRTY=false PASSED=5 FAILED=0 SKIPPED=1 TOTAL=6 KNOWN_ISSUE_TESTS=0
      ELAPSED=7 STATUS=ok REASON="" NIGHTLY_SCRIPT_VERSION=test NIGHTLY_CONFIGURATION=Release FAILED_NAMES_JSON='[]'
      COV_LOGIC=null CRASHED_NAMES_JSON='[]' NIGHTLY_APP_SHARDS_USED="$1" APP_TEST_HOSTS=8
      make_current_test_result_row | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("app_test_hosts"), r["passed"], r["status"])' )
}
got="$(row_case true)|$(row_case false)"
[ "$got" = "8 5 ok|None 5 ok" ] && pass "the row says how many test hosts ran the app phase (app_test_hosts), and a single-host row keeps its exact shape" \
    || fail "row app_test_hosts: got '$got'"
# Coverage in the row: the ruler is named, and a single host's old-ruler number rides along.
cov_row() {   # COV_LOGIC COV_BASIS COV_LOGIC_REPORT → coverage_logic_pct|coverage_basis|coverage_logic_report_pct
    ( # shellcheck disable=SC1090
      source "$CORE_LIB"
      HOST=h BRANCH=b COMMIT=c COMMIT_DATE=d DIRTY=false PASSED=5 FAILED=0 SKIPPED=1 TOTAL=6 KNOWN_ISSUE_TESTS=0
      ELAPSED=7 STATUS=ok REASON="" NIGHTLY_SCRIPT_VERSION=test NIGHTLY_CONFIGURATION=Release FAILED_NAMES_JSON='[]'
      CRASHED_NAMES_JSON='[]' NIGHTLY_APP_SHARDS_USED=false COV_LOGIC="$1" COV_BASIS="$2" COV_LOGIC_REPORT="$3"
      make_current_test_result_row | python3 -c 'import json,sys; r=json.load(sys.stdin); print("|".join(str(r.get(k)) for k in ("coverage_logic_pct", "coverage_basis", "coverage_logic_report_pct")))' )
}
got="$(cov_row 79.017 lines 72.238) $(cov_row 79.022 lines null) $(cov_row 72.238 "" null) $(cov_row null lines 72.238)"
want="79.017|lines|72.238 79.022|lines|None 72.238|None|None None|None|None"
[ "$got" = "$want" ] && pass "the row names the coverage ruler (coverage_basis lines), carries a single host's function-summed number beside it, and a row with no number carries neither" \
    || fail "coverage row fields: got '$got' want '$want'"
# One bundle through the same tool (the single host's path): the union of one, plus the bundle's
# own report number for the same files.
one=$( # shellcheck disable=SC1090
    source "$CORE_LIB"
    log() { printf '%s\n' "$*" >> "$SH/case.log"; }
    : > "$SH/case.log"
    export SHARD_FAKE_ARGS="$SH/args.txt" NIGHTLY_XCRUN="$SH/bin/xcrun" VIDEOSCAN_NIGHTLY_COVERAGE_UNION="$SCRIPT_DIR/xccov_union.py"
    NIGHTLY_XCRESULT="$SH/one.xcresult" COV_LOGIC=null COV_BASIS=""
    union_coverage "$SH/run/run/0000/shard.xcresult"; printf '%s|%s|%s' "$?" "$COV_LOGIC" "$COV_BASIS")
if [ "$one" = "0|25.000|lines" ]; then
    grep -q "the bundle's own report (function-summed): " "$SH/case.log" \
        && pass "a single bundle is measured by the same tool on the same ruler ($one), and the log shows Xcode's function-summed number beside it" \
        || fail "single-bundle coverage did not log the report's number: $(cat "$SH/case.log")"
else
    fail "single-bundle coverage: got '$one'"
fi
UNION_CALL=$(grep -c '^        union_coverage /tmp/nightly-results.xcresult$' "$NIGHTLY")
[ "$UNION_CALL" = 1 ] && pass "the single host's bundle goes through union_coverage too: one ruler whatever K is" \
    || fail "the single-host coverage path does not call union_coverage ($UNION_CALL)"

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
