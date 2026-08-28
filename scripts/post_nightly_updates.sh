#!/usr/bin/env bash
# post_nightly_updates.sh — Refresh developer tools after nightly results are safe.
#
# This script is independently runnable, but nightly_local_tests.sh is responsible
# for calling it only after its result row has either been published or queued.
# Binary paths are injectable so regression tests never contact update services.

set -u

BREW_BIN="${VIDEOSCAN_BREW_UPDATE_BIN:-/opt/homebrew/bin/brew}"
CLAUDE_BIN="${VIDEOSCAN_CLAUDE_UPDATE_BIN:-$HOME/.local/bin/claude}"
CODEX_BIN="${VIDEOSCAN_CODEX_UPDATE_BIN:-$HOME/.local/bin/codex}"
DRY_RUN="${VIDEOSCAN_POST_NIGHTLY_DRY_RUN:-0}"
LOCK_FILE="${VIDEOSCAN_POST_NIGHTLY_LOCK_DIR:-/tmp/videoscan-post-nightly-updates.lock}"
LOCK_OWNER_PID=""

log() { echo "[$(date '+%H:%M:%S')] $*"; }

release_lock() {
    local recorded_owner=""
    [ -n "$LOCK_OWNER_PID" ] || return 0
    if [ -r "$LOCK_FILE" ]; then
        recorded_owner=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)
    fi
    if [ "$recorded_owner" = "$LOCK_OWNER_PID" ]; then
        # Only unlink the exact lock instance this process acquired. A newer
        # owner's file is never removed, even if cleanup runs late.
        rm -f "$LOCK_FILE" 2>/dev/null || true
    elif [ -e "$LOCK_FILE" ]; then
        log "WARNING: maintenance lock ownership changed; leaving $LOCK_FILE untouched."
    fi
    LOCK_OWNER_PID=""
}

install_lock_traps() {
    LOCK_OWNER_PID="$$"
    trap release_lock EXIT
    trap 'release_lock; trap - EXIT HUP INT TERM; exit 129' HUP
    trap 'release_lock; trap - EXIT HUP INT TERM; exit 130' INT
    trap 'release_lock; trap - EXIT HUP INT TERM; exit 143' TERM
}

acquire_lock() {
    # shlock uses an atomic link(2) operation and safely arbitrates multiple
    # simultaneous stale-lock recoverers. Exactly one contender can replace a
    # dead owner's lock; all others observe the newly live PID and stand down.
    if /usr/bin/shlock -f "$LOCK_FILE" -p "$$" 2>/dev/null; then
        install_lock_traps
        return 0
    fi

    local owner=""
    if [ -e "$LOCK_FILE" ]; then
        if [ ! -r "$LOCK_FILE" ] || [ ! -f "$LOCK_FILE" ]; then
            log "ERROR: maintenance lock is unreadable or contains an invalid owner pid: $LOCK_FILE"
            return 1
        fi
        owner=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)
        case "$owner" in
            ''|*[!0-9]*)
                log "ERROR: maintenance lock is unreadable or contains an invalid owner pid: $LOCK_FILE"
                return 1
                ;;
            *)
                if kill -0 "$owner" 2>/dev/null; then
                    log "Post-nightly maintenance already running as pid $owner; skipping duplicate invocation."
                    return 10
                fi
                ;;
        esac
    fi

    # shlock deliberately observes a dead lock for one second before removing
    # it, ensuring that its timestamp is stable. Retry after that observation
    # window. Atomic link(2) still guarantees one winner among all recoverers.
    sleep 1
    if /usr/bin/shlock -f "$LOCK_FILE" -p "$$" 2>/dev/null; then
        install_lock_traps
        return 0
    fi

    # A losing shlock contender can observe the brief unlink/link window of
    # the winner's stale-lock replacement. Wait for a stable owner instead of
    # misclassifying that transient absence as an infrastructure failure.
    local observe_attempt=1
    while [ "$observe_attempt" -le 20 ]; do
        if [ -e "$LOCK_FILE" ]; then
            if [ ! -r "$LOCK_FILE" ] || [ ! -f "$LOCK_FILE" ]; then
                log "ERROR: maintenance lock became unreadable or invalid: $LOCK_FILE"
                return 1
            fi
            owner=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || true)
            case "$owner" in
                ''|*[!0-9]*)
                    log "ERROR: maintenance lock contains an invalid owner pid: $LOCK_FILE"
                    return 1
                    ;;
                *)
                    if kill -0 "$owner" 2>/dev/null; then
                        log "Post-nightly maintenance lock was recovered by pid $owner; skipping duplicate invocation."
                        return 10
                    fi
                    ;;
            esac
        fi
        sleep 0.05
        observe_attempt=$((observe_attempt + 1))
    done

    log "ERROR: could not acquire post-nightly maintenance lock: $LOCK_FILE"
    return 1
}

run_update() {
    local label="$1"
    local binary="$2"
    shift 2

    if [ "$DRY_RUN" = "1" ]; then
        log "DRY RUN: $binary $*"
        return 0
    fi
    if [ ! -x "$binary" ]; then
        log "ERROR: $label update binary is missing or not executable: $binary"
        return 1
    fi

    log "Starting $label update: $binary $*"
    "$binary" "$@"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        log "$label update completed successfully."
    else
        log "ERROR: $label update failed (rc=$rc); continuing with remaining updates."
    fi
    return "$rc"
}

run_homebrew_maintenance() {
    local subcommand
    local rc
    for subcommand in update upgrade doctor cleanup; do
        run_update "Homebrew" "$BREW_BIN" "$subcommand"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            log "Skipping remaining Homebrew maintenance because 'brew $subcommand' failed."
            return "$rc"
        fi
    done
    return 0
}

acquire_lock
LOCK_RC=$?
case "$LOCK_RC" in
    0) ;;
    10)
        # A legitimate duplicate is advisory success: the active process owns it.
        exit 0
        ;;
    *) exit 1 ;;
esac

log "=== Post-nightly developer-tool maintenance starting ==="
FAILURES=0
run_homebrew_maintenance || FAILURES=$((FAILURES + 1))
run_update "Claude" "$CLAUDE_BIN" update || FAILURES=$((FAILURES + 1))
run_update "Codex" "$CODEX_BIN" update || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -gt 0 ]; then
    log "=== Post-nightly maintenance completed with $FAILURES failure(s) ==="
    exit 1
fi

log "=== Post-nightly maintenance completed successfully ==="
exit 0
