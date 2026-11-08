#!/usr/bin/env bash
# m4_run.sh — run the UI test plans and/or the deep gauntlet on a test host,
# on demand, in that host's GUI session (docs/guides/operations.md).
#
#   scripts/m4_run.sh ui     [--host m4|ultra] [--ref <rev>] [--only <UITestClass>[,…]] [--wait] [--dry-run]
#   scripts/m4_run.sh deep   [--host m4|ultra] [--ref <rev>] [--wait] [--dry-run]
#   scripts/m4_run.sh all    [--host m4|ultra] [--ref <rev>] [--wait] [--dry-run]
#   scripts/m4_run.sh status [--host m4|ultra]
#
# What Rick says → what runs (from the phone, over Remote Control):
#   "run the gauntlet UI tests on the M4"       scripts/m4_run.sh ui
#   "… on the M5 Ultra"                         scripts/m4_run.sh ui --host ultra
#   "deep test on the M4" / "run the gauntlet"  scripts/m4_run.sh deep
#   "everything on the M4"                      scripts/m4_run.sh all
#   "how's the M4 run?"                         scripts/m4_run.sh status
#
# Lanes:
#   ui    Debug build-for-testing (ad-hoc signed), then the VideoScan-UI
#         (Smoke) and VideoScan-Gauntlet plans, each under a hard watchdog.
#         --only runs just those VideoScanUITests classes from the Gauntlet plan.
#   deep  scripts/run_gauntlet.sh --away --machine <m4|m5> --queue-only (the
#         runner knows only m4|m5|m1, so the Ultra runs as "m5"; --queue-only
#         keeps an on-demand run off the metrics branch).
#   all   deep, then ui.
#
# Shape. The caller (normally the Ultra) never builds anything:
#   1. resolves --ref (default `main`) to a commit;
#   2. asks the host whether a run holds its lock (refuses if so) and whether
#      it is the nightly window (01:30–06:00 host time; --force overrides);
#   3. M4 only: `git push ricksm4.local:dev/VideoScan <sha>:refs/m4run/<sha>`
#      (a new ref per commit — never a forced update, never a branch);
#   4. installs this script + m4_run_summary.py + testbed_lock.py under
#      <root>/bin/<stamp>/ on the host (per run, so a live run's runner is
#      never overwritten, and the runner does not depend on the commit under
#      test having it);
#   5. bootstraps a one-shot LaunchAgent (label <label>.<stamp>, per run: a
#      live run's agent is never booted out; finished ones are) in gui/<uid>
#      that runs `<root>/bin/<stamp>/m4_run.sh __host …`. A LaunchAgent, not
#      plain ssh: an ssh job has no window server (XCUITest needs it) and a
#      locked keychain.
# The host side takes <root>/lock (a kernel flock on fd 9, scripts/testbed_lock.py,
# shared with scripts/nightly_gauntlet.sh; held for as long as any process of the
# run lives), THEN checks the testbed worktree out at <sha> (detached; refuses a
# dirty one: M4 ~/m4run/work, Ultra ~/dev/VideoScan-wt/ultra-testbed) — every
# mutation of the shared testbed happens under the lock, so a second caller is
# refused before it can touch a live run's tree (Codex 2026-11-05) — writes
# <root>/out/<stamp>-<lane>/ {run.log, summary.txt,
# <plan>.log, <plan>.xcresult, <plan>.tests.tsv}, points <root>/latest at it,
# and prints START/OUTCOME lines into run.log. `status` reads them back.
#
# Roots: M4 ~/m4run (DerivedData ~/Library/Caches/videoscan-m4run-dd);
#        Ultra ~/ultrarun (DerivedData ~/Library/Caches/videoscan-ultrarun-dd).
#
# Worst-case resources: one Debug DerivedData per host (~15 GB), xcresult
# bundles per run (~50–300 MB each, kept; prune <root>/out by hand), and the
# watchdog budgets below in wall time.
#
# Exit: 0 started (or --wait: run GREEN or AMBER — the OUTCOME line says which) · 1 run RED / host error · 2 usage ·
#       3 busy · 4 testbed worktree not usable · 5 nightly window.
#
# Tests: tests/test_m4_run.py (argument parsing, dry-run plans, the lock, the
# summary line). Nothing in the tests touches a host.

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Watchdog budgets (seconds). A stuck privacy prompt or a hung test fails the
# plan at its budget instead of hanging the run.
BUILD_BUDGET=2400
UI_PLAN_BUDGET=1200          # VideoScan-UI (Smoke): one test, normally < 60 s
GAUNTLET_PLAN_BUDGET=3600    # VideoScan-Gauntlet: 8 classes × ≤ 300 s allowance
DEEP_BUDGET=14400            # run_gauntlet.sh: ~45 min normally
WAIT_BUDGET=21600

usage() {
    sed -n '2,8p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 2
}

die() { echo "m4_run: $*" >&2; exit "${2:-1}"; }

# ── Host configuration ────────────────────────────────────────────────────
# Same account on every fleet Mac, so $HOME names the host's home too.
host_config() {
    case "$1" in
        m4)
            H_SSH="ricksm4.local"; H_ROOT="$HOME/m4run"; H_WT="$HOME/m4run/work"
            H_DD="$HOME/Library/Caches/videoscan-m4run-dd"; H_LABEL="com.videoscan.m4run"
            H_MACHINE="m4"; H_NAME="M4" ;;
        ultra)
            H_SSH=""; H_ROOT="$HOME/ultrarun"; H_WT="$HOME/dev/VideoScan-wt/ultra-testbed"
            H_DD="$HOME/Library/Caches/videoscan-ultrarun-dd"; H_LABEL="com.videoscan.ultrarun"
            H_MACHINE="m5"; H_NAME="M5 Ultra" ;;
        *) die "unknown host '$1' (m4|ultra)" 2 ;;
    esac
    H_REPO="$HOME/dev/VideoScan"
    LOCK="$H_ROOT/lock"      # the testbed lock, shared with scripts/nightly_gauntlet.sh (take_lock below)
    # The lock helper beside this script: scripts/ in the repo for the caller,
    # <root>/bin on the host (installed by start_run beside m4_run.sh).
    LOCK_HELPER="$SCRIPT_DIR/testbed_lock.py"
}

# ── Running a command on the host (or printing it under --dry-run) ────────
on_host() {   # on_host <shell snippet>
    if [ "$DRY" = 1 ]; then
        if [ -n "$H_SSH" ]; then echo "+ ssh $H_SSH <<'SH'"; else echo "+ bash <<'SH'"; fi
        printf '%s\n' "$1" | sed 's/^/    /'
        echo "  SH"
        return 0
    fi
    if [ -n "$H_SSH" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$H_SSH" bash -s <<<"$1"
    else
        bash -s <<<"$1"
    fi
}

copy_to_host() {   # copy_to_host <local file> <host path>
    if [ "$DRY" = 1 ]; then
        echo "+ install $1 -> ${H_SSH:+$H_SSH:}$2"
        return 0
    fi
    if [ -n "$H_SSH" ]; then
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$H_SSH" "cat > '$2' && chmod +x '$2'" <"$1"
    else
        cp "$1" "$2" && chmod +x "$2"
    fi
}

# Lock state as one line: "FREE" or "BUSY <info>" — the same kernel truth
# take_lock uses (scripts/testbed_lock.py probe), the helper's own source
# shipped inline so the probe never depends on what is installed on the host.
lock_probe_snippet() {   # lock_probe_snippet [redirect, e.g. " >file"]
    # printf + cat, not an unquoted heredoc: the helper's text must reach the
    # host verbatim (an unquoted heredoc would expand any $word inside it).
    printf "python3 - probe '%s' <<'PY'%s\n" "$H_ROOT/lock" "${1:-}"
    cat "$LOCK_HELPER"
    printf 'PY\n'
}

status_snippet() {
    # The probe runs into a file, not inside \$( ): /bin/bash 3.2 misparses a
    # heredoc (the helper's source) inside a command substitution.
    cat <<SH
$(lock_probe_snippet " >'$H_ROOT/.probe'")
probe="\$(cat '$H_ROOT/.probe' 2>/dev/null)"
case "\$probe" in
  BUSY*) echo "$H_NAME: RUNNING \${probe#BUSY }" ;;
  *) echo "$H_NAME: idle" ;;
esac
last='$H_ROOT/latest'
if [ -e "\$last/run.log" ]; then
  echo "last run: \$(readlink "\$last")"
  grep -E '^(START|OUTCOME)' "\$last/run.log" | sed 's/^/  /'
  [ -f "\$last/summary.txt" ] && sed 's/^/  /' "\$last/summary.txt"
  grep -q '^OUTCOME' "\$last/run.log" || echo "  now: \$(tail -1 "\$last/run.log")"
else
  echo "no run recorded under $H_ROOT"
fi
SH
}

plist_xml() {   # plist_xml <label> <args…>  (ProgramArguments after /bin/bash)
    local label="$1"; shift
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key>'
    echo '  <array>'
    echo '    <string>/bin/bash</string>'
    local a
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>LimitLoadToSessionType</key><string>Aqua</string>'
    echo '  <key>ProcessType</key><string>Interactive</string>'
    echo "  <key>StandardOutPath</key><string>$H_ROOT/agent.out</string>"
    echo "  <key>StandardErrorPath</key><string>$H_ROOT/agent.err</string>"
    echo '</dict>'
    echo '</plist>'
}

# ── Caller side ───────────────────────────────────────────────────────────
start_run() {
    local sha short stamp probe hhmm
    sha="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$REF^{commit}")" \
        || die "cannot resolve --ref '$REF' to a commit" 2
    short="${sha:0:9}"
    stamp="$(date +%Y%m%d_%H%M%S)_$$"     # unique per caller: two callers in one second never share a run
    local out="$H_ROOT/out/$stamp-$LANE"

    echo "m4_run: $LANE on $H_NAME at $short ($REF)${ONLY:+, only $ONLY}"
    [ "$H_MACHINE" = m5 ] && [ "$LANE" != ui ] && \
        echo "m4_run: note — run_gauntlet.sh has no 'ultra' label; the Ultra runs as --machine m5 --queue-only"

    if [ "$DRY" = 0 ]; then
        probe="$(on_host "$(lock_probe_snippet)")" || die "cannot reach $H_NAME (${H_SSH:-local})"
        case "$probe" in BUSY*) die "$H_NAME is busy: ${probe#BUSY } — try: scripts/m4_run.sh status --host $HOST" 3 ;; esac
        hhmm="$(on_host 'date +%H%M')"
        if [ "$FORCE" = 0 ] && [ "$hhmm" -ge 0130 ] && [ "$hhmm" -lt 0600 ] 2>/dev/null; then
            die "it is ${hhmm} on $H_NAME — the nightly runs 02:00; pass --force to run anyway" 5
        fi
    else
        echo "+ (probe $H_ROOT/lock: refuse early with exit 3 if a live run holds it; the host takes it for real)"
        echo "+ (refuse with exit 5 between 01:30 and 06:00 host time unless --force)"
        on_host "$(lock_probe_snippet)"
    fi
    # Test hook: hold here, after the advisory probe and before anything is
    # shipped (tests/test_m4_run.py pins that a second caller in this window
    # can never touch a live run's tree, runner or agent).
    if [ -n "${VIDEOSCAN_M4RUN_PAUSE_AFTER_PROBE:-}" ]; then
        : >"$VIDEOSCAN_M4RUN_PAUSE_AFTER_PROBE.paused"
        while [ -e "$VIDEOSCAN_M4RUN_PAUSE_AFTER_PROBE" ]; do sleep 0.05; done
    fi

    # Everything from here is ADDITIVE on the host — a new ref, a new per-run
    # bin directory, a new per-run LaunchAgent label. Nothing a live run uses
    # is touched: the testbed worktree is checked out by the host side under
    # the lock (host_main), where a second caller is refused before any
    # mutation (Codex 2026-11-05 re-review 3: the probe is advisory only).
    if [ -n "$H_SSH" ]; then
        if [ "$DRY" = 1 ]; then
            echo "+ git -C $REPO_ROOT push -q $H_SSH:dev/VideoScan $sha:refs/m4run/$sha"
        else
            git -C "$REPO_ROOT" push -q "$H_SSH:dev/VideoScan" "$sha:refs/m4run/$sha" \
                || die "git push to $H_SSH failed (is the M4 awake?)"
        fi
    fi

    local bin="$H_ROOT/bin/$stamp" label="$H_LABEL.$stamp"
    on_host "mkdir -p '$bin' '$H_ROOT/out'" || die "could not prepare $bin on $H_NAME" 4
    [ "$DRY" = 1 ] && echo "+ (the host checks out $sha into $H_WT under the testbed lock, refusing a dirty tree)"

    copy_to_host "$SELF" "$bin/m4_run.sh" || die "could not install the runner on $H_NAME"
    copy_to_host "$SCRIPT_DIR/m4_run_summary.py" "$bin/m4_run_summary.py" \
        || die "could not install the summarizer on $H_NAME"
    copy_to_host "$SCRIPT_DIR/testbed_lock.py" "$bin/testbed_lock.py" \
        || die "could not install the lock helper on $H_NAME"

    local args=("$bin/m4_run.sh" __host "$LANE" "$sha" "$stamp" --host "$HOST")
    [ -n "$ONLY" ] && args+=(--only "$ONLY")
    [ -n "$PLAN_TIMEOUT" ] && args+=(--plan-timeout "$PLAN_TIMEOUT")
    local plist
    plist="$(plist_xml "$label" "${args[@]}")"
    # A per-run label: bootstrapping never boots out a live run's agent. Agents
    # of FINISHED runs (launchctl list shows no pid) are booted out here so
    # they do not accumulate; a running one is never touched.
    on_host "$(cat <<SH
cat > '$H_ROOT/$label.plist' <<'PLIST'
$plist
PLIST
uid=\$(id -u)
launchctl list 2>/dev/null | awk -v p='$H_LABEL.' 'index(\$3, p) == 1 && \$1 == "-" { print \$3 }' | while read -r done_label; do
  [ "\$done_label" = '$label' ] || launchctl bootout "gui/\$uid/\$done_label" 2>/dev/null || true
done
launchctl bootstrap gui/\$uid '$H_ROOT/$label.plist'
echo "LaunchAgent $label bootstrapped in gui/\$uid"
SH
)" || die "could not bootstrap the LaunchAgent on $H_NAME"

    echo "m4_run: started — output $out (run.log, summary.txt)"
    echo "m4_run: check with: scripts/m4_run.sh status --host $HOST"
    [ "$WAIT" = 1 ] && [ "$DRY" = 0 ] && wait_for "$out"
    return 0
}

wait_for() {   # wait_for <out dir>: poll until run.log has OUTCOME
    local out="$1" waited=0 line
    while [ "$waited" -lt "$WAIT_BUDGET" ]; do
        sleep 30; waited=$((waited + 30))
        line="$(on_host "grep '^OUTCOME' '$out/run.log' 2>/dev/null || true")"
        if [ -n "$line" ]; then
            on_host "$(status_snippet)"
            # AMBER is not a failure for a --wait caller (exit 0); the line says AMBER.
            case "$line" in "OUTCOME GREEN"*|"OUTCOME AMBER"*) exit 0 ;; *) exit 1 ;; esac
        fi
    done
    die "gave up waiting after ${WAIT_BUDGET}s; the run may still be going — scripts/m4_run.sh status --host $HOST"
}

# ── Host side (inside the LaunchAgent) ────────────────────────────────────

# run_bounded <secs> <log> <cwd> <cmd…>: run cmd in its own process group,
# output appended to log; past the budget, TERM then KILL the group, then
# TERM any app-under-test left running from THIS testbed's DerivedData (the
# XCUITest app is launched by testmanagerd, outside the group). Exit 124 on
# timeout, else the command's own status.
run_bounded() {
    local secs="$1" log="$2" cwd="$3"; shift 3
    M4RUN_REAP="$H_DD/Build/Products/" python3 - "$secs" "$log" "$cwd" "$@" <<'PY'
import os, signal, subprocess, sys
secs, log, cwd, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
reap = os.environ.get("M4RUN_REAP", "")
# fd 9 is the testbed lock (take_lock): Python closes inherited fds by default,
# so pass it on — the work must hold the lock for as long as it runs.
try:
    os.fstat(9); pass_fds = (9,)
except OSError:
    pass_fds = ()
with open(log, "ab") as f:
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=f,
                         stderr=subprocess.STDOUT, start_new_session=True, pass_fds=pass_fds)
    try:
        sys.exit(p.wait(timeout=secs))
    except subprocess.TimeoutExpired:
        f.write(f"\n[m4_run] WATCHDOG: {secs}s budget exceeded; stopping process group {p.pid}\n".encode())
        f.flush()
        try:
            os.killpg(p.pid, signal.SIGTERM)
            p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        except ProcessLookupError:
            pass
        if reap:
            ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
            for row in ps.splitlines():
                pid, _, command = row.strip().partition(" ")
                if command.startswith(reap) and pid.isdigit():
                    f.write(f"[m4_run] WATCHDOG: stopping leftover {pid} {command[:120]}\n".encode())
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        sys.exit(124)
PY
}

# ── The testbed lock: ONE protocol, the same text in scripts/m4_run.sh and scripts/nightly_gauntlet.sh (tests/test_m4_run.py pins them equal) ──
# A kernel advisory lock on an open file description the WORK inherits: this shell opens fd 9 on $LOCK/flock,
# scripts/testbed_lock.py flocks that fd (LOCK_EX|LOCK_NB) and exits. flock belongs to the open file description,
# so the kernel holds it until the LAST process holding fd 9 closes it — the suite, the gauntlet in its own
# session, any child — and releases it by itself when they are all gone (Codex 2026-11-05 re-reviews: a lease
# tied to the shell ended before surviving work did; every mkdir/rename protocol had a check-then-act window).
# $LOCK/info carries "pid info" for the busy message only; the probe (`testbed_lock.py probe`) reads the same
# kernel truth from a fresh open. $LOCK_HELPER names the helper (per script: repo checkout or <root>/bin).
take_lock() {   # take_lock <info>: LOCK_HELD=1 (fd 9 is the lock), or BUSY="…" and return 1
    local answer
    mkdir -p "$LOCK" || { BUSY="cannot prepare the lock at $LOCK"; return 1; }
    exec 9>>"$LOCK/flock" || { BUSY="cannot open $LOCK/flock"; return 1; }
    answer="$(python3 "$LOCK_HELPER" hold 9 "$LOCK" "$1" 2>/dev/null)"
    case "$answer" in
        HELD)  LOCK_HELD=1; return 0 ;;
        BUSY*) BUSY="busy: ${answer#BUSY }" ;;
        *)     BUSY="lock helper failed (${answer:-no answer})" ;;
    esac
    exec 9>&-
    return 1
}
drop_lock() {   # closes this shell's fd 9; work still holding its copy keeps the lock until it exits
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    exec 9>&-
    LOCK_HELD=0
}
# ── end of the shared lock text ──

summarize_plan() {   # summarize_plan <plan> <log> <rc> <secs>
    local plan="$1" log="$2" rc="$3" secs="$4" flag=()
    [ "$rc" = 124 ] && flag=(--timeout)
    # `${a[@]+"${a[@]}"}`: an empty array under `set -u` on /bin/bash 3.2.
    python3 "$SCRIPT_DIR/m4_run_summary.py" "$plan" "$log" "$rc" "$secs" ${flag[@]+"${flag[@]}"} \
        --tsv "$OUT/$plan.tests.tsv" >>"$OUT/summary.txt"
}

host_ui() {
    local proj="$H_WT/VideoScan/VideoScan.xcodeproj" t0 rc plan budget
    t0=$(date +%s)
    run_bounded "$BUILD_BUDGET" "$OUT/ui-build.log" "$H_WT" \
        xcodebuild build-for-testing -project "$proj" -scheme VideoScan -configuration Debug \
        -destination platform=macOS -derivedDataPath "$H_DD" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual
    rc=$?
    echo "ui build exit=$rc secs=$(( $(date +%s) - t0 ))"
    if [ "$rc" != 0 ]; then
        echo "ui-build: RED rc=$rc (see ui-build.log)" >>"$OUT/summary.txt"
        VERDICT=RED
        return
    fi
    local plans=(VideoScan-UI VideoScan-Gauntlet) only=()
    if [ -n "$ONLY" ]; then
        plans=(VideoScan-Gauntlet)
        local c
        for c in ${ONLY//,/ }; do only+=("-only-testing:VideoScanUITests/$c"); done
    fi
    for plan in "${plans[@]}"; do
        budget=$GAUNTLET_PLAN_BUDGET
        [ "$plan" = VideoScan-UI ] && budget=$UI_PLAN_BUDGET
        [ -n "$PLAN_TIMEOUT" ] && budget=$PLAN_TIMEOUT
        t0=$(date +%s)
        run_bounded "$budget" "$OUT/$plan.log" "$H_WT" \
            xcodebuild test-without-building -project "$proj" -scheme VideoScan -testPlan "$plan" \
            -configuration Debug -destination platform=macOS -derivedDataPath "$H_DD" \
            -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
            -resultBundlePath "$OUT/$plan.xcresult" ${only[@]+"${only[@]}"}
        rc=$?
        local secs=$(( $(date +%s) - t0 ))
        echo "$plan exit=$rc secs=$secs"
        summarize_plan "$plan" "$OUT/$plan.log" "$rc" "$secs" || VERDICT=RED
    done
}

host_deep() {
    local t0 rc secs line verdict_line
    t0=$(date +%s)
    run_bounded "$DEEP_BUDGET" "$OUT/gauntlet.log" "$H_WT" \
        scripts/run_gauntlet.sh --away --machine "$H_MACHINE" --queue-only
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    echo "gauntlet exit=$rc secs=$secs"
    # The verdict line only: SUMMARY / TIDY / RETENTION lines also start "GAUNTLET " and
    # follow it; a published run dir is gone by now (m4_run_summary.py reads history.jsonl).
    line="$(grep -E '^GAUNTLET (PASSED|AMBER|FAILED) .* results=' "$OUT/gauntlet.log" | tail -1)"
    # The verdict comes from the run's result.json (GREEN / AMBER / RED, Rick
    # 2026-11-05): known issues, unadapted suites and ui-not-run are AMBER.
    local result="${line##* results=}" flag=() vrc
    result="${result%% *}"
    [ "$rc" = 124 ] && flag=(--timeout)
    verdict_line="$(python3 "$SCRIPT_DIR/m4_run_summary.py" --gauntlet "${result:-/nonexistent}" "$rc" "$secs" \
        ${flag[@]+"${flag[@]}"})"
    vrc=$?
    echo "$verdict_line" >>"$OUT/summary.txt"
    echo "  ${line:-(no GAUNTLET line; see gauntlet.log)}" >>"$OUT/summary.txt"
    case "$vrc" in
        0) ;;
        3) [ "$VERDICT" = GREEN ] && VERDICT=AMBER
           # "deep: AMBER <reasons> (sha=…)" → the reasons, for the OUTCOME line.
           AMBER_WHY="${verdict_line#deep: AMBER }"; AMBER_WHY="${AMBER_WHY% (sha=*}" ;;
        *) VERDICT=RED ;;
    esac
}

host_main() {   # __host <lane> <sha> <stamp>
    local lane="$1" sha="$2" stamp="$3"
    OUT="$H_ROOT/out/$stamp-$lane"
    mkdir -p "$OUT"
    exec >"$OUT/run.log" 2>&1
    export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # Lock first: a refused run must not repoint `latest` away from the live one.
    BUSY=""
    take_lock "$lane sha=${sha:0:9} since $(date '+%F %T') out=$OUT" || { echo "OUTCOME REFUSED $BUSY"; exit 3; }
    trap drop_lock EXIT
    ln -sfn "$OUT" "$H_ROOT/latest"
    # The testbed worktree is mutated HERE, under the lock, never by the
    # caller: a second caller's agent is refused above before it can touch
    # the tree a live run is testing (Codex 2026-11-05 re-review 3).
    if [ -d "$H_WT" ]; then
        if [ -n "$(git -C "$H_WT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            echo "OUTCOME REFUSED testbed worktree $H_WT has local changes:"
            git -C "$H_WT" status --short --untracked-files=no
            exit 4
        fi
        git -C "$H_WT" checkout -q --detach "$sha" || { echo "OUTCOME REFUSED cannot check out $sha in $H_WT"; exit 4; }
    else
        git -C "$H_REPO" worktree add -q --detach "$H_WT" "$sha" || { echo "OUTCOME REFUSED cannot add worktree $H_WT at $sha (from $H_REPO)"; exit 4; }
    fi
    echo "START $(date '+%F %T') host=$H_NAME lane=$lane sha=$sha${ONLY:+ only=$ONLY}"
    if [ "$(git -C "$H_WT" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
        echo "OUTCOME RED testbed $H_WT is not at $sha"
        exit 1
    fi
    : >"$OUT/summary.txt"
    VERDICT=GREEN
    AMBER_WHY=""
    case "$lane" in
        deep) host_deep ;;
        ui)   host_ui ;;
        all)  host_deep; host_ui ;;
    esac
    [ "$VERDICT" = AMBER ] || AMBER_WHY=""
    echo "OUTCOME $VERDICT $(date '+%F %T') lane=$lane sha=${sha:0:9}${AMBER_WHY:+ — $AMBER_WHY}"
    sed 's/^/  /' "$OUT/summary.txt"
    [ "$VERDICT" != RED ]
}

# ── Arguments ─────────────────────────────────────────────────────────────
LANE="${1:-}"; [ $# -gt 0 ] && shift
HOST=m4; REF=main; DRY=0; FORCE=0; WAIT=0; ONLY=""; PLAN_TIMEOUT=""
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 || usage ;;
        --ref) REF="${2:-}"; shift 2 || usage ;;
        --only) ONLY="${2:-}"; shift 2 || usage ;;
        --plan-timeout) PLAN_TIMEOUT="${2:-}"; shift 2 || usage ;;
        --dry-run) DRY=1; shift ;;
        --force) FORCE=1; shift ;;
        --wait) WAIT=1; shift ;;
        -h|--help) usage ;;
        --*) die "unknown option $1" 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done
[ -n "$PLAN_TIMEOUT" ] && ! [[ "$PLAN_TIMEOUT" =~ ^[0-9]+$ ]] && die "--plan-timeout wants seconds" 2
[ -n "$ONLY" ] && ! [[ "$ONLY" =~ ^[A-Za-z0-9_,]+$ ]] && die "--only wants UI test class names (A,B)" 2
host_config "$HOST"

case "$LANE" in
    ui|deep|all)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        [ -n "$ONLY" ] && [ "$LANE" != ui ] && die "--only applies to the ui lane" 2
        start_run ;;
    status)
        [ "$DRY" = 1 ] && { on_host "$(status_snippet)"; exit 0; }
        on_host "$(status_snippet)" || die "cannot reach $H_NAME (${H_SSH:-local})" ;;
    __host)
        [ ${#POS[@]} -eq 3 ] || die "__host <lane> <sha> <stamp>" 2
        case "${POS[0]}" in ui|deep|all) ;; *) die "bad lane ${POS[0]}" 2 ;; esac
        host_main "${POS[@]}" ;;
    ""|-h|--help) usage ;;
    *) die "unknown lane '$LANE' (ui|deep|all|status)" 2 ;;
esac
