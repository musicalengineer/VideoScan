#!/usr/bin/env bash
# Process-group watchdog, sourced (2026-10-01).
#
# Lifted verbatim from scripts/nightly_local_tests.sh so the nightly
# adversarial review's red-test confirm step (tools/adversarial_confirm.py)
# runs its swift test / xcodebuild calls under the SAME supervisor the 2 AM
# nightly trusts. nightly_local_tests.sh sources this file; behaviour there is
# unchanged. Sets NIGHTLY_WATCHDOG_DID_TIMEOUT=true after a deadline kill and
# returns 124.
#
#   source scripts/lib/process_group_watchdog.sh
#   run_with_process_group_watchdog <timeout_s> <term_grace_s> <output_log> <command> [args...]

#
# Optional, for one call (prefix the call with them; unset = old behaviour):
#   VIDEOSCAN_WATCHDOG_STALL_SECONDS=<n>  also stop the command when its output
#       log has not grown for n seconds (a hung test, found in minutes rather
#       than at the deadline). Sets NIGHTLY_WATCHDOG_STALLED=true.
#   VIDEOSCAN_WATCHDOG_SAMPLE_FILE=<path> before TERM on a stall or deadline,
#       `sample` every live process in the group (3 s each) into <path>, so
#       the hung stack is on disk after the kill (2026-10-22: a Core hang left
#       only a log cut at a 16 KB buffer boundary).
# NIGHTLY_WATCHDOG_TIMEOUT_KIND is "deadline" or "stall:<n>s" after a stop.

NIGHTLY_WATCHDOG_DID_TIMEOUT=${NIGHTLY_WATCHDOG_DID_TIMEOUT:-false}
NIGHTLY_WATCHDOG_STALLED=${NIGHTLY_WATCHDOG_STALLED:-false}
NIGHTLY_WATCHDOG_TIMEOUT_KIND=${NIGHTLY_WATCHDOG_TIMEOUT_KIND:-}

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
    NIGHTLY_WATCHDOG_STALLED=false
    NIGHTLY_WATCHDOG_TIMEOUT_KIND=""

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
stall = float(os.environ.get("VIDEOSCAN_WATCHDOG_STALL_SECONDS") or 0)
sample_path = os.environ.get("VIDEOSCAN_WATCHDOG_SAMPLE_FILE") or ""
stop_kind = "deadline"


def wait_watching_output(output):
    """child.wait(timeout), but also give up when the output log stops
    growing for `stall` seconds. Polls once a second (C++: a condition
    wait with a timeout, re-armed whenever the file size moves)."""
    global stop_kind
    start = time.monotonic()
    last_size, last_change = -1, start
    while True:
        rc = child.poll()
        if rc is not None:
            return rc
        now = time.monotonic()
        size = os.fstat(output.fileno()).st_size
        if size != last_size:
            last_size, last_change = size, now
        if now - start >= timeout:
            raise subprocess.TimeoutExpired(command, timeout)
        if now - last_change >= stall:
            stop_kind = "stall:%ds" % int(stall)
            raise subprocess.TimeoutExpired(command, timeout)
        time.sleep(1.0)


def sample_group(pgid):
    """Record the stacks of every live group member before the kill. Bounded:
    pgrep 10 s, each sample 60 s. A failure here never blocks the kill."""
    try:
        pids = subprocess.run(["pgrep", "-g", str(pgid)], capture_output=True,
                              text=True, timeout=10).stdout.split()
    except Exception as error:
        pids = []
        note = "pgrep failed: %s\n" % error
    else:
        note = "group %d members: %s\n" % (pgid, " ".join(pids) or "(none)")
    with open(sample_path, "w", encoding="utf-8") as out:
        out.write("watchdog %s stop at %s\n%s" % (stop_kind, time.strftime("%Y-%m-%d %H:%M:%S"), note))
    for pid in pids:
        part = "%s.%s" % (timeout_marker, pid)
        try:
            subprocess.run(["/usr/bin/sample", pid, "3", "-file", part],
                           capture_output=True, timeout=60)
            with open(part, encoding="utf-8", errors="replace") as src, \
                 open(sample_path, "a", encoding="utf-8") as out:
                out.write("\n===== sample of pid %s =====\n" % pid)
                out.write(src.read())
        except Exception as error:
            with open(sample_path, "a", encoding="utf-8") as out:
                out.write("\n===== sample of pid %s failed: %s =====\n" % (pid, error))


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
        if stall > 0:
            sys.exit(wait_watching_output(output))
        sys.exit(child.wait(timeout=timeout))
    except subprocess.TimeoutExpired:
        with open(timeout_marker, "w", encoding="utf-8") as marker:
            marker.write(stop_kind)
        if sample_path:
            sample_group(child.pid)

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
        NIGHTLY_WATCHDOG_TIMEOUT_KIND=$(cat "$timeout_file" 2>/dev/null)
        case "$NIGHTLY_WATCHDOG_TIMEOUT_KIND" in
            stall:*) NIGHTLY_WATCHDOG_STALLED=true ;;
        esac
    fi
    rm -rf "$state_dir"
    return "$command_rc"
}
