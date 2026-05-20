#!/usr/bin/env bash
# nightly_local_tests.sh — Run all VideoScan tests with coverage at 10pm,
# publish results to metrics/testdriver.jsonl on the metrics branch.
#
# Designed to run unattended via launchd. Logs to ~/Library/Logs/VideoScan/.
# Exit silently on pre-condition failures (dirty tree, not on main, etc.)

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

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    log "SKIP: on branch '$BRANCH', not main"
    exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    log "SKIP: working tree is dirty"
    exit 0
fi

# Sync with origin
git fetch origin main --quiet
BEHIND=$(git rev-list --count HEAD..origin/main)
if [ "$BEHIND" -gt 0 ]; then
    log "Pulling $BEHIND commits from origin/main..."
    git pull --ff-only origin main --quiet || { log "FATAL: pull failed"; exit 1; }
fi
AHEAD=$(git rev-list --count origin/main..HEAD)
if [ "$AHEAD" -gt 0 ]; then
    log "SKIP: local is $AHEAD commits ahead of origin/main"
    exit 0
fi

COMMIT=$(git rev-parse --short HEAD)
COMMIT_DATE=$(git log -1 --format=%Y-%m-%d)
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
    CODE_SIGNING_ALLOWED=NO \
    -quiet 2>&1 | tail -5

if [ "${PIPESTATUS[0]:-$?}" -ne 0 ]; then
    log "FATAL: build failed"
    exit 1
fi
BUILD_END=$(date +%s)
log "Build done in $((BUILD_END - BUILD_START))s"

# ── Test ────────────────────────────────────────────────────────────
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
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee /tmp/nightly-test-output.log || true
TEST_END=$(date +%s)
ELAPSED=$((TEST_END - TEST_START))
log "Tests completed in ${ELAPSED}s"

# ── Parse results ───────────────────────────────────────────────────
# Swift Testing markers
PASSED=$(grep -cE '^(✔ Test |Test Case .*passed)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
FAILED=$(grep -cE '^(✘ Test .*failed|Test Case .*failed)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
SKIPPED=$(grep -cE '^(◇ Test .*skipped|Test Case .*skipped)' /tmp/nightly-test-output.log 2>/dev/null || echo 0)
TOTAL=$((PASSED + FAILED + SKIPPED))
log "Results: ${PASSED}p / ${FAILED}f / ${SKIPPED}s (${TOTAL} total)"

if [ "$TOTAL" -eq 0 ]; then
    log "SKIP: no tests ran (likely build issue)"
    exit 0
fi

# ── Coverage ────────────────────────────────────────────────────────
COV_LOGIC="null"
if [ -d /tmp/nightly-results.xcresult ]; then
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

# ── Determine host name ─────────────────────────────────────────────
HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname -s)
case "$HOSTNAME" in
    *[Ss]tudio*) HOST="Mac Studio (local)" ;;
    *[Bb]ook*[Pp]ro*) HOST="MacBook Pro (local)" ;;
    *) HOST="$HOSTNAME" ;;
esac

# ── Build JSON row (matches TestDriver MetricsPublisher format) ─────
TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
COV_FIELD=""
if [ "$COV_LOGIC" != "null" ]; then
    COV_FIELD=",\"coverage_logic_pct\":$COV_LOGIC"
fi

ROW=$(printf '{"ts":"%s","source":"nightly-local","host":"%s","branch":"main","commit":"%s","commit_date":"%s","app_version":"1.0","dirty":false,"passed":%d,"failed":%d,"skipped":%d,"total":%d,"elapsed_s":%.3f%s}' \
    "$TS" "$HOST" "$COMMIT" "$COMMIT_DATE" \
    "$PASSED" "$FAILED" "$SKIPPED" "$TOTAL" \
    "$ELAPSED" "$COV_FIELD")
log "Row: $ROW"

# ── Publish to metrics branch ───────────────────────────────────────
log "Publishing to metrics branch..."

git fetch origin metrics --quiet 2>/dev/null

# Set up worktree for metrics branch
if [ -d "$METRICS_WT/.git" ] || [ -f "$METRICS_WT/.git" ]; then
    CURRENT_BR=$(git -C "$METRICS_WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$CURRENT_BR" = "metrics" ]; then
        git -C "$METRICS_WT" pull --ff-only origin metrics --quiet 2>/dev/null \
            || git -C "$METRICS_WT" reset --hard origin/metrics --quiet
    else
        git worktree remove --force "$METRICS_WT" 2>/dev/null
        rm -rf "$METRICS_WT"
        git worktree add "$METRICS_WT" metrics 2>/dev/null
    fi
else
    rm -rf "$METRICS_WT"
    git worktree add "$METRICS_WT" metrics 2>/dev/null || {
        log "FATAL: cannot create metrics worktree"
        exit 1
    }
fi

mkdir -p "$METRICS_WT/metrics"
echo "$ROW" >> "$METRICS_WT/metrics/testdriver.jsonl"

git -C "$METRICS_WT" add metrics/testdriver.jsonl
git -C "$METRICS_WT" \
    -c user.email="nightly@videoscan" -c user.name="Nightly Tests" \
    commit -m "testdriver: nightly on $HOST — ${PASSED}p/${FAILED}f/${SKIPPED}s" --quiet 2>/dev/null

if git -C "$METRICS_WT" push origin metrics --quiet 2>/dev/null; then
    log "Published successfully."
else
    log "Push failed — retrying with rebase..."
    git -C "$METRICS_WT" pull --rebase origin metrics --quiet 2>/dev/null
    git -C "$METRICS_WT" push origin metrics --quiet 2>/dev/null \
        && log "Published on retry." \
        || log "ERROR: push to metrics branch failed after retry"
fi

# ── Cleanup ─────────────────────────────────────────────────────────
rm -rf /tmp/nightly-results.xcresult /tmp/nightly-test-output.log
log "=== Nightly test run complete ==="
