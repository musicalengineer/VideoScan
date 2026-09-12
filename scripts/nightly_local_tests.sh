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
#
#   2026-08-28 (post-nightly-updates-r1):
#     - After the result row is published or durably queued, run Homebrew,
#       Claude, and Codex updates. Update failures remain advisory and cannot
#       replace the already-recorded nightly verdict or its exit status.
#
#   2026-08-30 (xcodebuild-watchdog-r3):
#     - Build and test xcodebuild invocations run in private process groups
#       behind hard deadlines. Timeout rows take precedence over ordinary
#       return codes and zero-test discovery, so metrics publication remains
#       mandatory even when a removable-volume read wedges in the kernel.

set -u

NIGHTLY_SCRIPT_VERSION="2026-09-12-hallie-replay-r6"
REPO="$HOME/dev/VideoScan"
LOGDIR="$HOME/Library/Logs/VideoScan"
LOGFILE="$LOGDIR/nightly_test_$(date +%Y%m%d_%H%M%S).log"
PENDING_QUEUE="$LOGDIR/nightly-pending.jsonl"
METRICS_WT="/tmp/nightly-metrics-wt"
PERSON_EVAL_MANIFEST="${VIDEOSCAN_PERSON_EVAL_MANIFEST:-$REPO/output/person-eval-private/nightly/manifest.json}"
PERSON_EVAL_REPORT="${VIDEOSCAN_PERSON_EVAL_REPORT:-$REPO/output/person-eval-private/nightly/latest-report.json}"
PERSON_METRICS_JSON='{"person_eval_status":"not-configured","person_eval_reason":"quality-holdout-not-configured","person_eval_readiness_pct":0,"person_eval_readiness_band":"red","person_eval_publish_eligible":false,"person_eval_quality_score":null,"poi_cycle_stream_status":"not-collected"}'
# The Hallie replay lane (2026-09-08, Rick: "I thought we had an automated
# hallie testbed"). Every row carries it, so a night where the replay never
# ran says "not-run" in the row rather than showing nothing at all.
HALLIE_REPLAY_JSON='{"hallie_replay_status":"not-run","hallie_strict_status":"not-run","hallie_advisory_status":"not-run"}'
# 2026-09-11: the clean DEBUG build of the test target took 1,645 s on the M4 on
# 9/10 and was killed at 1,800 s on 9/11 (M1 too, same tree) — the night published
# ZERO tests. 3,600 s is MITIGATION so a build within normal variance cannot trip
# the watchdog; the underlying slowdown is not yet explained (candidates: the
# uncommitted Package.resolved bump swift-collections 1.5.1→1.6.0 / swift-jinja
# 2.3.6→2.5.0 forcing package rebuilds; test-target growth). Evidence: codex
# #1322/#1323. The watchdog still catches a hung build.
NIGHTLY_BUILD_TIMEOUT_SECONDS="${VIDEOSCAN_NIGHTLY_BUILD_TIMEOUT_SECONDS:-3600}"
NIGHTLY_TEST_TIMEOUT_SECONDS="${VIDEOSCAN_NIGHTLY_TEST_TIMEOUT_SECONDS:-7200}"
NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS="${VIDEOSCAN_NIGHTLY_TERM_GRACE_SECONDS:-10}"
NIGHTLY_WATCHDOG_DID_TIMEOUT=false

mkdir -p "$LOGDIR"
exec > "$LOGFILE" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

nightly_timeout_reason() { printf '%s-timeout:%ss' "$1" "$2"; }

# Run one command in a private process group with a hard deadline.
#
# One foreground Python supervisor owns the child from Popen through deadline
# handling. start_new_session gives xcodebuild a private PGID, and retaining the
# unreaped Popen child reserves that numeric PID/PGID until after TERM/KILL, so
# no second shell actor can signal a recycled process group. A child that still
# cannot be reaped after KILL is reported as contamination; the supervisor exits
# 124 promptly rather than blocking metrics publication in waitpid.
# Args: timeout_seconds term_grace_seconds output_log command [args...]
run_with_process_group_watchdog() {
    local timeout_seconds="$1"
    local grace_seconds="$2"
    local output_log="$3"
    shift 3

    local state_dir timeout_file command_rc
    state_dir=$(mktemp -d "${TMPDIR:-/tmp}/videoscan-nightly-watchdog.XXXXXX") || return 125
    timeout_file="$state_dir/timeout"
    : > "$output_log"
    NIGHTLY_WATCHDOG_DID_TIMEOUT=false

    python3 -c '
import errno
import os
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
grace = float(sys.argv[2])
output_path = sys.argv[3]
timeout_marker = sys.argv[4]
command = sys.argv[5:]
test_immediate = os.environ.get("VIDEOSCAN_WATCHDOG_TEST_TIMEOUT_IMMEDIATELY") == "1"
test_ready = os.environ.get("VIDEOSCAN_WATCHDOG_TEST_DEADLINE_READY_FILE")
test_unreapable = os.environ.get("VIDEOSCAN_WATCHDOG_TEST_UNREAPABLE") == "1"
pre_signal_ready = os.environ.get("VIDEOSCAN_WATCHDOG_TEST_PRE_SIGNAL_READY_FILE")
pre_signal_release = os.environ.get("VIDEOSCAN_WATCHDOG_TEST_PRE_SIGNAL_RELEASE_FILE")

with open(output_path, "wb") as output:
    child = subprocess.Popen(
        command,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        if test_immediate:
            limit = time.monotonic() + 2.0
            while test_ready and not os.path.exists(test_ready) and time.monotonic() < limit:
                if child.poll() is not None:
                    sys.exit(child.returncode)
                time.sleep(0.01)
            raise subprocess.TimeoutExpired(command, timeout)
        sys.exit(child.wait(timeout=timeout))
    except subprocess.TimeoutExpired:
        with open(timeout_marker, "w", encoding="utf-8"):
            pass

        # Test-only rendezvous: let a child exit after the deadline but before
        # signaling. It stays unreaped here, so its PID/PGID cannot be reused.
        if pre_signal_ready:
            with open(pre_signal_ready, "w", encoding="utf-8"):
                pass
        if pre_signal_release:
            limit = time.monotonic() + 2.0
            while not os.path.exists(pre_signal_release) and time.monotonic() < limit:
                time.sleep(0.01)
            if os.path.exists(pre_signal_release):
                time.sleep(0.05)

        def signal_group(sig):
            try:
                os.killpg(child.pid, sig)
                return True
            except OSError as error:
                # Darwin reports EPERM as well as ESRCH for an empty group
                # whose unreaped leader remains reserved by this supervisor.
                if error.errno in (errno.ESRCH, errno.EPERM):
                    return False
                raise

        term_delivered = signal_group(signal.SIGTERM)
        if term_delivered and grace > 0:
            # Do not waitpid/poll here: even if the leader exits on TERM, it
            # stays unreaped and reserves the numeric PID/PGID while descendants
            # receive their full grace interval.
            time.sleep(grace)

        group_alive = signal_group(0)
        if group_alive:
            signal_group(signal.SIGKILL)

        if not test_unreapable and group_alive:
            # Retain the leader while KILL propagates, so every group probe is
            # immune to numeric PGID reuse. Never waitpid until the group is
            # empty; a kernel-blocked member therefore cannot wedge publication.
            kill_deadline = time.monotonic() + 1.0
            while signal_group(0) and time.monotonic() < kill_deadline:
                time.sleep(0.01)
            group_alive = signal_group(0)

        if not test_unreapable and not group_alive:
            try:
                child.wait(timeout=0.1)
                sys.exit(124)
            except subprocess.TimeoutExpired:
                pass

        print(
            f"CONTAMINATION: watchdog could not reap PID/PGID {child.pid} "
            "after TERM/KILL; supervisor is detaching",
            file=sys.stderr,
            flush=True,
        )
        sys.exit(124)
' "$timeout_seconds" "$grace_seconds" "$output_log" "$timeout_file" "$@"
    command_rc=$?
    if [ -e "$timeout_file" ]; then
        NIGHTLY_WATCHDOG_DID_TIMEOUT=true
    fi
    rm -rf "$state_dir"
    return "$command_rc"
}

# One precedence function owns the published test verdict. In particular, a
# watchdog timeout is never rewritten as zero-tests-ran or a normal test rc.
#
# 2026-09-07 (r4): THE EXIT CODE IS EVIDENCE, NOT DECORATION. A test host that
#   TRAPS (SIGTRAP/EXC_BREAKPOINT — a force-unwrap of nil, a precondition) never
#   prints a per-test failure line, so `failed` stayed 0 while xcodebuild
#   returned 65 and listed the dead tests in its own "Failing tests:" block.
#   `test_rc` was already a parameter here, but was read only inside the
#   total-eq-0 branch, so the night of 2026-09-07 published
#   status=ok / passed=6830 / failed=0 for a run that had died five times
#   (HallieAppositionVitalsTests force-unwrapped tree.people["I2"]; GEDCOM ids
#   carry their at-signs). Nine hours of green that never happened.
#   Two new rungs close the class:
#     * `crashed` — tests named in the "Failing tests:" block that produced no
#       failure line of their own. This outranks ui-runner-hung: a real crash is
#       never excused by a hung UI runner.
#     * a nonzero `test_rc` that NOTHING else explained now fails closed. The
#       text scrapers are best-effort; the exit code is the contract.
#   ui_runner_hung keeps its rung ABOVE the bare-rc rule on purpose — that hang
#   is a KNOWN-benign source of nonzero rc whose unit counts are still honest,
#   and it stays ok exactly as before.
# Args: timed_out timeout_seconds total failed ui_runner_hung test_rc [crashed]
classify_nightly_test_result() {
    local timed_out="$1"
    local timeout_seconds="$2"
    local total="$3"
    local failed="$4"
    local ui_runner_hung="$5"
    local test_rc="$6"
    local crashed="${7:-0}"
    STATUS="ok"
    REASON=""
    if $timed_out; then
        STATUS="failed"
        REASON=$(nightly_timeout_reason test "$timeout_seconds")
    elif [ "$total" -eq 0 ]; then
        STATUS="failed"
        REASON="zero-tests-ran:test-rc=$test_rc"
    elif [ "$failed" -gt 0 ]; then
        STATUS="failed"
        REASON="failed-tests:$failed"
    elif [ "$crashed" -gt 0 ]; then
        STATUS="failed"
        REASON="crashed-tests:$crashed"
    elif $ui_runner_hung; then
        REASON="ui-runner-hung"
    elif [ "$test_rc" -ne 0 ]; then
        STATUS="failed"
        REASON="test-rc:$test_rc"
    fi
}

# Run developer-tool maintenance only after publish_row has returned, which
# means the result row is either on origin/metrics or in the durable local
# pending queue. Its result is deliberately advisory: update failures are
# logged here but never replace the night's recorded test verdict or exit code.
run_dev_updater_if_recorded() {
    local publish_rc="$1"
    local rc
    if [ "$publish_rc" -ne 0 ] && [ "$publish_rc" -ne 1 ]; then
        log "ERROR: nightly result was neither published nor queued; post-nightly maintenance will not run."
        return 0
    fi
    log "Nightly result recorded; starting post-nightly developer-tool maintenance."
    "$REPO/scripts/dev_updater.sh"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "WARNING: post-nightly developer-tool maintenance failed (rc=$rc); nightly verdict is unchanged."
    fi
    return 0
}

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
    BASE_ROW="$1" PERSON_ROW="$PERSON_METRICS_JSON" HALLIE_ROW="${HALLIE_REPLAY_JSON:-}" python3 -c '
import json, os
base = json.loads(os.environ["BASE_ROW"])
base.update(json.loads(os.environ["PERSON_ROW"]))
# The Hallie replay lane rides in the same row, and like the person lane it
# may only ADD fields: it can never touch status, reason or the test counts.
# Empty when unset — the shell default is NOT "{}" because ${v:-{}} closes
# the expansion at the first brace and appends a stray "}" (caught by
# test_nightly_failure_modes.sh 9b: "Extra data" at column 125).
hallie = json.loads(os.environ["HALLIE_ROW"] or "{}")
for key in ("status", "reason", "passed", "failed", "skipped", "total"):
    hallie.pop(key, None)
base.update(hallie)
print(json.dumps(base, separators=(",", ":")))
'
}

# Build and publish the current parsed test result. COV_LOGIC="null" omits the
# coverage field. Keeping this path callable before any optional post-test work
# is what lets a watchdog timeout durably record partial counts immediately.
make_current_test_result_row() {
    local ts cov_field="" crashed_field=""
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    if [ "$COV_LOGIC" != "null" ]; then
        cov_field=",\"coverage_logic_pct\":$COV_LOGIC"
    fi
    # Additive, and present ONLY when tests actually died — a green row keeps
    # the exact shape every existing dashboard consumer already parses.
    if [ "${CRASHED_NAMES_JSON:-[]}" != "[]" ]; then
        crashed_field=",\"crashed_names\":${CRASHED_NAMES_JSON}"
    fi
    printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"%s","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":%s,"passed":%d,"failed":%d,"skipped":%d,"total":%d,"elapsed_s":%.3f,"status":"%s","reason":"%s","nightly_script_v":"%s","failed_names":%s%s}' \
        "$ts" "$HOST" "$BRANCH" "$COMMIT" "$COMMIT_DATE" "$DIRTY" \
        "$PASSED" "$FAILED" "$SKIPPED" "$TOTAL" \
        "$ELAPSED" "$STATUS" "$REASON" "$NIGHTLY_SCRIPT_VERSION" \
        "$FAILED_NAMES_JSON" "${cov_field}${crashed_field}"
}

publish_current_test_result() {
    local row
    row=$(with_person_metrics "$(make_current_test_result_row)")
    publish_row "$row"
    PUBLISH_RC=$?
}

# Timeout publication is deliberately tiny: no xcresult traversal, live person
# evaluator, or other optional work can run before publish_row has returned.
record_timed_out_test_result() {
    COV_LOGIC="null"
    publish_current_test_result
}

# Optional post-test work is kept behind orchestrate_post_test_result so the
# actual timeout branch can be exercised without invoking xccov or the live
# person evaluator. Neither command is part of the durable-row critical path.
collect_optional_post_test_metrics() {
    COV_LOGIC="null"
    if [ -d /tmp/nightly-results.xcresult ]; then
        log "xcresult exists, extracting coverage..."
        xcrun xccov view --report --only-targets /tmp/nightly-results.xcresult 2>&1 \
            | head -5 | while read -r line; do log "  xccov: $line"; done
        LOGIC_NUMS=$(xcrun xccov view --report --files-for-target VideoScan.app \
            /tmp/nightly-results.xcresult 2>/dev/null \
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

    PERSON_EVAL_APP="$NIGHTLY_DD/Build/Products/Debug/VideoScan.app/Contents/MacOS/VideoScan"
    refresh_person_metrics "$PERSON_EVAL_APP"
    refresh_hallie_replay "$PERSON_EVAL_APP"
}

# Replay Rick's recorded Hallie questions through the freshly built app and
# the model host, and carry the verdict in the row. Rick, 2026-09-07: "I
# thought we had an automated hallie testbed to identify and prevent
# regressions?" — the recorder and the harness existed; nothing ran them.
# Advisory to the TEST verdict by construction (with_person_metrics strips
# status/reason/counts from the merged lane), but conspicuous on its own:
# hallie_replay_status is ok | failed | incomplete | not-run, and the strict
# lane's pass/fail/incomplete counts are separate from the advisory corpus.
# Budget-bounded and watchdog-wrapped so a hung model host cannot hold the
# row past the 04:30 reviewer; an overrun is INCOMPLETE with its completed
# count, never a small subset presented as the whole (codex #1189).
refresh_hallie_replay() {
    local app="$1"
    local out="/tmp/nightly-hallie-replay.json"
    local budget="${NIGHTLY_HALLIE_BUDGET_SECONDS:-3600}"
    if [ ! -x "$app" ]; then
        log "Hallie replay skipped: no app binary at $app"
        HALLIE_REPLAY_JSON='{"hallie_replay_status":"not-run","hallie_replay_reason":"no-app-binary","hallie_strict_status":"not-run","hallie_advisory_status":"not-run"}'
        return 0
    fi
    rm -f "$out"
    # HOST AND MODEL ARE THE REPLAY SCRIPT'S TO DEFAULT (2026-09-12): the M4's
    # own ollama at 127.0.0.1 and the app's selected brain (Rick's ruling,
    # codex #1359 — Hallie tests run on the M4). This function used to pin
    # ricksm5 here, and the night of 09/11->12 found the M5 asleep at 02:xx
    # and published nothing. Only an explicit override is passed through:
    # VIDEOSCAN_HALLIE_REPLAY_HOST / _MODEL (the replay script's names) or
    # the older NIGHTLY_HALLIE_HOST / _MODEL, for a manual run against the M5.
    local host="${VIDEOSCAN_HALLIE_REPLAY_HOST:-${NIGHTLY_HALLIE_HOST:-}}"
    local model="${VIDEOSCAN_HALLIE_REPLAY_MODEL:-${NIGHTLY_HALLIE_MODEL:-}}"
    log "Hallie replay: strict manifest + advisory corpus, budget ${budget}s, host ${host:-http://127.0.0.1:11434 (the M4's own ollama, replay default)}, model ${model:-the app's selected brain (replay default)}"
    run_with_process_group_watchdog         $((budget + 180)) "$NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS"         "$LOGFILE.hallie-replay"         "$REPO/scripts/nightly_hallie_replay.sh"             --out "$out" --bin "$app"             ${host:+--host "$host"}             ${model:+--model "$model"}             --budget-seconds "$budget"
    local rc=$?
    if [ -s "$out" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
        HALLIE_REPLAY_JSON=$(cat "$out")
        log "Hallie replay: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("hallie_replay_status"), "strict", d.get("hallie_strict_pass"), "/", d.get("hallie_strict_expected"), "advisory", d.get("hallie_advisory_pass"), "/", d.get("hallie_advisory_expected"))' "$out") (rc=$rc)"
    else
        # A launch failure before any artifact is INCOMPLETE, never green and
        # never absent (codex #1191).
        log "Hallie replay produced no readable artifact (rc=$rc); recording incomplete"
        HALLIE_REPLAY_JSON="{\"hallie_replay_status\":\"incomplete\",\"hallie_replay_reason\":\"no-artifact-rc-$rc\",\"hallie_strict_status\":\"incomplete\",\"hallie_advisory_status\":\"not-run\"}"
    fi
    return 0
}

# Return 124 after recording a timeout row, 2 for the existing zero-test path,
# or 0 after normal optional metrics. Timeout is checked first by construction.
orchestrate_post_test_result() {
    local timed_out="$1"
    local total="$2"
    if $timed_out; then
        log "FATAL: test watchdog expired; recording partial counts before optional metrics"
        record_timed_out_test_result
        return 124
    fi
    if [ "$total" -eq 0 ]; then
        return 2
    fi
    collect_optional_post_test_metrics
    return 0
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
#         1 if push failed and the new row was durably appended to
#           PENDING_QUEUE for the next run to retry,
#         2 if neither remote publication nor the local queue append worked.
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
            if queue_pending "$new_row"; then
                return 1
            fi
            return 2
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
        if queue_pending "$new_row"; then
            return 1
        fi
        return 2
    fi
}

# Append a row to the local pending-rows queue. The next successful
# publish_row call will drain it.
queue_pending() {
    local row="$1"
    if ! printf '%s\n' "$row" >> "$PENDING_QUEUE"; then
        log "ERROR: could not append nightly result row to $PENDING_QUEUE"
        return 1
    fi
    log "  queued row to $PENDING_QUEUE (size now $(wc -l < "$PENDING_QUEUE" | tr -d ' ') rows)"
    return 0
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
    local build_log="/tmp/nightly-build-output.log"
    run_with_process_group_watchdog \
        "$NIGHTLY_BUILD_TIMEOUT_SECONDS" \
        "$NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS" \
        "$build_log" \
        xcodebuild build-for-testing \
        -project VideoScan/VideoScan.xcodeproj \
        -scheme VideoScan \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$NIGHTLY_DD" \
        -enableCodeCoverage YES \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= \
        -quiet
    local rc=$?
    tail -10 "$build_log" 2>/dev/null || true
    return "$rc"
}

log "Building..."
BUILD_START=$(date +%s)
run_nightly_build
BUILD_RC=$?
BUILD_TIMED_OUT=$NIGHTLY_WATCHDOG_DID_TIMEOUT
if $BUILD_TIMED_OUT; then
    log "FATAL: build timed out after ${NIGHTLY_BUILD_TIMEOUT_SECONDS}s"
    publish_row "$(with_person_metrics "$(make_status_row failed "$(nightly_timeout_reason build "$NIGHTLY_BUILD_TIMEOUT_SECONDS")" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    PUBLISH_RC=$?
    run_dev_updater_if_recorded "$PUBLISH_RC"
    exit 1
elif [ "$BUILD_RC" -ne 0 ]; then
    log "Build failed (rc=$BUILD_RC) — wiping DerivedData and retrying once (stale-module-cache guard)"
    rm -rf "$NIGHTLY_DD"
    run_nightly_build
    BUILD_RC=$?
    BUILD_TIMED_OUT=$NIGHTLY_WATCHDOG_DID_TIMEOUT
fi

if $BUILD_TIMED_OUT; then
    log "FATAL: clean-retry build timed out after ${NIGHTLY_BUILD_TIMEOUT_SECONDS}s"
    publish_row "$(with_person_metrics "$(make_status_row failed "$(nightly_timeout_reason build "$NIGHTLY_BUILD_TIMEOUT_SECONDS")" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    PUBLISH_RC=$?
    run_dev_updater_if_recorded "$PUBLISH_RC"
    exit 1
elif [ "$BUILD_RC" -ne 0 ]; then
    log "FATAL: build failed after clean retry (rc=$BUILD_RC)"
    publish_row "$(with_person_metrics "$(make_status_row failed "build-rc:$BUILD_RC" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    PUBLISH_RC=$?
    run_dev_updater_if_recorded "$PUBLISH_RC"
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
# A private-process-group watchdog guarantees this call returns to the
# publication path even if xcodebuild or a test blocks in a kernel read.
run_with_process_group_watchdog \
    "$NIGHTLY_TEST_TIMEOUT_SECONDS" \
    "$NIGHTLY_WATCHDOG_TERM_GRACE_SECONDS" \
    /tmp/nightly-test-output.log \
    xcodebuild test-without-building \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$NIGHTLY_DD" \
    -enableCodeCoverage YES \
    -resultBundlePath /tmp/nightly-results.xcresult \
    -skip-testing:VideoScanUITests \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS=
TEST_RC=$?
TEST_TIMED_OUT=$NIGHTLY_WATCHDOG_DID_TIMEOUT
cat /tmp/nightly-test-output.log 2>/dev/null || true
TEST_END=$(date +%s)
ELAPSED=$((TEST_END - TEST_START))
if $TEST_TIMED_OUT; then
    log "Tests hit hard timeout after ${NIGHTLY_TEST_TIMEOUT_SECONDS}s (rc=$TEST_RC)"
else
    log "Tests completed in ${ELAPSED}s (rc=$TEST_RC)"
fi

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
    parse_crashed_tests "$out"
}

# Tests that DIED rather than failed. A trap takes the host down before any
# per-test terminal line is printed, so the only place these names ever appear
# is xcodebuild's own trailing block:
#
#     Failing tests:
#     	HallieAppositionVitalsTests.theAsideSpeaksTheCorrectedYear()
#
#     ** TEST EXECUTE FAILED **
#
# That block also lists ordinary failures, which parse_test_counts has already
# counted — double-counting them would inflate the row. Entries are matched
# against the counted names by their bare method token, because the block is
# suite-qualified ("Suite.method()") while a Swift Testing failure line is not
# ("method()"). Sets CRASHED and CRASHED_NAMES_JSON; both are empty on a run
# where every failure announced itself normally.
parse_crashed_tests() {
    local out="$1"
    local parsed
    parsed=$(NIGHTLY_LOG="$out" COUNTED_NAMES="$FAILED_NAMES_JSON" python3 -c '
import json, os, sys

def token(name):
    """Reduce a test name to its bare method token for cross-shape matching."""
    n = name.strip().rstrip(".")
    if n.startswith("-[") or n.startswith("+["):
        n = n[2:].rstrip("]").split()[-1]        # -[Suite method] -> method
    elif "." in n:
        n = n.rsplit(".", 1)[-1]                  # Suite.method() -> method()
    return n.rstrip("()")

try:
    counted = {token(n) for n in json.loads(os.environ["COUNTED_NAMES"])}
except Exception:
    counted = set()

crashed, in_block = [], False
try:
    with open(os.environ["NIGHTLY_LOG"], errors="replace") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped == "Failing tests:":
                in_block = True
                continue
            if not in_block:
                continue
            # The block ends at the first line that is not an indented entry.
            if not stripped or not line[:1].isspace() or stripped.startswith("**"):
                in_block = False
                continue
            if token(stripped) not in counted:
                crashed.append(stripped)
except OSError:
    pass

names = sorted(set(crashed))
print(len(names))
print(json.dumps(names))
' 2>/dev/null)
    CRASHED=$(printf '%s\n' "$parsed" | sed -n '1p')
    CRASHED_NAMES_JSON=$(printf '%s\n' "$parsed" | sed -n '2p')
    case "$CRASHED" in
        ''|*[!0-9]*) CRASHED=0; CRASHED_NAMES_JSON='[]' ;;
    esac
    CRASHED_NAMES_JSON=${CRASHED_NAMES_JSON:-[]}
}

parse_test_counts /tmp/nightly-test-output.log
TOTAL=$((PASSED + FAILED + SKIPPED))
log "Results: ${PASSED}p / ${FAILED}f / ${SKIPPED}s (${TOTAL} total)"
[ "$FAILED" -gt 0 ] && log "Failed tests: $FAILED_NAMES_JSON"
[ "${CRASHED:-0}" -gt 0 ] && log "Crashed tests (host died, no failure line): $CRASHED_NAMES_JSON"

# Look for the UI test runner timeout/hang marker — the unit-test pass
# count is still honest, but we want the row to flag this so a sudden
# pass-count drop isn't blamed on the wrong thing.
UI_RUNNER_HUNG=false
if grep -qE 'test runner hung|Timed out while enabling automation' /tmp/nightly-test-output.log 2>/dev/null; then
    UI_RUNNER_HUNG=true
    log "Note: UI test runner hung/timed out (unit-test count is still valid)"
fi

classify_nightly_test_result \
    "$TEST_TIMED_OUT" "$NIGHTLY_TEST_TIMEOUT_SECONDS" \
    "$TOTAL" "$FAILED" "$UI_RUNNER_HUNG" "$TEST_RC" "${CRASHED:-0}"

orchestrate_post_test_result "$TEST_TIMED_OUT" "$TOTAL"
POST_TEST_ROUTE_RC=$?
if [ "$POST_TEST_ROUTE_RC" -eq 124 ]; then
    run_dev_updater_if_recorded "$PUBLISH_RC"
    rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
    exit 1
fi

if [ "$POST_TEST_ROUTE_RC" -eq 2 ]; then
    log "SKIP: no tests ran (likely build issue or test discovery fail)"
    publish_row "$(with_person_metrics "$(make_status_row "$STATUS" "$REASON" "$DIRTY" "$COMMIT" "$COMMIT_DATE" "$BRANCH")")"
    PUBLISH_RC=$?
    run_dev_updater_if_recorded "$PUBLISH_RC"
    exit 1
fi

# Note on TEST_RC: non-zero is expected when any test fails. Classification
# above is driven by the parsed result, except that a hard timeout always wins.

# ── Publish JSON row (matches TestDriver MetricsPublisher format) ───
# "failed_names" is additive; make_current_test_result_row also includes
# coverage only when the normal, non-timeout extraction produced it.
publish_current_test_result
run_dev_updater_if_recorded "$PUBLISH_RC"

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
