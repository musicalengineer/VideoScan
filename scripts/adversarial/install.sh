#!/bin/bash
# Install (or remove) the nightly adversarial review LaunchAgents (2026-10-01).
#
#   bash scripts/adversarial/install.sh                 # install, pointing at ~/dev/VideoScan
#   bash scripts/adversarial/install.sh --checkout DIR  # point at another checkout
#   bash scripts/adversarial/install.sh --uninstall
#
# Installs com.videoscan.adversarial-review (00:30, Tier A) and
# com.videoscan.adversarial-confirm (05:30, red tests) from the templates
# beside this script. REFUSES unless the tool reports SHADOW MODE on: these
# jobs may only write a review doc, a ledger row and the morning line until
# Rick turns filing on after the shadow week.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKOUT="$HOME/dev/VideoScan"
UNINSTALL=false
while [ $# -gt 0 ]; do
    case "$1" in
        --checkout) CHECKOUT="$2"; shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        *) echo "usage: $0 [--checkout DIR] [--uninstall]" >&2; exit 2 ;;
    esac
done
AGENTS="$HOME/Library/LaunchAgents"
LABELS=(com.videoscan.adversarial-review com.videoscan.adversarial-confirm)
DOMAIN="gui/$(id -u)"

if $UNINSTALL; then
    for label in "${LABELS[@]}"; do
        launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
        if [ -f "$AGENTS/$label.plist" ]; then
            mkdir -p "$HOME/Library/LaunchAgents/.trash"
            mv "$AGENTS/$label.plist" "$HOME/Library/LaunchAgents/.trash/$label.plist.$(date +%Y%m%d-%H%M%S)"
        fi
        echo "removed $label"
    done
    exit 0
fi

TOOL="$CHECKOUT/tools/adversarial_nightly.py"
if [ ! -f "$TOOL" ]; then
    echo "WARNING: $TOOL does not exist yet (branch not merged into that checkout?)." >&2
    echo "         The agents will be installed, but each night will fail until it does;" >&2
    echo "         the morning line then reads 'did not run'." >&2
    SHADOW_SOURCE="$HERE/../../tools/adversarial_nightly.py"
else
    SHADOW_SOURCE="$TOOL"
fi

# Shadow-mode gate: ask the tool that will run, not a grep of its text.
SHADOW=$(/usr/bin/python3 "$SHADOW_SOURCE" status --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["shadow"])')
if [ "$SHADOW" != "True" ]; then
    echo "REFUSING: $SHADOW_SOURCE reports shadow=$SHADOW. Filing/Tier B need Rick's go-ahead." >&2
    exit 1
fi
echo "shadow mode: ON ($SHADOW_SOURCE)"

mkdir -p "$AGENTS" "$HOME/Library/Logs/VideoScan"
for label in "${LABELS[@]}"; do
    target="$AGENTS/$label.plist"
    sed -e "s#__HOME__#$HOME#g" -e "s#__CHECKOUT__#$CHECKOUT#g" "$HERE/$label.plist" > "$target.tmp"
    plutil -lint "$target.tmp" >/dev/null
    mv "$target.tmp" "$target"
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$target"
    echo "installed $label -> $target"
done
launchctl list | grep -E 'com\.videoscan\.adversarial' || { echo "not listed by launchctl" >&2; exit 1; }
