#!/bin/bash
# setup_xcode_ramdisk.sh — create a RAM-disk-backed DerivedData volume for Xcode.
#
# Source code stays on SSD; only the build cache lives in RAM. Run it when you
# want the speedup; run it again after a reboot, which always takes the RAM
# disk with it. This is deliberately NOT a login agent (decision 2026-09-15) —
# Rick starts it when he wants it.
#
# Defaults: 16 GB, volume name "XcodeRAM". Override with --size N (GB) and
# --name LABEL. Idempotent: bails if the target volume is already mounted.
#
# 16 GB is the standard (2026-07-02): 8 GB overflowed under parallel agent builds.
#
# WHY --off EXISTS. Setup points Xcode's DerivedData at $MOUNT via `defaults`,
# and those prefs persist across reboots — the RAM disk does not. Boot without
# running setup and Xcode happily writes DerivedData to /Volumes/XcodeRAM as an
# ORDINARY DIRECTORY on the boot SSD: no speedup, silent SSD wear, and no
# warning. Worse, that stray directory then looks like a mounted volume to a
# naive `-d` test, so the next setup run would skip creation and you would
# build on SSD believing you were in RAM. `--off` is how you leave the RAM disk
# cleanly: eject it AND put the Xcode prefs back to default.
#
# Usage:
#   setup_xcode_ramdisk.sh                 # 16 GB, /Volumes/XcodeRAM
#   setup_xcode_ramdisk.sh --size 8        # 8 GB
#   setup_xcode_ramdisk.sh --size 6 --name ProjectXRAM
#   setup_xcode_ramdisk.sh --off           # eject + restore default DerivedData
set -euo pipefail

SIZE_GB=16
NAME="XcodeRAM"
OFF=0

while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE_GB="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --off)  OFF=1; shift ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

MOUNT="/Volumes/$NAME"

# A real mount test. `[ -d "$MOUNT" ]` is NOT one: a leftover plain directory
# (see --off in the header) passes it, and we would skip creation and build on
# SSD while reporting success.
is_mounted() { mount | grep -q " on $MOUNT ("; }

if [ "$OFF" = "1" ]; then
    if is_mounted; then
        echo "Ejecting $MOUNT …"
        diskutil eject "$MOUNT"
    else
        echo "$NAME is not mounted."
    fi
    # Restore Xcode's default DerivedData location, or the next build without a
    # RAM disk lands on the boot SSD at a path nobody thinks to look at.
    defaults delete com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true
    defaults write com.apple.dt.Xcode IDEDerivedDataLocationStyle -int 0
    echo "Xcode DerivedData restored to its default location."
    if pgrep -x Xcode >/dev/null; then
        echo "NOTE: Xcode is running — quit and relaunch so it picks up the change."
    fi
    exit 0
fi

if is_mounted; then
    echo "$NAME already mounted — skipping creation."
elif [ -e "$MOUNT" ]; then
    # Not a mount, but something is there: the silent-SSD-fallback case.
    echo "ERROR: $MOUNT exists but is NOT a mounted volume." >&2
    echo "  That is a plain directory on the boot SSD — most likely Xcode wrote" >&2
    echo "  DerivedData there after a reboot with no RAM disk. Inspect it, then" >&2
    echo "  remove it and re-run:  rm -rf '$MOUNT'" >&2
    du -sh "$MOUNT" 2>/dev/null >&2 || true
    exit 1
else
    # ram:// takes 512-byte sectors → 2 Mi sectors per GB.
    # `diskutil image attach` replaces the deprecated `hdiutil attach -nomount`;
    # it prints "<dev>\t<content hint>\t<mount point>", so take field 1.
    SECTORS=$(( SIZE_GB * 1024 * 1024 * 2 ))
    DEV=$(diskutil image attach --noMount "ram://$SECTORS" | awk 'NR==1 {print $1}')
    echo "Created ${SIZE_GB} GB RAM device: $DEV"
    diskutil erasevolume APFS "$NAME" "$DEV"
fi

# Point Xcode at the RAM-backed DerivedData. Persists across reboots, but
# re-assert each run in case prefs were reset (or this is a fresh machine).
defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation "$MOUNT"
defaults write com.apple.dt.Xcode IDEDerivedDataLocationStyle 2

echo ""
df -h "$MOUNT"

# Verify the Xcode prefs actually stuck — a running Xcode can silently
# overwrite them on quit. Reading them back is the only honest check.
echo ""
STYLE=$(defaults read com.apple.dt.Xcode IDEDerivedDataLocationStyle 2>/dev/null || echo "<unset>")
LOC=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || echo "<unset>")
if [ "$STYLE" = "2" ] && [ "$LOC" = "$MOUNT" ]; then
    echo "Xcode prefs OK: Custom DerivedData → $LOC (style=$STYLE)"
else
    echo "WARNING: Xcode prefs do not match expected values."
    echo "  IDEDerivedDataLocationStyle  = $STYLE  (expected 2)"
    echo "  IDECustomDerivedDataLocation = $LOC"
    echo "  Expected mount               = $MOUNT"
    echo "  Quit Xcode if it's running and re-run this script."
fi

if pgrep -x Xcode >/dev/null; then
    echo "NOTE: Xcode is running — quit and relaunch so it picks up the location."
fi
