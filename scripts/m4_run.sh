#!/usr/bin/env bash
# m4_run.sh — run the UI test plans, the deep gauntlet or the full suite on a
# test host, on demand, in that host's GUI session (docs/guides/operations.md).
#
#   scripts/m4_run.sh ui     [--host m4|ultra] [--ref <rev>] [--only <UITestClass>[,…]] [--wait] [--dry-run]
#   scripts/m4_run.sh deep   [--host m4|ultra] [--ref <rev>] [--wait] [--dry-run]
#   scripts/m4_run.sh all    [--host m4|ultra] [--ref <rev>] [--wait] [--dry-run]
#   scripts/m4_run.sh suite  [--host m4|ultra] [--ref <rev>] [--wait] [--dry-run]
#   scripts/m4_run.sh testbed [--ref <rev>] [--smoke] [--wait] [--dry-run]
#   scripts/m4_run.sh status [--host m4|ultra] [--json]
#   scripts/m4_run.sh corpus --corpus-lane prepare|check|proof|verbs|coverage [--ref <rev>] [--deadline <s>] [--limit <n>] [--smoke] [--wait] [--dry-run]
#   --smoke (DECISIONS 2026-11-19, target <= 15 min on the M4): the testbed's every lane on a small stratified
#         subset — the sensor lane (scripts/run_sensors.sh) in place of the full suite, then corpus check, proof
#         and verbs each with corpus_run.py --smoke. Labelled SMOKE in every summary line and the block; its
#         verdict means "the harness, the host and the code run end to end"; never a baseline.
#
# What Rick says → what runs (from the phone, over Remote Control):
#   "run the gauntlet UI tests on the M4"       scripts/m4_run.sh ui
#   "… on the M5 Ultra"                         scripts/m4_run.sh ui --host ultra
#   "deep test on the M4" / "run the gauntlet"  scripts/m4_run.sh deep
#   "everything on the M4"                      scripts/m4_run.sh all
#   "run the full suite on the M4 for <ref>"    scripts/m4_run.sh suite --ref <ref> --wait
#   "run the testbed on the M4 for <ref>"       scripts/m4_run.sh testbed --ref <ref> --wait
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
#   suite The full app + Core suite the scheduled nightly runs (~13,900 tests),
#         by the nightly's own runner: scripts/nightly_local_tests.sh --on-demand
#         (one engine — the same preflight, Core lane, Release build, parsers
#         and verdict precedence), installed beside this script per run and
#         pointed at the testbed worktree. Nothing is published: its row goes
#         to <out>/suite-row.json, never the metrics branch, and the page is
#         not rebuilt. Own caches (<DerivedData>-suite/{app,core}), own logs in
#         <out>; the scheduled run's checkout, caches and /tmp files are not
#         touched. m4_run_summary.py --suite turns the row into the verdict:
#         GREEN / RED, or NORUN when the machine preflight stopped it. A lane
#         with no number (zero app or zero Core tests) is RED. `all` does not
#         include it.
#   corpus  the real-data corpus harness (scripts/corpus_run.sh is its front door; M4 only):
#         scripts/corpus_run.py on the host, under the same lock, agent and --ref checkout.
#         It refuses any host but the M4 and any state root outside ~/corpus/state.
#         --corpus-lane coverage (opt-in, ~2 h): check, proof and verbs on an instrumented
#         build beside the same build's suite and Core's suite; what of our code only the
#         corpus runs (scripts/corpus_coverage.py; caches <DerivedData>-coverage{,-core}, which
#         testbed_host.py clean removes at every run start and end: scratch, not warm).
#   testbed  everything, one verdict (M4 only): the suite lane, then corpus `check`, then corpus
#         `proof`, under ONE hold of the lock, at one commit. The lanes are the ones above (host_suite,
#         host_corpus — no second implementation); each still runs when an earlier one is RED. The
#         summary opens with one block (m4_run_summary.py --testbed): per lane GREEN / AMBER / RED /
#         NORUN, its wall time and counts, and for a corpus lane what changed against its earlier run.
#         The run is RED if any lane is RED, else NORUN if any lane could not run, else AMBER, else
#         GREEN. Each corpus lane's files go to <out>/corpus-<lane>/. <root>/latest-testbed names the
#         last testbed run for `status`; <root>/latest-suite stays the suite lane's own.
#
# Shape. The caller (normally the Ultra) never builds anything:
#   1. resolves --ref (default `main`) to a commit;
#   2. asks the host whether a run holds its lock (refuses if so), whether
#      it is the nightly window (01:30–06:00 host time; --force overrides), and
#      whether it is the QUIET WINDOW before a scheduled run (the M4's 14:00
#      testbed: scripts/testbed_host.py window — by default the lane's own
#      expected length, <root>/testbed.conf changes it; exit 5; --force
#      overrides). The scheduled run does not wait for the lock — it runs its
#      suite anyway — so a lane must be finished before it starts;
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
# prunes old run folders (scripts/testbed_host.py prune: the newest 10 of each lane, every RED run and
# whatever <root>/latest* names are kept; KEEP in <root>/testbed.conf changes the 10), writes
# <root>/out/<stamp>-<lane>/ {run.log, summary.txt,
# <plan>.log, <plan>.xcresult, <plan>.tests.tsv}, points <root>/latest at it
# (a suite run also <root>/latest-suite, so `status` still shows the last suite
# verdict after a later ui or deep run), and prints START/OUTCOME lines into
# run.log. `status` reads them back.
#
# `--host m4local` is the M4 calling itself (no ssh, no push; the commit must already be in the
# M4's ~/dev/VideoScan): that is how the push watcher starts a run. Refused on any other Mac.
#
# Roots: M4 ~/m4run (DerivedData ~/Library/Caches/videoscan-m4run-dd);
#        Ultra ~/ultrarun (DerivedData ~/Library/Caches/videoscan-ultrarun-dd).
#
# The floor, 15% free = 85% used at rest (DECISIONS 2026-11-18, 2026-11-19; scripts/testbed_host.py clean): a run may use as much disk as it
# needs; once its verdict and summary are written, its scratch goes (xcresult bundles, overlays, patched
# test-run files; each log cut to its last 200 lines under its own name) and the summary gets one line:
#   disk: free 52% after cleanup (lowest 38% during the run, 47% at the start; floor 15%) — removed 0.41 GB: this run 0.41 GB
# At the start, and again at the end, under the lock: finished runs not yet tidied are tidied and
# ~/corpus/work/<stamp>-<lane> folders removed; below 15% free, unfinished runs go oldest first, then the
# build caches below — only when that reaches the floor. M4 only. Deletion works through folder descriptors
# opened from $HOME down without following links (~/m4run/out, ~/corpus/work, those two caches; never a mount, never
# the corpus protected set), and refuses unless the lock names this run. A stuck cleanup stops at 900 s; the run
# reaches its OUTCOME whatever the cleanup does.
#
# Worst-case resources: one Debug DerivedData per host (~15 GB), plus for the
# suite lane one Release DerivedData and one Core scratch (<DerivedData>-suite,
# 6.9 GB together on the M4, 2026-11-17), xcresult bundles per run (~50–300 MB
# each; a suite run's directory 140–420 MB; pruned at the start of each lane), and
# the watchdog budgets below in wall time. A suite run on the M4 with warm caches:
# 56 min (Core 16, build 10, app tests 30), measured 2026-11-17.
#
# Exit: 0 started (or --wait: run GREEN or AMBER — the OUTCOME line says which) · 1 run RED / host error (also a run
#       whose shell was stopped before its OUTCOME: a logout of the host's GUI session, a restart) · 2 usage ·
#       3 busy · 4 testbed worktree not usable (or a run folder that already exists) · 5 nightly window or the
#       quiet window before a scheduled run (also when the run reaches its lock after the window opened) ·
#       6 (--unless-ran, the push watcher's) that commit was already run to a verdict.
#       suite --wait: 0 GREEN · 1 RED · 2 could not run (the host refused it, the machine preflight
#       stopped it, its shell was stopped before an OUTCOME, or the wait gave up); a run that never
#       started still exits 3 / 4 / 5 as above. testbed --wait: the same three — 0 only when no
#       lane is RED or NORUN.
#
# `status --json` prints one JSON object for machines (scripts/testbed_host.py status-json): the lock,
# and the last run, the last suite run and the last testbed run with their verdict words.
#
# Tests: tests/test_testbed_host.py (prune, the quiet window, status --json), tests/test_m4_run.py (argument parsing, dry-run plans, the lock, the
# summary line), tests/test_m4_run_deep_lane.py, tests/test_m4_run_suite_lane.py,
# tests/test_m4_run_testbed_lane.py.
# Nothing in the tests touches a host.

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
# The suite's runner has its own watchdogs (Core 3,600 s; build 5,400 s, twice at
# worst with its clean retry; tests 7,200 s = 21,600 s); this one is the backstop.
SUITE_BUDGET=22500
CORPUS_BUDGET=21600          # corpus lane: a build, then every corpus file under its own per-file deadline
WAIT_BUDGET=23400            # past every single lane's budget, so --wait outlives the run it waits for
TESTBED_WAIT_BUDGET=$((SUITE_BUDGET + 2 * CORPUS_BUDGET + 900))   # testbed = suite + two corpus lanes, back to back
SENSORS_BUDGET=1800          # the smoke testbed's suite: the sensor lane (~70 s warm, a cold Debug build ~10 min)
WAIT_POLL="${VIDEOSCAN_M4RUN_WAIT_POLL:-30}"     # seconds between --wait polls (tests shorten it)

usage() {
    sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'
    exit 2
}

die() { echo "m4_run: $1" >&2; exit "${2:-1}"; }     # die <message> [exit code]

# ── Host configuration ────────────────────────────────────────────────────
# Same account on every fleet Mac, so $HOME names the host's home too.
host_config() {
    case "$1" in
        m4|m4local)
            H_SSH="ricksm4.local"; H_ROOT="$HOME/m4run"; H_WT="$HOME/m4run/work"
            H_DD="$HOME/Library/Caches/videoscan-m4run-dd"; H_LABEL="com.videoscan.m4run"
            H_MACHINE="m4"; H_NAME="M4"
            # m4local: the caller IS the M4 (the push watcher, scripts/m4_watch.py) — no ssh, no
            # push. Allowed by this Mac's own name and nothing else: no flag or variable can make
            # another Mac (the Ultra) run the M4's lanes on itself.
            if [ "$1" = m4local ]; then
                [ "$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" = ricksm4 ] \
                    || die "--host m4local is for the M4 itself; this Mac is not the M4" 2
                H_SSH=""
            fi ;;
        ultra)
            H_SSH=""; H_ROOT="$HOME/ultrarun"; H_WT="$HOME/dev/VideoScan-wt/ultra-testbed"
            H_DD="$HOME/Library/Caches/videoscan-ultrarun-dd"; H_LABEL="com.videoscan.ultrarun"
            H_MACHINE="m5"; H_NAME="M5 Ultra" ;;
        *) die "unknown host '$1' (m4|ultra; m4local on the M4 itself)" 2 ;;
    esac
    H_REPO="$HOME/dev/VideoScan"
    # The M4 calling itself runs from a pinned copy that is not a checkout: --ref is resolved in the
    # host's own repository, which is also where the testbed worktree comes from.
    [ "$1" = m4local ] && REPO_ROOT="$H_REPO"
    H_SUITE_DD="$H_DD-suite"   # the suite lane's own caches: <it>/app (Release DerivedData), <it>/core (swift test scratch)
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

# scripts/testbed_host.py run on the host from its own source (no apostrophes in it), as the lock probe is.
host_tool_snippet() {   # host_tool_snippet <args…>
    printf "python3 -"
    printf " '%s'" "$@"
    printf " <<'PY'\n"
    cat "$SCRIPT_DIR/testbed_host.py"
    printf 'PY\n'
}

# vs_show: a shell function on the host that prints a file through `testbed_host.py show` — no
# link followed, one-name regular files only, lines that could carry a name withheld (Codex
# #315-3: status never prints unvalidated text). Its source rides inline, like the lock probe's.
show_function_snippet() {
    printf "vs_show() {\npython3 - show \"\$@\" <<'PY'\n"
    cat "$SCRIPT_DIR/testbed_host.py"
    printf 'PY\n}\n'
}

status_snippet() {
    # The probe runs into a file, not inside \$( ): /bin/bash 3.2 misparses a
    # heredoc (the helper's source) inside a command substitution.
    cat <<SH
$(show_function_snippet)
$(lock_probe_snippet " >'$H_ROOT/.probe'")
probe="\$(cat '$H_ROOT/.probe' 2>/dev/null)"
case "\$probe" in
  BUSY*) echo "$H_NAME: RUNNING \${probe#BUSY }" ;;
  *) echo "$H_NAME: idle" ;;
esac
last='$H_ROOT/latest'
if [ -e "\$last/run.log" ]; then
  echo "last run: \$(readlink "\$last")"
  vs_show "\$last/run.log" --match '^(START|OUTCOME)' | sed 's/^/  /'
  [ -f "\$last/summary.txt" ] && vs_show "\$last/summary.txt" | sed 's/^/  /'
  if ! grep -q '^OUTCOME' "\$last/run.log"; then
    case "\$probe" in
      BUSY*) echo "  now: \$(vs_show "\$last/run.log" --tail 1)" ;;
      *) echo "  ENDED WITHOUT AN OUTCOME: nothing of this run holds the lock — its shell was stopped (a logout of the GUI session, a restart, a crash); its logs are what is left" ;;
    esac
  fi
  # A live suite run: its runner's last step, and how many tests have finished in each lane.
  if [ -f "\$last/suite.log" ] && ! grep -q '^OUTCOME' "\$last/run.log"; then
    echo "  step: \$(vs_show "\$last/suite.log" --match '^\[[0-9:]+\] ' | grep -v 'Core lane machine' | tail -1)"
    for lane in core app; do
      [ -f "\$last/suite-\$lane-test.log" ] && echo "  \$lane tests finished so far: \$(grep -E '(✔|✘|━) Test .* (passed|failed) after |^Test Case .* (passed|failed) \(' "\$last/suite-\$lane-test.log" | grep -cvE 'Test run with [0-9]+ test| recorded an issue ')"
    done
  fi
else
  echo "no run recorded under $H_ROOT"
fi
suite='$H_ROOT/latest-suite'
if [ -e "\$suite/run.log" ] && [ "\$(readlink "\$suite")" != "\$(readlink "\$last")" ]; then
  echo "last suite run: \$(readlink "\$suite")"
  vs_show "\$suite/run.log" --match '^(START|OUTCOME)' | sed 's/^/  /'
  [ -f "\$suite/summary.txt" ] && vs_show "\$suite/summary.txt" | sed 's/^/  /'
fi
[ -f '$H_ROOT/watch/verdict.txt' ] && echo "push watcher: \$(vs_show '$H_ROOT/watch/verdict.txt' --tail 1)"
[ -f '$H_ROOT/watch/tick.txt' ] && echo "push watcher, last tick: \$(vs_show '$H_ROOT/watch/tick.txt' --tail 1)"
testbed='$H_ROOT/latest-testbed'
if [ -e "\$testbed/run.log" ] && [ "\$(readlink "\$testbed")" != "\$(readlink "\$last")" ]; then
  echo "last testbed run: \$(readlink "\$testbed")"
  vs_show "\$testbed/run.log" --match '^(START|OUTCOME)' | sed 's/^/  /'
  [ -f "\$testbed/testbed-block.txt" ] && vs_show "\$testbed/testbed-block.txt" | sed 's/^/  /'
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
    [ "$H_MACHINE" = m5 ] && [ "$LANE" != ui ] && [ "$LANE" != suite ] && [ "$LANE" != testbed ] && \
        echo "m4_run: note — run_gauntlet.sh has no 'ultra' label; the Ultra runs as --machine m5 --queue-only"

    if [ "$DRY" = 0 ]; then
        probe="$(on_host "$(lock_probe_snippet)")" || die "cannot reach $H_NAME (${H_SSH:-local})"
        case "$probe" in BUSY*) die "$H_NAME is busy: ${probe#BUSY } — try: scripts/m4_run.sh status --host $HOST" 3 ;; esac
        hhmm="$(on_host 'date +%H%M')"
        if [ "$FORCE" = 0 ] && [ "$hhmm" -ge 0130 ] && [ "$hhmm" -lt 0600 ] 2>/dev/null; then
            die "it is ${hhmm} on $H_NAME — the nightly runs 02:00; pass --force to run anyway" 5
        fi
        # The quiet window before a scheduled run (the M4's 14:00 testbed does not wait for the lock).
        local quiet
        quiet="$(on_host "$(host_tool_snippet window "$H_ROOT" "$LANE" "$hhmm")" 2>/dev/null)"
        case "$quiet" in
            QUIET*) [ "$FORCE" = 1 ] || die "it is ${hhmm} on $H_NAME — ${quiet#QUIET }; pass --force to run anyway" 5 ;;
        esac
        # The host side re-checks when it takes the lock: a run that reaches it after the next
        # window has opened is refused there (Codex #315-6). --force carries no deadline.
        if [ "$FORCE" = 0 ]; then
            START_BY="$(on_host "$(host_tool_snippet start-by "$H_ROOT" "$LANE" "$hhmm" "$(on_host 'date +%s')")" 2>/dev/null)"
            [[ "$START_BY" =~ ^[0-9]+$ ]] || die "could not work out when the next window opens on $H_NAME" 1
        fi
    else
        echo "+ (probe $H_ROOT/lock: refuse early with exit 3 if a live run holds it; the host takes it for real)"
        echo "+ (refuse with exit 5 between 01:30 and 06:00 host time unless --force)"
        echo "+ (refuse with exit 5 inside the quiet window before a scheduled run on the host unless --force: testbed_host.py window $H_ROOT $LANE <host HHMM>)"
        echo "+ (unless --force: --start-by <the epoch the next window opens>; the host refuses a run that reaches its lock after it)"
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
    [ "$DRY" = 1 ] && [ "$LANE" = corpus ] && \
        echo "+ (the host runs corpus_run.py host $CORPUS_LANE: refused unless the hostname is the M4's and the state root is under ~/corpus/state)"
    [ "$DRY" = 1 ] && [ "$LANE" = corpus ] && [ "$SMOKE" = 1 ] && \
        echo "+ (SMOKE: corpus_run.py host $CORPUS_LANE --smoke — a stratified subset; never a baseline)"
    [ "$DRY" = 1 ] && [ "$LANE" = testbed ] && [ "$SMOKE" = 1 ] && \
        echo "+ (the host runs, under one hold of the lock, SMOKE: the sensor lane, then corpus_run.py host check, proof and verbs, each --smoke — one summary block, one OUTCOME; target 15 min)"
    [ "$DRY" = 1 ] && [ "$LANE" = testbed ] && [ "$SMOKE" = 0 ] && \
        echo "+ (the host runs, under one hold of the lock: the suite lane, then corpus_run.py host check, then corpus_run.py host proof — each refused unless the hostname is the M4's; one summary block, one OUTCOME)"

    copy_to_host "$SELF" "$bin/m4_run.sh" || die "could not install the runner on $H_NAME"
    copy_to_host "$SCRIPT_DIR/m4_run_summary.py" "$bin/m4_run_summary.py" \
        || die "could not install the summarizer on $H_NAME"
    copy_to_host "$SCRIPT_DIR/testbed_lock.py" "$bin/testbed_lock.py" \
        || die "could not install the lock helper on $H_NAME"
    copy_to_host "$SCRIPT_DIR/testbed_host.py" "$bin/testbed_host.py" \
        || die "could not install the housekeeping helper on $H_NAME"
    if [ "$LANE" = suite ] || [ "$LANE" = testbed ]; then
        # The nightly's own runner and its watchdog library, from the caller's
        # checkout like this script: the commit under test need not have them.
        on_host "mkdir -p '$bin/lib'" || die "could not prepare $bin/lib on $H_NAME" 4
        copy_to_host "$SCRIPT_DIR/nightly_local_tests.sh" "$bin/nightly_local_tests.sh" \
            && copy_to_host "$SCRIPT_DIR/lib/process_group_watchdog.sh" "$bin/lib/process_group_watchdog.sh" \
            || die "could not install the suite runner on $H_NAME"
        [ "$DRY" = 1 ] && echo "+ (the host runs $bin/nightly_local_tests.sh --on-demand $out --repo $H_WT --dd $H_SUITE_DD: nothing published)"
    fi

    if [ "$LANE" = corpus ] || [ "$LANE" = testbed ]; then
        # The harness's host side and its driver sources, per run like the runner itself.
        local f
        # Every driver source in scripts/corpus/ goes, by glob: a fixed list missed CorpusPool.swift when the
        # parallel pool merged and every corpus run died at its overlay step (2026-11-22).
        for f in corpus_run.py corpus_coverage.py catalog_db.py "$SCRIPT_DIR"/corpus/*.swift; do
            f="${f#"$SCRIPT_DIR"/}"
            copy_to_host "$SCRIPT_DIR/$f" "$bin/$(basename "$f")" || die "could not install $f on $H_NAME"
        done
    fi

    local args=("$bin/m4_run.sh" __host "$LANE" "$sha" "$stamp" --host "$HOST")
    [ -n "$ONLY" ] && args+=(--only "$ONLY")
    [ -n "$PLAN_TIMEOUT" ] && args+=(--plan-timeout "$PLAN_TIMEOUT")
    [ -n "$CORPUS_LANE" ] && args+=(--corpus-lane "$CORPUS_LANE")
    [ -n "$CORPUS_DEADLINE" ] && args+=(--deadline "$CORPUS_DEADLINE")
    [ -n "$CORPUS_LIMIT" ] && args+=(--limit "$CORPUS_LIMIT")
    [ -n "$START_BY" ] && args+=(--start-by "$START_BY")
    [ "$UNLESS_RAN" = 1 ] && args+=(--unless-ran)
    [ "$SMOKE" = 1 ] && args+=(--smoke)
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
    local out="$1" waited=0 line norun=1 free=0 budget="$WAIT_BUDGET"
    [ "$LANE" = suite ] && norun=2       # suite: could-not-run is told apart from RED
    [ "$LANE" = testbed ] && { norun=2; budget="$TESTBED_WAIT_BUDGET"; }
    while [ "$waited" -lt "$budget" ]; do
        sleep "$WAIT_POLL"; waited=$((waited + WAIT_POLL))
        line="$(on_host "grep '^OUTCOME' '$out/run.log' 2>/dev/null || true")"
        if [ -n "$line" ]; then
            on_host "$(status_snippet)"
            # AMBER is not a failure for a --wait caller (exit 0); the line says AMBER.
            case "$line" in
                "OUTCOME GREEN"*|"OUTCOME AMBER"*) exit 0 ;;
                "OUTCOME RED"*) exit 1 ;;
                *) exit "$norun" ;;          # REFUSED, NORUN
            esac
        fi
        # No OUTCOME and nothing holds the lock, twice running (the agent takes it within a
        # second of starting): the run's shell is gone — a logout of the host's GUI session
        # stops the agent (2026-11-17, the first real suite run), so does a restart. Without
        # this the caller waited out the whole budget for a line that would never come.
        case "$(on_host "$(lock_probe_snippet)" 2>/dev/null)" in FREE*) free=$((free + 1)) ;; *) free=0 ;; esac
        if [ "$free" -ge 2 ]; then
            line="$(on_host "grep '^OUTCOME' '$out/run.log' 2>/dev/null || true")"
            [ -n "$line" ] && continue          # it finished between the two looks
            on_host "$(status_snippet)"
            die "the run on $H_NAME ended without an OUTCOME (its shell was stopped: logout, restart or crash) — logs in $out" "$norun"
        fi
    done
    die "gave up waiting after ${budget}s; the run may still be going — scripts/m4_run.sh status --host $HOST" "$norun"
}

# ── Host side (inside the LaunchAgent) ────────────────────────────────────

# run_bounded <secs> <log> <cwd> <cmd…>: run cmd in its own process group,
# output appended to log; past the budget, TERM then KILL the group, then
# TERM any app-under-test left running from THIS testbed's DerivedData (the
# XCUITest app is launched by testmanagerd, outside the group). Exit 124 on
# timeout, else the command's own status.
run_bounded() {
    local secs="$1" log="$2" cwd="$3"; shift 3
    M4RUN_REAP="${REAP_DD:-$H_DD}/Build/Products/" python3 - "$secs" "$log" "$cwd" "$@" <<'PY'
import os, signal, subprocess, sys
secs, log, cwd, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
reap = os.environ.get("M4RUN_REAP", "")
# fd 9 is the testbed lock (take_lock): Python closes inherited fds by default,
# so pass it on — the work must hold the lock for as long as it runs.
try:
    os.fstat(9); pass_fds = (9,)
except OSError:
    pass_fds = ()
# The log is the run's own: never through a link, never a file with a second name (Codex #315-2).
try:
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o644)
except OSError as error:
    print(f"[m4_run] refused: the log {os.path.basename(log)} cannot be opened safely ({type(error).__name__})")
    sys.exit(125)
info = os.fstat(fd)
if not (info.st_mode & 0o170000 == 0o100000) or info.st_nlink != 1:
    os.close(fd)
    print(f"[m4_run] refused: the log {os.path.basename(log)} has a second name or is not a plain file")
    sys.exit(125)
with os.fdopen(fd, "ab") as f:
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

# The full app + Core suite, by the nightly's own runner in its on-demand mode
# (installed beside this script). The runner writes its log itself (<out>/suite.log)
# and its row to <out>/suite-row.json; the summary turns the row into the verdict.
# caffeinate -i: the host must not idle-sleep under a two-hour run (the scheduled run
# gets the same from scripts/nightly_guarded.sh).
host_suite() {
    local t0 rc secs flag=() vrc dirty
    local REAP_DD="$H_SUITE_DD/app"      # run_bounded reads it (bash locals are visible to callees)
    t0=$(date +%s)
    run_bounded "$SUITE_BUDGET" "$OUT/suite-runner.log" "$H_WT" \
        /usr/bin/caffeinate -i /bin/bash "$SCRIPT_DIR/nightly_local_tests.sh" --on-demand "$OUT" --repo "$H_WT" --dd "$H_SUITE_DD"
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    echo "suite exit=$rc secs=$secs"
    [ "$rc" = 124 ] && flag=(--timeout)
    python3 "$SCRIPT_DIR/m4_run_summary.py" --suite "$OUT/suite-row.json" "$rc" "$secs" \
        --repo "$H_WT" --log "$OUT/suite.log" ${flag[@]+"${flag[@]}"} >>"$OUT/summary.txt"
    vrc=$?
    case "$vrc" in
        0) ;;
        4) VERDICT=NORUN
           WHY="$(sed -n '1s/^suite: NORUN \([^ ]*\).*/\1/p' "$OUT/summary.txt")" ;;
        *) VERDICT=RED ;;
    esac
    # The next run refuses a dirty testbed: say now whether this one left it clean.
    dirty="$(git -C "$H_WT" status --porcelain --untracked-files=no 2>/dev/null)"
    if [ -n "$dirty" ]; then
        echo "  testbed worktree NOT clean after the run (the next run will refuse it): $(printf '%s' "$dirty" | tr '\n' ';')" >>"$OUT/summary.txt"
    else
        echo "  testbed worktree clean after the run" >>"$OUT/summary.txt"
    fi
}

# The smoke testbed's suite (DECISIONS 2026-11-19): the sensor lane of the commit under test — its
# own test plan, reused, not a second subset — into the corpus lanes' Debug DerivedData. Its one line
# ("sensor lane GREEN (N tests)") is the lane's facts; anything else is RED, a ref without it NORUN.
host_sensors() {
    local t0 rc secs line
    t0=$(date +%s)
    if [ ! -f "$H_WT/scripts/run_sensors.sh" ]; then
        echo "sensors: NORUN this ref has no scripts/run_sensors.sh" >>"$OUT/summary.txt"
        printf '{}\n' >"$OUT/sensors-row.json"; VERDICT=NORUN; WHY="sensors: no sensor lane in this ref"; return
    fi
    run_bounded "$SENSORS_BUDGET" "$OUT/sensors.log" "$H_WT" /bin/bash "$H_WT/scripts/run_sensors.sh" --derived-data "$H_DD"
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    echo "sensors exit=$rc secs=$secs"
    line="$(grep -E '^sensor lane (GREEN|RED)' "$OUT/sensors.log" 2>/dev/null | tail -1)"
    python3 -c 'import json,sys; print(json.dumps({"line": sys.argv[1], "rc": int(sys.argv[2])}))' "$line" "$rc" >"$OUT/sensors-row.json"
    echo "sensors (SMOKE: the sensor lane in place of the full suite): ${line:-no result line} (rc=$rc, ${secs}s)" >>"$OUT/summary.txt"
    # GREEN only with a positive count of tests run (Codex #336 F8: a bare GREEN or zero tests proves nothing).
    case "$rc:$line" in
        0:"sensor lane GREEN ("[1-9]*" tests)") ;;
        124:*) echo "sensors: RED TIMEOUT after ${secs}s" >>"$OUT/summary.txt"; VERDICT=RED ;;
        *) VERDICT=RED ;;
    esac
}

# The real-data corpus harness (DECISIONS 2026-11-17). Everything it does is in
# scripts/corpus_run.py (installed beside this script); it runs under the lane
# watchdog with the lock's fd passed on, and writes its own counts-only
# summary. Exit: 0 GREEN · 3 AMBER (some file's outcome word moved against the lane's
# baseline) · 4 NORUN (the ref lacks the lane's engine) · anything else RED (a file
# crashed an engine or timed out, the build failed, the seal refused).
# It repoints <root>/latest like every lane and never <root>/latest-suite.
# $COUT is where the lane's own files go: <out> for the corpus lane, <out>/corpus-<lane>
# inside a testbed run (two corpus lanes share one <out> there).
host_corpus() {   # host_corpus <sha> <stamp>
    local t0 rc secs extra=() cout="${COUT:-$OUT}"
    [ -n "$CORPUS_DEADLINE" ] && extra+=(--deadline "$CORPUS_DEADLINE")
    [ -n "$CORPUS_LIMIT" ] && extra+=(--limit "$CORPUS_LIMIT")
    [ "$SMOKE" = 1 ] && extra+=(--smoke)
    mkdir -p "$cout"
    t0=$(date +%s)
    run_bounded "$CORPUS_BUDGET" "$cout/corpus.log" "$H_WT" \
        python3 "$SCRIPT_DIR/corpus_run.py" host "$CORPUS_LANE" --sha "$1" --stamp "$2" --out "$cout" \
        --worktree "$H_WT" --derived-data "$H_DD" --bin "$SCRIPT_DIR" ${extra[@]+"${extra[@]}"}
    rc=$?
    secs=$(( $(date +%s) - t0 ))
    echo "corpus $CORPUS_LANE exit=$rc secs=$secs"
    # The helper's summary is read back only when the helper finished its lane (0 GREEN · 1 RED ·
    # 3 AMBER · 4 NORUN), and only through the show door: never a link, one name only, inside this
    # run's folder, lines that could carry a name withheld (Codex #315-3). A refusal (2), a timeout
    # or a crash says so in fixed words; its reason stays in corpus.log on the M4.
    case "$rc" in
        0|1|3|4)
            if [ -f "$cout/corpus-summary.txt" ]; then
                python3 "$SCRIPT_DIR/testbed_host.py" show "$cout/corpus-summary.txt" --under "$cout" >>"$OUT/summary.txt"
            else
                echo "corpus $CORPUS_LANE: RED no summary was written (rc=$rc; see corpus.log on the host)" >>"$OUT/summary.txt"
            fi ;;
        2) echo "corpus $CORPUS_LANE: RED refused by the harness (rc=2; the reason is in corpus.log on the M4)" >>"$OUT/summary.txt"
           # The one refusal Rick must act on at the M4 itself is named here, in fixed words matched
           # on the access probe's own phrases; no text of the log is copied (#315-3).
           if [ -f "$cout/corpus.log" ] && [ ! -L "$cout/corpus.log" ]; then
               if grep -qF "macOS is waiting for permission to read the external volume" "$cout/corpus.log"; then
                   echo "  the M4 is waiting for a privacy prompt on its screen: click Allow (Screen Sharing), or grant the corpus Python Removable Volumes / Full Disk Access in System Settings (path in corpus.log)" >>"$OUT/summary.txt"
               elif grep -qF "macOS does not let this Python read the external volume" "$cout/corpus.log"; then
                   echo "  macOS denied this Python access to the external volume: grant it Removable Volumes / Full Disk Access in System Settings on the M4 (path in corpus.log)" >>"$OUT/summary.txt"
               fi
           fi ;;
        124) ;;
        *) echo "corpus $CORPUS_LANE: RED the harness stopped (rc=$rc; see corpus.log on the M4)" >>"$OUT/summary.txt" ;;
    esac
    case "$rc" in
        0) ;;
        3) [ "$VERDICT" = GREEN ] && VERDICT=AMBER
           AMBER_WHY="corpus $CORPUS_LANE: see the summary" ;;
        4) [ "$VERDICT" = RED ] || VERDICT=NORUN
           WHY="corpus $CORPUS_LANE: this ref has no engine for the lane" ;;
        124) echo "corpus $CORPUS_LANE: RED TIMEOUT after ${secs}s" >>"$OUT/summary.txt"; VERDICT=RED ;;
        *) VERDICT=RED ;;
    esac
}

# Everything, one verdict: the suite lane, then the two corpus lanes — the SAME functions
# the single lanes run, each judged on its own (VERDICT starts GREEN per lane) and recorded
# as one row of <out>/lanes.tsv: name, verdict, seconds, the lane's facts file. The one
# summary block and the run's verdict come from m4_run_summary.py --testbed (0 GREEN ·
# 3 AMBER · 4 NORUN · else RED); the lanes' own lines follow it in summary.txt.
host_testbed() {   # host_testbed <sha> <stamp>
    local sha="$1" stamp="$2" t0 lane_t0 vrc block words=""
    t0=$(date +%s)
    : >"$OUT/lanes.tsv"
    testbed_lane() {   # testbed_lane <name> <facts file> <function> [args…]
        local name="$1" facts="$2"; shift 2
        VERDICT=GREEN; AMBER_WHY=""; WHY=""
        lane_t0=$(date +%s)
        "$@"
        printf '%s\t%s\t%s\t%s\n' "$name" "$VERDICT" "$(( $(date +%s) - lane_t0 ))" "$facts" >>"$OUT/lanes.tsv"
        words="${words:+$words · }$name $VERDICT"
    }
    local corpus_lane corpus_lanes="check proof" smoke_flag=()
    if [ "$SMOKE" = 1 ]; then
        testbed_lane "sensors" "$OUT/sensors-row.json" host_sensors
        corpus_lanes="check proof verbs"; smoke_flag=(--smoke)
    else
        testbed_lane "suite" "$OUT/suite-row.json" host_suite
    fi
    for corpus_lane in $corpus_lanes; do
        CORPUS_LANE="$corpus_lane"; COUT="$OUT/corpus-$corpus_lane"
        testbed_lane "corpus $corpus_lane" "$COUT/corpus-verdict.json" host_corpus "$sha" "$stamp"
    done
    CORPUS_LANE=""; COUT=""
    block="$(python3 "$SCRIPT_DIR/m4_run_summary.py" --testbed "$OUT/lanes.tsv" "$sha" "$(( $(date +%s) - t0 ))" ${smoke_flag[@]+"${smoke_flag[@]}"})"
    vrc=$?
    # The block is built from the lanes' facts files: it reaches a caller only through the show door.
    printf '%s\n' "$block" >"$OUT/testbed-block.raw"
    python3 "$SCRIPT_DIR/testbed_host.py" show "$OUT/testbed-block.raw" --under "$OUT" >"$OUT/testbed-block.txt"
    { cat "$OUT/testbed-block.txt"; echo "— the lanes' own lines —"; cat "$OUT/summary.txt"; } >"$OUT/summary.txt.new" \
        && mv "$OUT/summary.txt.new" "$OUT/summary.txt"
    AMBER_WHY="$words"; WHY="$words"
    case "$vrc" in
        0) VERDICT=GREEN; WHY="" ;;
        3) VERDICT=AMBER ;;
        4) VERDICT=NORUN ;;
        *) VERDICT=RED ;;
    esac
}

host_main() {   # __host <lane> <sha> <stamp>
    local lane="$1" sha="$2" stamp="$3"
    OUT="$H_ROOT/out/$stamp-$lane"
    # The run folder is NEW and this run's (Codex #315-2): ~/m4run and ~/m4run/out are real folders,
    # and the run's own folder did not exist a moment ago — so nothing in it (run.log, summary.txt,
    # a link named like a log) predates this run. Said on stderr (the agent's log): there is no
    # run.log to say it in.
    [[ "$stamp" =~ ^[0-9A-Za-z_]+$ ]] || die "__host wants a stamp of letters, digits and underscores" 2
    [ -L "$H_ROOT" ] || [ -L "$H_ROOT/out" ] && die "refused: $H_ROOT or its out folder is a symlink" 4
    mkdir -p "$H_ROOT/out" || die "cannot prepare $H_ROOT/out" 4
    [ -L "$H_ROOT/out" ] && die "refused: $H_ROOT/out is a symlink" 4
    mkdir "$OUT" 2>/dev/null || die "refused: the run folder $OUT is already there — a run folder is made new, never reused" 4
    exec >"$OUT/run.log" 2>&1
    # VIDEOSCAN_M4RUN_TEST_PATH: a test hook (tests/test_m4_run_suite_lane.py puts stand-ins for xcodebuild and swift first).
    export PATH="${VIDEOSCAN_M4RUN_TEST_PATH:+$VIDEOSCAN_M4RUN_TEST_PATH:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    # Lock first: a refused run must not repoint `latest` away from the live one.
    BUSY=""
    take_lock "$lane sha=${sha:0:9} since $(date '+%F %T') out=$OUT" || { echo "OUTCOME REFUSED $BUSY"; exit 3; }
    trap drop_lock EXIT
    # The window, again, now that the lock is held (Codex #315-6): the caller's check may be minutes old.
    if [ -n "$START_BY" ] && [ "$(date +%s)" -ge "$START_BY" ]; then
        echo "OUTCOME REFUSED window: the run reached its lock after the next window opened (start by $START_BY, now $(date +%s)); pass --force to run anyway"
        exit 5
    fi
    # The watcher's runs: a commit a run under out/ already ran to a verdict is not run again — checked
    # HERE, under the lock, so a run by hand that finished a moment ago counts (Codex #315-5).
    if [ "$UNLESS_RAN" = 1 ]; then
        local ran
        ran="$(python3 "$SCRIPT_DIR/testbed_host.py" ran "$H_ROOT" "$sha" "$OUT")"
        if [ -n "$ran" ]; then
            echo "OUTCOME REFUSED already-run $ran — sha=${sha:0:9} was run to a verdict under $H_ROOT/out; not run again"
            exit 6
        fi
    fi
    ln -sfn "$OUT" "$H_ROOT/latest"
    # Housekeeping, under the lock: old run folders go (the newest of each lane, every RED run and
    # whatever `latest*` names stay). A run with no helper beside it (an older install) skips this.
    [ -f "$SCRIPT_DIR/testbed_host.py" ] && python3 "$SCRIPT_DIR/testbed_host.py" prune "$H_ROOT" --current "$OUT" 2>&1
    # The 15% floor (85% used at rest; DECISIONS 2026-11-18, 2026-11-19), still under the lock: finished runs give up their scratch,
    # dead corpus work goes, and below 15% free older unfinished runs (then the build caches, only when
    # that reaches the floor). One "disk:" line here; the run itself may use as much disk as it needs.
    # The M4 only: the ruling is about the testbed machine, and the helper refuses any root but $HOME/m4run.
    local clean_tool=""
    [ "$H_MACHINE" = m4 ] && [ -f "$SCRIPT_DIR/testbed_host.py" ] && clean_tool="$SCRIPT_DIR/testbed_host.py"
    [ -n "$clean_tool" ] && python3 "$clean_tool" clean "$H_ROOT" --current "$OUT" --phase start 2>&1
    [ "$lane" = suite ] && ln -sfn "$OUT" "$H_ROOT/latest-suite"
    [ "$lane" = testbed ] && ln -sfn "$OUT" "$H_ROOT/latest-testbed"
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
    echo "START $(date '+%F %T') host=$H_NAME lane=$lane${CORPUS_LANE:+ corpus-lane=$CORPUS_LANE} sha=$sha${ONLY:+ only=$ONLY}"
    if [ "$(git -C "$H_WT" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
        echo "OUTCOME RED testbed $H_WT is not at $sha"
        exit 1
    fi
    : >"$OUT/summary.txt"
    VERDICT=GREEN
    AMBER_WHY=""
    WHY=""
    # The lowest free figure while the lanes work (testbed_host.py sample). Started with fd 9 closed:
    # it must never hold the testbed lock. It stops itself on the stop file or when this shell is gone.
    local sampler=""
    if [ -n "$clean_tool" ]; then
        python3 "$clean_tool" sample "$H_ROOT" "$OUT" 9>&- &
        sampler=$!
    fi
    case "$lane" in
        deep)  host_deep ;;
        ui)    host_ui ;;
        all)   host_deep; host_ui ;;
        suite) host_suite ;;
        corpus) host_corpus "$sha" "$stamp" ;;
        testbed) host_testbed "$sha" "$stamp" ;;
    esac
    # Summarized: the verdict is decided and summary.txt written. Now this run gives up its scratch,
    # and the summary (and a testbed run block) gets the disk line: free now, the lowest, the start.
    if [ -n "$sampler" ]; then
        # It looks for the stop file every second; give it 30 and go on without it (never an unbounded wait, F6).
        # The marker is made by the helper through the run folder descriptor: never through a planted link (Codex #323 R1).
        python3 "$clean_tool" stop "$H_ROOT" "$OUT" 2>/dev/null
        local waited=0
        while kill -0 "$sampler" 2>/dev/null && [ "$waited" -lt 30 ]; do sleep 1; waited=$((waited + 1)); done
        kill -0 "$sampler" 2>/dev/null || wait "$sampler" 2>/dev/null
    fi
    if [ -n "$clean_tool" ]; then
        # The helper writes the disk line into summary.txt (a testbed run: also the end of its block) through
        # the run folder descriptor (Codex #323 R1); if it cannot, it says the line on stderr, into run.log.
        python3 "$clean_tool" clean "$H_ROOT" --current "$OUT" --phase end >/dev/null
    fi
    [ "$VERDICT" = AMBER ] && WHY="$AMBER_WHY"
    # A SMOKE run says so on its OUTCOME line too (Codex #336 F7).
    [ "$SMOKE" = 1 ] && WHY="SMOKE (a stratified subset: the harness, the host and the code run end to end; never a baseline)${WHY:+ · $WHY}"
    echo "OUTCOME $VERDICT $(date '+%F %T') lane=$lane sha=${sha:0:9}${WHY:+ — $WHY}"
    sed 's/^/  /' "$OUT/summary.txt"
    case "$VERDICT" in GREEN|AMBER) return 0 ;; *) return 1 ;; esac
}

# ── Arguments ─────────────────────────────────────────────────────────────
LANE="${1:-}"; [ $# -gt 0 ] && shift
HOST=m4; REF=main; DRY=0; FORCE=0; WAIT=0; ONLY=""; PLAN_TIMEOUT=""; JSON=0
CORPUS_LANE=""; CORPUS_DEADLINE=""; CORPUS_LIMIT=""; COUT=""; START_BY=""; UNLESS_RAN=0; SMOKE=0
POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 || usage ;;
        --ref) REF="${2:-}"; shift 2 || usage ;;
        --only) ONLY="${2:-}"; shift 2 || usage ;;
        --plan-timeout) PLAN_TIMEOUT="${2:-}"; shift 2 || usage ;;
        --corpus-lane) CORPUS_LANE="${2:-}"; shift 2 || usage ;;
        --deadline) CORPUS_DEADLINE="${2:-}"; shift 2 || usage ;;
        --limit) CORPUS_LIMIT="${2:-}"; shift 2 || usage ;;
        --dry-run) DRY=1; shift ;;
        --force) FORCE=1; shift ;;
        --wait) WAIT=1; shift ;;
        --json) JSON=1; shift ;;
        --start-by) START_BY="${2:-}"; shift 2 || usage ;;
        --unless-ran) UNLESS_RAN=1; shift ;;
        --smoke) SMOKE=1; shift ;;
        -h|--help) usage ;;
        --*) die "unknown option $1" 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done
[ -n "$PLAN_TIMEOUT" ] && ! [[ "$PLAN_TIMEOUT" =~ ^[0-9]+$ ]] && die "--plan-timeout wants seconds" 2
[ -n "$ONLY" ] && ! [[ "$ONLY" =~ ^[A-Za-z0-9_,]+$ ]] && die "--only wants UI test class names (A,B)" 2
[ -n "$CORPUS_DEADLINE" ] && ! [[ "$CORPUS_DEADLINE" =~ ^[0-9]+$ ]] && die "--deadline wants seconds" 2
[ -n "$CORPUS_LIMIT" ] && ! [[ "$CORPUS_LIMIT" =~ ^[0-9]+$ ]] && die "--limit wants a number of files" 2
[ -n "$START_BY" ] && ! [[ "$START_BY" =~ ^[0-9]+$ ]] && die "--start-by wants epoch seconds" 2
# The corpus lane: the M4 only (never the Ultra, Rick's machine), and its options belong to it alone.
corpus_args_ok() {
    [ "$H_MACHINE" = m4 ] || die "the corpus harness runs only on the M4 (--host $HOST refused)" 2
    case "$CORPUS_LANE" in prepare|check|proof|verbs|coverage) ;; *) die "--corpus-lane wants prepare|check|proof|verbs|coverage" 2 ;; esac
    [ -z "$ONLY$PLAN_TIMEOUT" ] || die "--only/--plan-timeout do not apply to the corpus lane" 2
}
# The testbed lane holds the corpus lanes, so it is the M4's alone too; it takes no lane options (it runs everything).
testbed_args_ok() {
    [ "$H_MACHINE" = m4 ] || die "the testbed lane holds the corpus lanes, which run only on the M4 (--host $HOST refused)" 2
    [ -z "$ONLY$PLAN_TIMEOUT$CORPUS_LANE$CORPUS_DEADLINE$CORPUS_LIMIT" ] \
        || die "the testbed lane runs everything: --only/--plan-timeout/--corpus-lane/--deadline/--limit do not apply" 2
}
[ "$LANE" = corpus ] || [ "${POS[0]:-}" = corpus ] || [ -z "$CORPUS_LANE$CORPUS_DEADLINE$CORPUS_LIMIT" ] \
    || die "--corpus-lane/--deadline/--limit apply to the corpus lane" 2
case "$SMOKE:$LANE:${POS[0]:-}" in
    0:*|1:testbed:*|1:__host:testbed) ;;
    1:corpus:*|1:__host:corpus)
        case "$CORPUS_LANE" in check|proof|verbs) ;; *) die "--smoke applies to corpus check, proof and verbs" 2 ;; esac ;;
    *) die "--smoke applies to the testbed lane and to corpus check, proof and verbs" 2 ;;
esac
host_config "$HOST"
[ "$JSON" = 1 ] && [ "$LANE" != status ] && die "--json applies to status" 2

case "$LANE" in
    corpus)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        corpus_args_ok
        start_run ;;
    ui|deep|all|suite)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        [ -n "$ONLY" ] && [ "$LANE" != ui ] && die "--only applies to the ui lane" 2
        start_run ;;
    testbed)
        [ ${#POS[@]} -eq 0 ] || die "unexpected argument ${POS[0]}" 2
        testbed_args_ok
        start_run ;;
    status)
        if [ "$JSON" = 1 ]; then
            on_host "$(host_tool_snippet status-json "$H_ROOT" "$H_NAME")" || die "cannot reach $H_NAME (${H_SSH:-local})"
            exit 0
        fi
        [ "$DRY" = 1 ] && { on_host "$(status_snippet)"; exit 0; }
        on_host "$(status_snippet)" || die "cannot reach $H_NAME (${H_SSH:-local})" ;;
    __host)
        [ ${#POS[@]} -eq 3 ] || die "__host <lane> <sha> <stamp>" 2
        case "${POS[0]}" in ui|deep|all|suite) ;; corpus) corpus_args_ok ;; testbed) testbed_args_ok ;; *) die "bad lane ${POS[0]}" 2 ;; esac
        # The host side of the corpus lanes does its work HERE: `--host m4` is only a label, so the
        # Mac itself must be the M4 before a worktree is checked out or a file written (Codex #311 F5).
        case "${POS[0]}" in corpus|testbed)
            [ "$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" = ricksm4 ] \
                || die "the corpus lanes run only on the M4; this Mac is not the M4" 2 ;;
        esac
        host_main "${POS[@]}" ;;
    ""|-h|--help) usage ;;
    *) die "unknown lane '$LANE' (ui|deep|all|suite|testbed|corpus|status)" 2 ;;
esac
