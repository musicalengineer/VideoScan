#!/usr/bin/env bash
# nightly_local_tests.sh — Run all VideoScan tests with coverage at 02:00,
# publish results to metrics/testdriver.jsonl on the metrics branch.
#
# Designed to run unattended via launchd. Logs to ~/Library/Logs/VideoScan/.
#
# Hardening 2026-06-02: every exit path publishes a JSONL row with a
# `status` field (`ok`, `skipped`, or `failed`) and a `reason` string.
# Previously the script silently exited 0 on dirty tree, off-main,
# ahead-of-origin, build/test failure, or zero-test runs, leaving the
# dashboard stuck on the last successful row with no visible cue. No more
# silent failures — see CLAUDE.md "No silent failures".

set -u

REPO="$HOME/dev/VideoScan"
LOGDIR="$HOME/Library/Logs/VideoScan"
LOGFILE="$LOGDIR/nightly_test_$(date +%Y%m%d_%H%M%S).log"
METRICS_WT="/tmp/nightly-metrics-wt"

mkdir -p "$LOGDIR"
exec > "$LOGFILE" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== Nightly local test run starting ==="
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

# ── Row publisher ───────────────────────────────────────────────────
# Append one JSONL row to metrics/testdriver.jsonl on the orphan
# `metrics` branch via a worktree, then push. Safe to call from any
# exit gate. Argument is the fully-formed JSON object.
publish_row() {
    local row="$1"
    log "Publishing row: $row"

    git fetch origin metrics --quiet 2>/dev/null || true

    if [ -d "$METRICS_WT/.git" ] || [ -f "$METRICS_WT/.git" ]; then
        local current_br
        current_br=$(git -C "$METRICS_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$current_br" = "metrics" ]; then
            git -C "$METRICS_WT" pull --ff-only origin metrics --quiet 2>/dev/null \
                || git -C "$METRICS_WT" reset --hard origin/metrics --quiet
        else
            git worktree remove --force "$METRICS_WT" 2>/dev/null || true
            rm -rf "$METRICS_WT"
            git worktree add "$METRICS_WT" metrics 2>/dev/null || {
                log "ERROR: cannot create metrics worktree; row not published"
                return 1
            }
        fi
    else
        rm -rf "$METRICS_WT"
        git worktree add "$METRICS_WT" metrics 2>/dev/null || {
            log "ERROR: cannot create metrics worktree; row not published"
            return 1
        }
    fi

    mkdir -p "$METRICS_WT/metrics"
    echo "$row" >> "$METRICS_WT/metrics/testdriver.jsonl"

    git -C "$METRICS_WT" add metrics/testdriver.jsonl
    git -C "$METRICS_WT" \
        -c user.email="nightly@videoscan" -c user.name="Nightly Tests" \
        commit -m "testdriver: nightly on $HOST — $(printf %s "$row" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status","?"),d.get("reason",""))' 2>/dev/null || echo row)" \
        --quiet 2>/dev/null

    if git -C "$METRICS_WT" push origin metrics --quiet 2>/dev/null; then
        log "Published successfully."
    else
        log "Push failed — retrying with rebase..."
        git -C "$METRICS_WT" pull --rebase origin metrics --quiet 2>/dev/null
        git -C "$METRICS_WT" push origin metrics --quiet 2>/dev/null \
            && log "Published on retry." \
            || log "ERROR: push to metrics branch failed after retry"
    fi
}

# Build a status/skipped/failed row when we don't have real test results.
# Args: status reason [dirty] [commit] [commit_date]
make_status_row() {
    local status="$1"
    local reason="$2"
    local dirty="${3:-false}"
    local commit="${4:-unknown}"
    local commit_date="${5:-unknown}"
    local ts
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"main","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":%s,"passed":0,"failed":0,"skipped":0,"total":0,"elapsed_s":0,"status":"%s","reason":"%s"}' \
        "$ts" "$HOST" "$commit" "$commit_date" "$dirty" "$status" "$reason"
}

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    log "SKIP: on branch '$BRANCH', not main"
    publish_row "$(make_status_row skipped "off-main:$BRANCH")"
    exit 0
fi

# ── Dirty-tree handling ─────────────────────────────────────────────
# If all dirty files are docs/markdown/agent metadata, RUN ANYWAY but
# mark dirty=true in the row. Otherwise skip.
DIRTY=false
if ! git diff --quiet || ! git diff --cached --quiet; then
    # Collect every modified path (worktree + index, untracked excluded
    # — they shouldn't have been there anyway).
    DIRTY_FILES=$(git diff --name-only; git diff --cached --name-only)
    DIRTY_FILES=$(printf '%s\n' "$DIRTY_FILES" | sort -u | grep -v '^$' || true)
    log "Dirty files:"
    printf '%s\n' "$DIRTY_FILES" | sed 's/^/  /'

    # Are ALL dirty paths cosmetic (docs/.claude/*.md)?
    NON_COSMETIC=$(printf '%s\n' "$DIRTY_FILES" | grep -vE '^(docs/|\.claude/)|\.md$' || true)
    if [ -z "$NON_COSMETIC" ]; then
        log "Dirty files are all cosmetic (docs/.claude/*.md) — proceeding with dirty=true"
        DIRTY=true
    else
        log "SKIP: working tree dirty with non-cosmetic changes"
        REASON="dirty-tree:$(printf '%s\n' "$NON_COSMETIC" | head -3 | tr '\n' ',' | sed 's/,$//')"
        publish_row "$(make_status_row skipped "$REASON" true)"
        exit 0
    fi
fi

# Sync with origin
git fetch origin main --quiet
BEHIND=$(git rev-list --count HEAD..origin/main)
if [ "$BEHIND" -gt 0 ]; then
    log "Pulling $BEHIND commits from origin/main..."
    if ! git pull --ff-only origin main --quiet; then
        log "FATAL: pull failed"
        publish_row "$(make_status_row failed "pull-failed" "$DIRTY")"
        exit 1
    fi
fi
AHEAD=$(git rev-list --count origin/main..HEAD)
if [ "$AHEAD" -gt 0 ]; then
    log "SKIP: local is $AHEAD commits ahead of origin/main"
    publish_row "$(make_status_row skipped "ahead-of-origin:$AHEAD" "$DIRTY")"
    exit 0
fi

COMMIT=$(git rev-parse --short HEAD)
COMMIT_DATE=$(git log -1 --format=%cd --date=short)
log "Commit: $COMMIT ($COMMIT_DATE)"

# ── Build ───────────────────────────────────────────────────────────
log "Building..."
BUILD_START=$(date +%s)
xcodebuild build-for-testing \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/nightly-dd \
    -enableCodeCoverage YES \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= \
    -quiet 2>&1 | tail -5
BUILD_RC="${PIPESTATUS[0]:-$?}"

if [ "$BUILD_RC" -ne 0 ]; then
    log "FATAL: build failed (rc=$BUILD_RC)"
    publish_row "$(make_status_row failed "build-rc:$BUILD_RC" "$DIRTY" "$COMMIT" "$COMMIT_DATE")"
    exit 1
fi
BUILD_END=$(date +%s)
log "Build done in $((BUILD_END - BUILD_START))s"

# ── Test ────────────────────────────────────────────────────────────
rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
log "Running ALL tests with coverage..."
TEST_START=$(date +%s)
xcodebuild test-without-building \
    -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath /tmp/nightly-dd \
    -enableCodeCoverage YES \
    -resultBundlePath /tmp/nightly-results.xcresult \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS= \
    2>&1 | tee /tmp/nightly-test-output.log
TEST_RC="${PIPESTATUS[0]:-$?}"
TEST_END=$(date +%s)
ELAPSED=$((TEST_END - TEST_START))
log "Tests completed in ${ELAPSED}s (rc=$TEST_RC)"

# ── Parse results ───────────────────────────────────────────────────
# Swift Testing markers
PASSED=$(grep -cE '^(✔ Test |Test Case .*passed)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
FAILED=$(grep -cE '^(✘ Test .*failed|Test Case .*failed)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
SKIPPED=$(grep -cE '^(◇ Test .*skipped|Test Case .*skipped)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
TOTAL=$((PASSED + FAILED + SKIPPED))
log "Results: ${PASSED}p / ${FAILED}f / ${SKIPPED}s (${TOTAL} total)"

if [ "$TOTAL" -eq 0 ]; then
    log "SKIP: no tests ran (likely build issue or test discovery fail)"
    publish_row "$(make_status_row failed "zero-tests-ran" "$DIRTY" "$COMMIT" "$COMMIT_DATE")"
    exit 1
fi

# Note on TEST_RC: non-zero is expected when any test fails. We still want
# to publish the row with the real pass/fail counts, so we don't gate on
# TEST_RC here. We only flag "failed" status when there are actual failures.
STATUS="ok"
REASON=""
if [ "$FAILED" -gt 0 ]; then
    STATUS="failed"
    REASON="failed-tests:$FAILED"
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

# ── Build JSON row (matches TestDriver MetricsPublisher format) ─────
TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
COV_FIELD=""
if [ "$COV_LOGIC" != "null" ]; then
    COV_FIELD=",\"coverage_logic_pct\":$COV_LOGIC"
fi

ROW=$(printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"main","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":%s,"passed":%d,"failed":%d,"skipped":%d,"total":%d,"elapsed_s":%.3f,"status":"%s","reason":"%s"%s}' \
    "$TS" "$HOST" "$COMMIT" "$COMMIT_DATE" "$DIRTY" \
    "$PASSED" "$FAILED" "$SKIPPED" "$TOTAL" \
    "$ELAPSED" "$STATUS" "$REASON" "$COV_FIELD")

publish_row "$ROW"

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
log "=== Nightly test run complete ==="

# Exit code reflects test result so launchd's status is honest.
if [ "$STATUS" = "failed" ]; then
    exit 1
fi
exit 0
