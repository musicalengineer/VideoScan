#!/usr/bin/env bash
# m4_run.sh — run the UI test plans and/or the deep gauntlet on a test host,
# on demand, in that host's GUI session (docs/design/m4_staging_gate_2026_10_28.md).
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
#   4. checks the host's testbed worktree out at <sha> (detached; refuses a
#      dirty one): M4 ~/m4run/work, Ultra ~/dev/VideoScan-wt/ultra-testbed;
#   5. installs this script + m4_run_summary.py under <root>/bin on the host
#      (so the runner does not depend on the commit under test having it);
#   6. bootstraps a one-shot LaunchAgent in gui/<uid> that runs
#      `<root>/bin/m4_run.sh __host …`. A LaunchAgent, not plain ssh: an ssh
#      job has no window server (XCUITest needs it) and a locked keychain.
# The host side takes <root>/lock (mkdir is atomic; a dead holder's lock is
# reclaimed), writes <root>/out/<stamp>-<lane>/ {run.log, summary.txt,
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
# Exit: 0 started (or --wait: run GREEN) · 1 run RED / host error · 2 usage ·
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

# Lock state as one line: "FREE" or "BUSY <info>". `kill -0` only asks
# whether the holder still exists; it sends nothing.
lock_probe_snippet() {
    cat <<SH
if [ -d '$H_ROOT/lock' ]; then
  pid=\$(cat '$H_ROOT/lock/pid' 2>/dev/null)
  if [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then echo "BUSY \$(cat '$H_ROOT/lock/info' 2>/dev/null)"; exit 0; fi
fi
echo FREE
SH
}

status_snippet() {
    cat <<SH
lock='$H_ROOT/lock'
pid=\$(cat "\$lock/pid" 2>/dev/null)
if [ -d "\$lock" ] && [ -n "\$pid" ] && kill -0 "\$pid" 2>/dev/null; then
  echo "$H_NAME: RUNNING \$(cat "\$lock/info" 2>/dev/null)"
else
  echo "$H_NAME: idle"
fi
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

plist_xml() {   # plist_xml <args…>  (ProgramArguments after /bin/bash)
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    echo "  <key>Label</key><string>$H_LABEL</string>"
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
    stamp="$(date +%Y%m%d_%H%M%S)"
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
        echo "+ (probe $H_ROOT/lock: refuse with exit 3 if a live run holds it)"
        echo "+ (refuse with exit 5 between 01:30 and 06:00 host time unless --force)"
        on_host "$(lock_probe_snippet)"
    fi

    if [ -n "$H_SSH" ]; then
        if [ "$DRY" = 1 ]; then
            echo "+ git -C $REPO_ROOT push -q $H_SSH:dev/VideoScan $sha:refs/m4run/$sha"
        else
            git -C "$REPO_ROOT" push -q "$H_SSH:dev/VideoScan" "$sha:refs/m4run/$sha" \
                || die "git push to $H_SSH failed (is the M4 awake?)"
        fi
    fi

    on_host "$(cat <<SH
set -e
if [ -d '$H_WT' ]; then
  if [ -n "\$(git -C '$H_WT' status --porcelain --untracked-files=no)" ]; then
    echo "testbed worktree $H_WT has local changes:"; git -C '$H_WT' status --short --untracked-files=no; exit 4
  fi
  git -C '$H_WT' checkout -q --detach '$sha'
else
  git -C '$H_REPO' worktree add -q --detach '$H_WT' '$sha'
fi
mkdir -p '$H_ROOT/bin' '$H_ROOT/out'
echo "testbed $H_WT at \$(git -C '$H_WT' rev-parse --short=9 HEAD)"
SH
)"
    local rc=$?
    [ "$rc" = 0 ] || die "could not prepare the testbed worktree on $H_NAME" 4

    copy_to_host "$SELF" "$H_ROOT/bin/m4_run.sh" || die "could not install the runner on $H_NAME"
    copy_to_host "$SCRIPT_DIR/m4_run_summary.py" "$H_ROOT/bin/m4_run_summary.py" \
        || die "could not install the summarizer on $H_NAME"

    local args=("$H_ROOT/bin/m4_run.sh" __host "$LANE" "$sha" "$stamp" --host "$HOST")
    [ -n "$ONLY" ] && args+=(--only "$ONLY")
    [ -n "$PLAN_TIMEOUT" ] && args+=(--plan-timeout "$PLAN_TIMEOUT")
    local plist
    plist="$(plist_xml "${args[@]}")"
    on_host "$(cat <<SH
cat > '$H_ROOT/$H_LABEL.plist' <<'PLIST'
$plist
PLIST
uid=\$(id -u)
launchctl bootout gui/\$uid/$H_LABEL 2>/dev/null || true
launchctl bootstrap gui/\$uid '$H_ROOT/$H_LABEL.plist'
echo "LaunchAgent $H_LABEL bootstrapped in gui/\$uid"
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
            case "$line" in "OUTCOME GREEN"*) exit 0 ;; *) exit 1 ;; esac
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
with open(log, "ab") as f:
    p = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=f,
                         stderr=subprocess.STDOUT, start_new_session=True)
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

take_lock() {   # mkdir is atomic: exactly one run gets it
    local lock="$H_ROOT/lock" pid
    if ! mkdir "$lock" 2>/dev/null; then
        pid="$(cat "$lock/pid" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "OUTCOME REFUSED busy: $(cat "$lock/info" 2>/dev/null)"
            return 3
        fi
        echo "reclaiming a stale lock (holder ${pid:-unknown} is gone)"
        rm -f "$lock/pid" "$lock/info"
        rmdir "$lock" 2>/dev/null
        mkdir "$lock" 2>/dev/null || { echo "OUTCOME REFUSED lost the lock race"; return 3; }
    fi
    echo "$$" >"$lock/pid"
    echo "$1" >"$lock/info"
    LOCK_HELD=1
}

drop_lock() {
    [ "${LOCK_HELD:-0}" = 1 ] || return 0
    rm -f "$H_ROOT/lock/pid" "$H_ROOT/lock/info"
    rmdir "$H_ROOT/lock" 2>/dev/null
    LOCK_HELD=0
}

summarize_plan() {   # summarize_plan <plan> <log> <rc> <secs>
    local plan="$1" log="$2" rc="$3" secs="$4" flag=()
    [ "$rc" = 124 ] && flag=(--timeout)
    # `${a[@]+"${a[@]}"}`: an empty array under `set -u` on /bin/bash 3.2.
    python3 "$H_ROOT/bin/m4_run_summary.py" "$plan" "$log" "$rc" "$secs" ${flag[@]+"${flag[@]}"} \
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
    local t0 rc secs line
    t0=$(date +%s)
    run_bounded "$DEEP_BUDGET" "$OUT/gauntlet.log" "$H_WT" \
        scripts/run_gauntlet.sh --away --machine "$H_MACHINE" --queue-only
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    echo "gauntlet exit=$rc secs=$secs"
    line="$(grep -E '^GAUNTLET ' "$OUT/gauntlet.log" | tail -1)"
    [ "$rc" = 124 ] && line="TIMEOUT after ${secs}s ${line}"
    if [ "$rc" = 0 ]; then
        echo "deep: GREEN ${line:-(no GAUNTLET line)}" >>"$OUT/summary.txt"
    else
        echo "deep: RED rc=$rc ${line:-(no GAUNTLET line; see gauntlet.log)}" >>"$OUT/summary.txt"
        VERDICT=RED
    fi
}

host_main() {   # __host <lane> <sha> <stamp>
    local lane="$1" sha="$2" stamp="$3"
    OUT="$H_ROOT/out/$stamp-$lane"
    mkdir -p "$OUT"
    exec >"$OUT/run.log" 2>&1
    export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # Lock first: a refused run must not repoint `latest` away from the live one.
    take_lock "$lane sha=${sha:0:9} since $(date '+%F %T') out=$OUT" || exit 3
    trap drop_lock EXIT
    ln -sfn "$OUT" "$H_ROOT/latest"
    echo "START $(date '+%F %T') host=$H_NAME lane=$lane sha=$sha${ONLY:+ only=$ONLY}"
    if [ "$(git -C "$H_WT" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
        echo "OUTCOME RED testbed $H_WT is not at $sha"
        exit 1
    fi
    : >"$OUT/summary.txt"
    VERDICT=GREEN
    case "$lane" in
        deep) host_deep ;;
        ui)   host_ui ;;
        all)  host_deep; host_ui ;;
    esac
    echo "OUTCOME $VERDICT $(date '+%F %T') lane=$lane sha=${sha:0:9}"
    sed 's/^/  /' "$OUT/summary.txt"
    [ "$VERDICT" = GREEN ]
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
