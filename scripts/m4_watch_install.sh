#!/usr/bin/env bash
# m4_watch_install.sh — install, remove or look at the push watcher on the M4
# (scripts/m4_watch.py; docs/guides/operations.md §1 "The push trigger").
#
#   scripts/m4_watch_install.sh install   [--dry-run]
#   scripts/m4_watch_install.sh uninstall [--dry-run]
#   scripts/m4_watch_install.sh status    [--dry-run]
#
# Run from the Ultra (it does everything on the M4 over ssh) or on the M4 itself.
# The M4 ONLY: the host side refuses any Mac whose own name is not the M4's, so this
# can never install an agent on the Ultra.
#
#   install    1. copies a PINNED set of scripts from THIS checkout to ~/m4run/bin/watch
#                 on the M4 (m4_watch.py, m4_run.sh and what the suite lane needs), with
#                 the commit they came from in ~/m4run/bin/watch/VERSION — the watcher
#                 never runs from a checkout, so a branch switch on the M4 cannot change it;
#              2. writes ~/Library/LaunchAgents/com.videoscan.m4watch.plist from
#                 scripts/launchd/com.videoscan.m4watch.plist (__HOME__ filled in);
#              3. `launchctl bootstrap gui/<uid>` — the GUI session, like every run's own
#                 agent. An installed watcher is booted out first (install = reinstall).
#   uninstall  `launchctl bootout gui/<uid>/com.videoscan.m4watch`, then MOVES the plist
#              to ~/m4run/watch/uninstalled/ (nothing is deleted). The pinned scripts and
#              ~/m4run/watch (its state and verdict history) stay; a run it started keeps
#              going — it belongs to m4_run.sh, not to the watcher.
#   status     whether launchd has the agent, the pinned VERSION, the verdict line and
#              the last tick.
#
# One tick every 300 s; a tick starts at most one `m4_run.sh suite --host m4local` run,
# under the testbed lock and the quiet window, and publishes nothing.
#
# Exit: 0 done · 1 the M4 refused or could not be reached · 2 usage.
# Tests: tests/test_m4_watch.py (dry-run plans, and the host side for real in a fake HOME
# with a stand-in launchctl).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
M4_SSH="ricksm4.local"
LABEL="com.videoscan.m4watch"
PINNED=(m4_watch.py m4_run.sh m4_run_summary.py testbed_lock.py testbed_host.py nightly_local_tests.sh lib/process_group_watchdog.sh)

usage() { sed -n '4,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

VERB="${1:-}"; [ $# -gt 0 ] && shift
DRY=0
case "${1:-}" in --dry-run) DRY=1; shift ;; esac
[ $# -eq 0 ] || usage
case "$VERB" in install|uninstall|status) ;; *) usage ;; esac

# On the M4 itself there is no ssh. Decided by this Mac's own name only.
LOCAL=0
[ "$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" = ricksm4 ] && LOCAL=1

on_m4() {   # on_m4 <shell snippet>
    if [ "$DRY" = 1 ]; then
        if [ "$LOCAL" = 1 ]; then echo "+ bash <<'SH'"; else echo "+ ssh $M4_SSH <<'SH'"; fi
        printf '%s\n' "$1" | sed 's/^/    /'
        echo "  SH"
        return 0
    fi
    if [ "$LOCAL" = 1 ]; then bash -s <<<"$1"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$M4_SSH" bash -s <<<"$1"; fi
}

copy_to_m4() {   # copy_to_m4 <local file> <path under the host's home>
    if [ "$DRY" = 1 ]; then echo "+ install $1 -> ${M4_SSH}:~/$2"; return 0; fi
    if [ "$LOCAL" = 1 ]; then cp "$1" "$HOME/$2"; else ssh -o BatchMode=yes -o ConnectTimeout=15 "$M4_SSH" "cat > \"\$HOME/$2\"" <"$1"; fi
}

# Every host snippet starts with this: any Mac but the M4 stops here, before anything is written.
GUARD='[ "$(hostname -s 2>/dev/null | tr "[:upper:]" "[:lower:]")" = ricksm4 ] || { echo "m4_watch_install: refused — this Mac is not the M4"; exit 1; }'

case "$VERB" in
    install)
        sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
        on_m4 "$GUARD
mkdir -p \"\$HOME/m4run/bin/watch.new/lib\" \"\$HOME/m4run/watch\" \"\$HOME/Library/LaunchAgents\"" || { echo "m4_watch_install: the M4 refused or could not be reached" >&2; exit 1; }
        for f in "${PINNED[@]}"; do
            copy_to_m4 "$SCRIPT_DIR/$f" "m4run/bin/watch.new/$f" || { echo "m4_watch_install: could not copy $f" >&2; exit 1; }
        done
        plist="$(cat "$SCRIPT_DIR/launchd/$LABEL.plist")"
        on_m4 "$GUARD
uid=\$(id -u)
new=\"\$HOME/m4run/bin/watch.new\"; pinned=\"\$HOME/m4run/bin/watch\"
echo '$sha' > \"\$new/VERSION\"
chmod +x \"\$new/m4_run.sh\" \"\$new/m4_watch.py\"
# The agent goes first, so no tick runs while the pinned copy is swapped.
launchctl bootout \"gui/\$uid/$LABEL\" 2>/dev/null || true
if [ -d \"\$pinned\" ]; then
  mkdir -p \"\$HOME/m4run/watch/replaced\"
  mv \"\$pinned\" \"\$HOME/m4run/watch/replaced/watch-\$(date +%Y%m%d_%H%M%S)\"
fi
mv \"\$new\" \"\$pinned\"
cat > \"\$HOME/Library/LaunchAgents/$LABEL.plist\" <<'PLIST'
$plist
PLIST
/usr/bin/sed -i '' \"s|__HOME__|\$HOME|g\" \"\$HOME/Library/LaunchAgents/$LABEL.plist\"
launchctl bootstrap \"gui/\$uid\" \"\$HOME/Library/LaunchAgents/$LABEL.plist\" || { echo 'm4_watch_install: launchctl bootstrap failed'; exit 1; }
echo \"installed: $LABEL in gui/\$uid — plist \$HOME/Library/LaunchAgents/$LABEL.plist, every 300 s, pinned scripts \$pinned at $sha\"" \
            || { echo "m4_watch_install: install failed on the M4" >&2; exit 1; }
        ;;
    uninstall)
        on_m4 "$GUARD
uid=\$(id -u)
launchctl bootout \"gui/\$uid/$LABEL\" 2>/dev/null && echo 'booted out $LABEL' || echo '$LABEL was not loaded'
plist=\"\$HOME/Library/LaunchAgents/$LABEL.plist\"
if [ -f \"\$plist\" ]; then
  mkdir -p \"\$HOME/m4run/watch/uninstalled\"
  mv \"\$plist\" \"\$HOME/m4run/watch/uninstalled/$LABEL.\$(date +%Y%m%d_%H%M%S).plist\"
  echo \"uninstalled: the plist was moved to \$HOME/m4run/watch/uninstalled/ (the pinned scripts and the watcher's history stay)\"
else
  echo 'uninstalled: no plist was installed'
fi" || { echo "m4_watch_install: the M4 refused or could not be reached" >&2; exit 1; }
        ;;
    status)
        on_m4 "$GUARD
uid=\$(id -u)
if launchctl print \"gui/\$uid/$LABEL\" >/dev/null 2>&1; then echo \"$LABEL: loaded in gui/\$uid\"; else echo '$LABEL: not loaded'; fi
[ -f \"\$HOME/Library/LaunchAgents/$LABEL.plist\" ] && echo \"plist: \$HOME/Library/LaunchAgents/$LABEL.plist\" || echo 'plist: not installed'
[ -f \"\$HOME/m4run/bin/watch/VERSION\" ] && echo \"pinned scripts: \$HOME/m4run/bin/watch at \$(cat \"\$HOME/m4run/bin/watch/VERSION\")\" || echo 'pinned scripts: none'
[ -f \"\$HOME/m4run/watch/verdict.txt\" ] && echo \"verdict: \$(head -1 \"\$HOME/m4run/watch/verdict.txt\")\" || echo 'verdict: none yet'
[ -f \"\$HOME/m4run/watch/tick.txt\" ] && echo \"last tick: \$(head -1 \"\$HOME/m4run/watch/tick.txt\")\" || echo 'last tick: none yet'" \
            || { echo "m4_watch_install: the M4 refused or could not be reached" >&2; exit 1; }
        ;;
esac
