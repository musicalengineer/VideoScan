#!/bin/bash
#
# Nightly TestDriver metrics runner for VideoScan
# Scheduled via launchd to run at 2:00 AM daily
# Prevents sleep during execution with caffeinate
#
# Install: bash /Users/rickb/dev/VideoScan/.claude/scripts/install-nightly.sh
# Uninstall: launchctl unload ~/.launchagents/com.rick.videoscan.testdriver.plist
# Test: /Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh
# Status: launchctl list | grep videoscan.testdriver
# Logs: tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log
#

set -euo pipefail

PROJECT_DIR="/Users/rickb/dev/VideoScan"
TESTDRIVER_DIR="$PROJECT_DIR/TestDriver"
LOG_DIR="$HOME/Library/Logs/VideoScan"
LOG_FILE="$LOG_DIR/nightly-testdriver.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Timestamp function
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Log to both stdout and file
log() {
    echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"
}

log "Starting nightly TestDriver run (PID: $$)"

# Ensure we don't sleep during execution
exec caffeinate -i bash -c '
    set -euo pipefail

    PROJECT_DIR="/Users/rickb/dev/VideoScan"
    TESTDRIVER_DIR="$PROJECT_DIR/TestDriver"
    LOG_DIR="$HOME/Library/Logs/VideoScan"
    LOG_FILE="$LOG_DIR/nightly-testdriver.log"

    log() {
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOG_FILE"
    }

    cd "$PROJECT_DIR" || exit 1

    # Ensure we'"'"'re on main branch
    log "Fetching latest main..."
    git fetch origin main >/dev/null 2>&1 || log "Warning: git fetch failed"

    # Build TestDriver
    log "Building TestDriver (release mode)..."
    cd "$TESTDRIVER_DIR"
    swift build -c release >> "$LOG_FILE" 2>&1 || {
        log "ERROR: TestDriver build failed"
        exit 1
    }

    TESTDRIVER_BIN="$TESTDRIVER_DIR/.build/release/TestDriver"

    # Run tests and publish metrics
    log "Running full test suite (Smoke + Diagnostic)..."
    cd "$PROJECT_DIR"

    # TestDriver publishes metrics by default
    "$TESTDRIVER_BIN" \
        --host m4 \
        --suite Smoke \
        --suite Diagnostic \
        >> "$LOG_FILE" 2>&1

    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        log "✅ Nightly run completed successfully"
    else
        log "❌ Nightly run failed (exit code: $EXIT_CODE)"
    fi
    exit $EXIT_CODE
'
