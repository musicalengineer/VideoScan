#!/usr/bin/env bash
# nightly_local_tests.sh — Run all VideoScan tests with coverage at 02:00,
# publish results to metrics/testdriver.jsonl on the metrics branch.
#
# Designed to run unattended via launchd. Logs to ~/Library/Logs/VideoScan/.
#
# DESIGN PRINCIPLE: NEVER SILENTLY SKIP.
#   Between 2 AM and the time Rick wakes up, metrics/testdriver.jsonl on
#   origin/metrics MUST have a new row dated today. It can say "build failed"
#   or "tests failed" — but a row MUST be published. The dashboard's
#   staleness banner is the only signal Rick gets that something is wrong.
#
# Hardening history:
#   2026-06-02: every exit path publishes a `status`+`reason` row.
#   2026-06-14 (am): fixed grep -c idiom that crashed the parser.
#   2026-06-14 (pm) — THIS REVISION:
#     - Removed the off-main and dirty-non-cosmetic SKIP gates.
#       The job now ALWAYS runs against whatever HEAD is, tagged with
#       `dirty=true` and the branch in the `branch` field so the row tells
#       the truth (per memory project_nightly_dirty_tree_rule_change.md).
#     - publish_row gained a pending-rows queue at
#       ~/Library/Logs/VideoScan/nightly-pending.jsonl. Any row we can't
#       push (worktree creation fails, push retries exhausted) gets
#       appended there. On every successful invocation we drain the queue
#       FIRST so backlogged rows get up. This is what kept the dashboard
#       stuck on 2026-06-09 for 5 days even though the cron job was firing
#       (push fail = silent loss).
#     - publish_row now aggressively prunes a stale worktree (different
#       branch / corrupted) before giving up, and uses `git fetch --prune`
#       to keep the worktree-add path healthy.
#     - Every row now carries a `nightly_script_v` field so future me can
#       tell at a glance which version produced a given row.

#   2026-07-09 (r1):
#     - Fixed 3x-inflated FAILED count: the old pattern matched the
#       per-failure ISSUE line ("recorded an issue … Expectation failed"),
#       the per-test summary ("✘ Test x() failed after …") AND the run
#       summary ("✘ Test run with N tests failed after …") — one failing
#       test published failed:3 (digest said "failed-tests:3" on a
#       single-failure night). PASSED had the same +1 from the green run
#       summary, and SKIPPED counted "◇ … started." lines whose display
#       names merely CONTAIN the word "skipped" while missing the real
#       "➜ Test … skipped:" lines entirely. Parsing now lives in
#       parse_test_counts() (extractable by the test harness) and counts
#       only real per-test terminal lines.
#     - Rows gain an ADDITIVE "failed_names" field: JSON array of failing
#       test names, [] on green runs. No existing field renamed/removed.
#
#   2026-07-07 (r1):
#     - Skip the VideoScanUITests target at the xcodebuild level
#       (-skip-testing:VideoScanUITests). Every UI test class is already
#       skipped by VideoScan-CI.xctestplan (skippedTests since bfc1c24,
#       2026-05-29), so the runner app launched each night only to execute
#       ZERO tests — and in the 2 AM launchd context (locked screen,
#       ProcessType=Background) it cannot enable automation mode, times out
#       after 60s, forces rc=65, and stamped every green row since
#       2026-06-15 with reason:"ui-runner-hung". Skipping the target drops
#       no coverage. The UI_RUNNER_HUNG grep below stays as a sensor in
#       case the skip flag is ever removed. UI tests need an interactive
#       Aqua session with Automation/Accessibility TCC grants; if they are
#       ever re-enabled for nightly, that session problem must be solved
#       first (see docs / GH issue from 2026-07-07 investigation).

set -u

NIGHTLY_SCRIPT_VERSION="2026-07-19-poi-cycle-sensor-r1"
REPO="$HOME/dev/VideoScan"
LOGDIR="$HOME/Library/Logs/VideoScan"
LOGFILE="$LOGDIR/nightly_test_$(date +%Y%m%d_%H%M%S).log"
PENDING_QUEUE="$LOGDIR/nightly-pending.jsonl"
METRICS_WT="/tmp/nightly-metrics-wt"
PERSON_EVAL_MANIFEST="${VIDEOSCAN_PERSON_EVAL_MANIFEST:-$REPO/output/person-eval-private/nightly/manifest.json}"
PERSON_EVAL_REPORT="${VIDEOSCAN_PERSON_EVAL_REPORT:-$REPO/output/person-eval-private/nightly/latest-report.json}"
PERSON_METRICS_JSON='{"person_eval_status":"not-configured","person_eval_reason":"quality-holdout-not-configured","person_eval_readiness_pct":0,"person_eval_readiness_band":"red","person_eval_publish_eligible":false,"person_eval_quality_score":null,"poi_cycle_stream_status":"not-collected"}'

mkdir -p "$LOGDIR"
exec > "$LOGFILE" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Refresh the privacy-safe person-recognition fields. With no app argument it
# reports setup readiness only (used even on build-failure rows). After the app
# builds, pass its executable to run the configured private holdout. Evaluator
# failures never fail the main nightly suite; they become a visible orange/red
# person_eval_status in the same durable row.
refresh_person_metrics() {
    local app="${1:-}"
    local output
    local quality_flag=()
    if [ "${VIDEOSCAN_PERSON_EVAL_ALLOW_QUALITY:-0}" = "1" ]; then
        quality_flag=(--allow-quality)
    fi
    if [ -n "$app" ]; then
        output=$(python3 tools/person-eval/nightly_metrics.py \
            --manifest "$PERSON_EVAL_MANIFEST" --report "$PERSON_EVAL_REPORT" \
            --app "$app" \
            --timeout-seconds "${VIDEOSCAN_PERSON_EVAL_TIMEOUT_SECONDS:-1200}" \
            ${quality_flag[@]+"${quality_flag[@]}"} 2>>"$LOGFILE") || output=""
    else
        output=$(python3 tools/person-eval/nightly_metrics.py \
            --manifest "$PERSON_EVAL_MANIFEST" --report "$PERSON_EVAL_REPORT" \
            2>>"$LOGFILE") || output=""
    fi
    if [ -n "$output" ]; then
        PERSON_METRICS_JSON="$output"
    else
        PERSON_METRICS_JSON='{"person_eval_status":"collector-failed","person_eval_reason":"person-metrics-collector-failed","person_eval_readiness_pct":0,"person_eval_readiness_band":"red","person_eval_publish_eligible":false,"person_eval_quality_score":null,"person_eval_quality_band":null,"poi_cycle_stream_status":"collector-failed"}'
    fi
    log "Person recognition metrics: $PERSON_METRICS_JSON"
}

# Merge additive person fields into any normal/failure nightly JSON row. Python
# owns JSON escaping so private dataset names cannot corrupt the public JSONL.
with_person_metrics() {
    BASE_ROW="$1" PERSON_ROW="$PERSON_METRICS_JSON" python3 -c '
import json, os
base = json.loads(os.environ["BASE_ROW"])
base.update(json.loads(os.environ["PERSON_ROW"]))
print(json.dumps(base, separators=(",", ":")))
'
}

log "=== Nightly local test run starting (script v$NIGHTLY_SCRIPT_VERSION) ==="
log "Host: $(scutil --get ComputerName 2>/dev/null || hostname -s)"

# ── Pre-conditions ──────────────────────────────────────────────────
cd "$REPO" || { log "FATAL: cannot cd to $REPO"; exit 1; }

# ── Host detection (used by every published row) ────────────────────
HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
case "$HOSTNAME" in
    *[Ss]tudio*) HOST="Mac Studio (local)" ;;
    *[Bb]ook*[Pp]ro*) HOST="MacBook Pro (local)" ;;
    *) HOST="$HOSTNAME" ;;
esac

# ── Row publisher with backlog queue ────────────────────────────────
# Append one or more JSONL rows to metrics/testdriver.jsonl on the orphan
# `metrics` branch via a worktree, then push. Safe to call from any exit
# gate. Single argument is the fully-formed JSON object to publish NOW;
# any rows previously queued in PENDING_QUEUE are drained first.
#
# Return: 0 if everything (queued backlog + new row) landed on origin,
#         1 if push failed — in which case the unpushed rows have been
#         appended to PENDING_QUEUE for the next run to retry.
publish_row() {
    local new_row="$1"
    log "Publishing row: $new_row"

    # Always fetch with prune so stale ref state can't block worktree-add.
    git fetch origin metrics --prune --quiet 2>/dev/null || true

    # ── Establish a healthy metrics worktree ────────────────────────
    # Three cases:
    #   (a) worktree exists, on branch `metrics` → fast-forward.
    #   (b) worktree exists, on some other branch / corrupted → nuke + recreate.
    #   (c) worktree doesn't exist → create.
    local wt_ok=false
    if [ -d "$METRICS_WT/.git" ] || [ -f "$METRICS_WT/.git" ]; then
        local current_br
        current_br=$(git -C "$METRICS_WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        if [ "$current_br" = "metrics" ]; then
            if git -C "$METRICS_WT" reset --hard origin/metrics --quiet 2>/dev/null; then
                wt_ok=true
            else
                log "  worktree exists but reset to origin/metrics failed — rebuilding"
            fi
        else
            log "  worktree on unexpected branch '$current_br' — rebuilding"
        fi
    fi

    if ! $wt_ok; then
        git worktree remove --force "$METRICS_WT" 2>/dev/null || true
        rm -rf "$METRICS_WT"
        git worktree prune
        if git worktree add "$METRICS_WT" metrics 2>/dev/null \
            || git worktree add "$METRICS_WT" origin/metrics 2>/dev/null; then
            # If we attached to origin/metrics in detached HEAD, switch
            # to the branch so commit/push work.
            git -C "$METRICS_WT" checkout -B metrics origin/metrics --quiet 2>/dev/null || true
            wt_ok=true
        else
            log "ERROR: cannot create metrics worktree even after prune"
            queue_pending "$new_row"
            return 1
        fi
    fi

    mkdir -p "$METRICS_WT/metrics"

    # ── Drain pending backlog FIRST, then append new row ────────────
    # Backlog rows go in chronological order (they were appended in the
    # order they were generated). Drain in a single commit so the diff
    # is reviewable and the push is one round-trip.
    local appended_count=0
    if [ -s "$PENDING_QUEUE" ]; then
        log "  draining $(wc -l < "$PENDING_QUEUE" | tr -d ' ') queued rows from $PENDING_QUEUE"
        while IFS= read -r queued_row; do
            [ -z "$queued_row" ] && continue
            echo "$queued_row" >> "$METRICS_WT/metrics/testdriver.jsonl"
            appended_count=$((appended_count + 1))
        done < "$PENDING_QUEUE"
    fi
    echo "$new_row" >> "$METRICS_WT/metrics/testdriver.jsonl"
    appended_count=$((appended_count + 1))

    git -C "$METRICS_WT" add metrics/testdriver.jsonl
    local commit_msg
    commit_msg=$(printf %s "$new_row" | python3 -c \
        'import json,sys
try:
    d=json.load(sys.stdin)
    print(f"testdriver: nightly on {d.get(\"host\",\"?\")} — {d.get(\"status\",\"?\")} {d.get(\"reason\",\"\")}".strip())
except Exception:
    print("testdriver: nightly row")' 2>/dev/null || echo "testdriver: nightly row")
    if [ "$appended_count" -gt 1 ]; then
        commit_msg="$commit_msg (+ $((appended_count - 1)) backlogged)"
    fi

    git -C "$METRICS_WT" \
        -c user.email="nightly@videoscan" -c user.name="Nightly Tests" \
        commit -m "$commit_msg" --quiet 2>/dev/null

    # ── Push with retry-on-conflict ─────────────────────────────────
    # Up to PUSH_MAX_ATTEMPTS tries. Between attempts, pull --rebase to
    # pick up any other publisher's rows (e.g. an M1 ad-hoc run, the
    # static-analysis nightly, or the metrics collector). The `metrics`
    # branch is high-contention, so we also sleep with jittered backoff
    # between attempts — without it all retries fire within a few seconds
    # and a busy window guarantees exhaustion (see 2026-06-22 nightly).
    local push_max_attempts=6
    local push_attempt=1
    local pushed=false
    while [ $push_attempt -le $push_max_attempts ]; do
        if git -C "$METRICS_WT" push origin metrics --quiet 2>/dev/null; then
            pushed=true
            break
        fi
        # Jittered backoff: base 2s * attempt + 0–3s random jitter, so
        # concurrent publishers desynchronize instead of colliding again.
        local backoff=$(( push_attempt * 2 + (RANDOM % 4) ))
        log "  push attempt $push_attempt/$push_max_attempts failed — backing off ${backoff}s, rebasing and retrying"
        sleep "$backoff"
        git -C "$METRICS_WT" fetch origin metrics --quiet 2>/dev/null || true
        if ! git -C "$METRICS_WT" pull --rebase origin metrics --quiet 2>/dev/null; then
            # Rebase failed (conflict on jsonl — both sides appended).
            # Resolve by accepting both: re-add our row to the rebased tip.
            log "  rebase conflict — reconciling by concatenation"
            git -C "$METRICS_WT" rebase --abort 2>/dev/null || true
            git -C "$METRICS_WT" reset --hard origin/metrics --quiet
            # Replay the rows we wanted to append.
            if [ -s "$PENDING_QUEUE" ]; then
                while IFS= read -r queued_row; do
                    [ -z "$queued_row" ] && continue
                    echo "$queued_row" >> "$METRICS_WT/metrics/testdriver.jsonl"
                done < "$PENDING_QUEUE"
            fi
            echo "$new_row" >> "$METRICS_WT/metrics/testdriver.jsonl"
            git -C "$METRICS_WT" add metrics/testdriver.jsonl
            git -C "$METRICS_WT" \
                -c user.email="nightly@videoscan" -c user.name="Nightly Tests" \
                commit -m "$commit_msg" --quiet 2>/dev/null
        fi
        push_attempt=$((push_attempt + 1))
    done

    if $pushed; then
        # Backlog landed — clear the queue.
        : > "$PENDING_QUEUE"
        log "Published successfully ($appended_count row(s))."
        return 0
    else
        log "ERROR: push to metrics branch failed after $((push_attempt - 1)) attempts"
        queue_pending "$new_row"
        return 1
    fi
}

# Append a row to the local pending-rows queue. The next successful
# publish_row call will drain it.
queue_pending() {
    local row="$1"
    echo "$row" >> "$PENDING_QUEUE"
    log "  queued row to $PENDING_QUEUE (size now $(wc -l < "$PENDING_QUEUE" | tr -d ' ') rows)"
}

# Build a status/skipped/failed row when we don't have real test results.
# Args: status reason [dirty] [commit] [commit_date] [branch]
make_status_row() {
    local status="$1"
    local reason="$2"
    local dirty="${3:-false}"
    local commit="${4:-unknown}"
    local commit_date="${5:-unknown}"
    local branch="${6:-main}"
    local ts
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"%s","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":%s,"passed":0,"failed":0,"skipped":0,"total":0,"elapsed_s":0,"status":"%s","reason":"%s","nightly_script_v":"%s"}' \
        "$ts" "$HOST" "$branch" "$commit" "$commit_date" "$dirty" "$status" "$reason" "$NIGHTLY_SCRIPT_VERSION"
}

# ── Branch + dirty-tree handling (NEW POLICY 2026-06-14) ────────────
# Old policy: skip if off-main OR if dirty-tree-with-non-cosmetic-changes.
# New policy: ALWAYS run. The row's `branch` and `dirty` fields carry
# the truth; the dashboard can highlight non-main / dirty rows in a
# muted color. Never silently skip.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
log "Current branch: $BRANCH"

DIRTY=false
if ! git diff --quiet || ! git diff --cached --quiet; then
    DIRTY=true
    log "Working tree is dirty — running anyway, will tag dirty=true"
    git diff --name-only | head -20 | sed 's/^/  M /'
    git diff --cached --name-only | head -20 | sed 's/^/  S /'
fi

# Sync with origin/main. We don't gate on being IN sync, just attempt
# to fast-forward when we're behind and on main. Ahead-of-origin is
# fine — the SHA in the row makes it traceable.
git fetch origin main --quiet
if [ "$BRANCH" = "main" ]; then
    BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
    if [ "$BEHIND" -gt 0 ] && ! $DIRTY; then
        log "Pulling $BEHIND commits from origin/main..."
        git pull --ff-only origin main --quiet || log "  ff-pull failed (not fatal)"
    fi
    AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
    if [ "$AHEAD" -gt 0 ]; then
        log "Note: local is $AHEAD commits ahead of origin/main (running anyway)"
    fi
fi

COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMMIT_DATE=$(git log -1 --format=%cd --date=short 2>/dev/null || echo "unknown")
log "Commit: $COMMIT ($COMMIT_DATE)"

# Establish the pre-build readiness state. This guarantees even a build
# failure publishes the desired red 0 when no quality benchmark is configured.
refresh_person_metrics

# ── Build ───────────────────────────────────────────────────────────
# DerivedData lives under ~/Library/Caches, NOT /tmp. macOS garbage-collects
# /tmp and can leave a half-populated explicit-modules cache, which surfaces
# as `module file '…Foundation….pcm' not found` and fails the build with rc=65
# (nightly false failure 2026-06-23). A stable cache dir avoids that, and a
# clean-and-retry-once guards against any residual module-cache corruption.
NIGHTLY_DD="${HOME}/Library/Caches/videoscan-nightly-dd"

run_nightly_build() {
    xcodebuild build-for-testing \
        -project VideoScan/VideoScan.xcodeproj \
        -scheme VideoScan \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$NIGHTLY_DD" \
        -enableCodeCoverage YES \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= \
        -quiet 2>&1 | tail -10
    return "${PIPESTATUS[0]:-$?}"
}

log "Building..."
BUILD_START=$(date +%s)
run_nightly_build
BUILD_RC=$?
if [ "$BUILD_RC" -ne 0 ]; then
    log "Build failed (rc=$BUILD_RC) — wiping DerivedData and retrying once (stale-module-cache guard)"
    rm -rf "$NIGHTLY_DD"
    run_nightly_build
    BUILD_RC=$?
fi

if [ "$BUILD_RC" -ne 0 ]; then
    log "FATAL: build failed after clean retry (rc=$BUILD_RC)"
    publish_row "$(with_person_metrics "$(make_status_row failed "build-rc:$BUILD_RC" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    exit 1
fi
BUILD_END=$(date +%s)
log "Build done in $((BUILD_END - BUILD_START))s"

# ── Test ────────────────────────────────────────────────────────────
rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
log "Running ALL tests with coverage..."
log "  (VideoScanUITests target skipped: all its tests are plan-skipped, and the"
log "   locked-screen launchd session can't enable automation mode — see 2026-07-07-r1)"
TEST_START=$(date +%s)
# Trap any unexpected error during xcodebuild so we still publish.
xcodebuild test-without-building \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$NIGHTLY_DD" \
    -enableCodeCoverage YES \
    -resultBundlePath /tmp/nightly-results.xcresult \
    -skip-testing:VideoScanUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= \
    2>&1 | tee /tmp/nightly-test-output.log
TEST_RC="${PIPESTATUS[0]:-$?}"
TEST_END=$(date +%s)
ELAPSED=$((TEST_END - TEST_START))
log "Tests completed in ${ELAPSED}s (rc=$TEST_RC)"

# ── Parse results ───────────────────────────────────────────────────
# Swift Testing + XCTest markers. Extracted into a function so
# scripts/test_nightly_failure_modes.sh can source and fixture-test it.
#
# 2026-06-14 (still applies): never use `grep -cE ... || echo 0` — when
# grep matched nothing it emitted "0" AND returned 1, the `|| echo 0`
# also fired, and "0\n0" crashed the $(( )) arithmetic BEFORE a row was
# published (dashboard stuck for 5 days from 2026-06-09). grep -c always
# emits exactly one integer, even on empty input, so no fallback needed.
#
# 2026-07-09 (r1): count only REAL per-test terminal lines.
#   FAILED  old pattern matched 3 lines per Swift Testing failure:
#           the issue line   "✘ Test x() recorded an issue …: Expectation failed: …"
#           the test line    "✘ Test x() failed after 1.786 seconds with 1 issue."
#           the run summary  "✘ Test run with 2472 tests … failed after …"
#           → one failure published failed:3. Now: only " failed after "
#           per-test lines, excluding the "Test run with" summary.
#   PASSED  same +1 from "✔ Test run with … passed after …" on green runs.
#   SKIPPED the old '^◇ Test .*skipped' matched STARTED lines whose
#           display names contain the word "skipped" (9 such tests) and
#           missed the actual skip lines, which use "➜ Test … skipped:"
#           (with leading zero-width indent chars — hence no ^ anchor).
# Patterns are deliberately unanchored on the symbol markers: swift-testing
# indents nested lines with U+200B zero-width spaces, so ^-anchored ✔/➜
# patterns silently miss some per-test lines.
#
# 2026-07-09 (r2) hardenings:
#   * Issue lines are excluded by their own shape (' recorded an issue ')
#     — an expectation MESSAGE containing " failed after " (near-miss in
#     the wild: MediaFileOperationsTests.swift:556 asserts a job reached
#     .failed after the stall watchdog) must not double-count a failure
#     or inject message text into failed_names.
#   * The run-summary exclusion is pinned to the summary's real shape
#     ('Test run with <N> test…') so a test whose display name merely
#     contains the words "Test run with" still counts.
parse_test_counts() {
    local out="$1"
    PASSED=$(grep -E '(✔ Test .* passed after |^Test Case .* passed)' "$out" 2>/dev/null \
        | grep -v ' recorded an issue ' \
        | grep -Ecv 'Test run with [0-9]+ test')
    FAILED=$(grep -E '(✘ Test .* failed after |^Test Case .* failed)' "$out" 2>/dev/null \
        | grep -v ' recorded an issue ' \
        | grep -Ecv 'Test run with [0-9]+ test')
    SKIPPED=$(grep -E '(➜ Test .* skipped|^Test Case .* skipped)' "$out" 2>/dev/null \
        | grep -v ' recorded an issue ' \
        | grep -Ecv 'Test run with [0-9]+ test')
    PASSED=${PASSED:-0}
    FAILED=${FAILED:-0}
    SKIPPED=${SKIPPED:-0}
    # failed_names: JSON array of failing test names ([] on green runs).
    # python3 does the JSON escaping; on any hiccup fall back to [] so the
    # published row stays valid JSON.
    FAILED_NAMES_JSON=$(grep -E '(✘ Test .* failed after |^Test Case .* failed)' "$out" 2>/dev/null \
        | grep -v ' recorded an issue ' \
        | grep -Ev 'Test run with [0-9]+ test' \
        | sed -E -e 's/.*✘ Test (.+) failed after .*/\1/' \
                 -e "s/^Test Case '(.+)' failed.*/\1/" \
        | sort -u \
        | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))' \
        2>/dev/null)
    FAILED_NAMES_JSON=${FAILED_NAMES_JSON:-[]}
}

parse_test_counts /tmp/nightly-test-output.log
TOTAL=$((PASSED + FAILED + SKIPPED))
log "Results: ${PASSED}p / ${FAILED}f / ${SKIPPED}s (${TOTAL} total)"
[ "$FAILED" -gt 0 ] && log "Failed tests: $FAILED_NAMES_JSON"

# Look for the UI test runner timeout/hang marker — the unit-test pass
# count is still honest, but we want the row to flag this so a sudden
# pass-count drop isn't blamed on the wrong thing.
UI_RUNNER_HUNG=false
if grep -qE 'test runner hung|Timed out while enabling automation' /tmp/nightly-test-output.log 2>/dev/null; then
    UI_RUNNER_HUNG=true
    log "Note: UI test runner hung/timed out (unit-test count is still valid)"
fi

if [ "$TOTAL" -eq 0 ]; then
    log "SKIP: no tests ran (likely build issue or test discovery fail)"
    publish_row "$(with_person_metrics "$(make_status_row failed "zero-tests-ran:test-rc=$TEST_RC" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    exit 1
fi

# Note on TEST_RC: non-zero is expected when any test fails OR when the
# UI runner times out. We still want to publish the row with the real
# pass/fail counts, so we don't gate on TEST_RC. We only flag "failed"
# status when there are actual test failures.
STATUS="ok"
REASON=""
if [ "$FAILED" -gt 0 ]; then
    STATUS="failed"
    REASON="failed-tests:$FAILED"
elif $UI_RUNNER_HUNG; then
    # Unit tests passed but UI runner hung — flag it in the row but
    # don't call the run failed (the unit suite IS the source of truth).
    STATUS="ok"
    REASON="ui-runner-hung"
fi

# ── Coverage ────────────────────────────────────────────────────────
COV_LOGIC="null"
if [ -d /tmp/nightly-results.xcresult ]; then
    log "xcresult exists, extracting coverage..."
    xcrun xccov view --report --only-targets /tmp/nightly-results.xcresult 2>&1 | head -5 | while read -r line; do log "  xccov: $line"; done
    LOGIC_NUMS=$(xcrun xccov view --report --files-for-target VideoScan.app /tmp/nightly-results.xcresult 2>/dev/null \
        | awk '
            NF < 3 { next }
            $0 ~ /^--/ { next }
            $0 ~ /^ID/ { next }
            $2 ~ /(View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\.swift$/ { next }
            {
                if (match($5, /\([0-9]+\/[0-9]+\)/)) {
                    frag = substr($5, RSTART+1, RLENGTH-2)
                    split(frag, a, "/")
                    if (a[1] != "" && a[2] != "") {
                        cov += a[1]
                        tot += a[2]
                    }
                }
            }
            END {
                if (tot > 0) printf "%.3f", (cov/tot)*100
                else         printf "null"
            }')
    COV_LOGIC="${LOGIC_NUMS:-null}"
fi
log "Logic-only coverage: ${COV_LOGIC}%"

# Run the optional private benchmark only after the core test result is known.
# It has a separate bounded budget and process-group timeout, so it cannot
# orphan a VideoScan scanner. Missing config returns immediately.
PERSON_EVAL_APP="$NIGHTLY_DD/Build/Products/Debug/VideoScan.app/Contents/MacOS/VideoScan"
refresh_person_metrics "$PERSON_EVAL_APP"

# ── Build JSON row (matches TestDriver MetricsPublisher format) ─────
TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
COV_FIELD=""
if [ "$COV_LOGIC" != "null" ]; then
    COV_FIELD=",\"coverage_logic_pct\":$COV_LOGIC"
fi

# "failed_names" is ADDITIVE (2026-07-09-r1): [] on green runs. Do not
# rename/remove existing fields — the dashboard reads this schema.
ROW=$(printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"%s","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":%s,"passed":%d,"failed":%d,"skipped":%d,"total":%d,"elapsed_s":%.3f,"status":"%s","reason":"%s","nightly_script_v":"%s","failed_names":%s%s}' \
    "$TS" "$HOST" "$BRANCH" "$COMMIT" "$COMMIT_DATE" "$DIRTY" \
    "$PASSED" "$FAILED" "$SKIPPED" "$TOTAL" \
    "$ELAPSED" "$STATUS" "$REASON" "$NIGHTLY_SCRIPT_VERSION" \
    "$FAILED_NAMES_JSON" "$COV_FIELD")
ROW=$(with_person_metrics "$ROW")

publish_row "$ROW"
PUBLISH_RC=$?

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
log "=== Nightly test run complete (publish rc=$PUBLISH_RC, status=$STATUS) ==="

# Exit code reflects test result so launchd's status is honest.
# Publish failure is intentionally NOT a non-zero exit — the row sits in
# the pending queue and will be drained on the next run.
if [ "$STATUS" = "failed" ]; then
    exit 1
fi
exit 0
