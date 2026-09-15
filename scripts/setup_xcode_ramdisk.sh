#!/bin/bash
# setup_xcode_ramdisk.sh — create a RAM-disk-backed DerivedData volume for Xcode.
#
# Source code stays on SSD; only the build cache lives in RAM. Re-run any time
# /Volumes/XcodeRAM (or your chosen name) is missing — e.g. after a reboot.
# The LaunchAgent com.rickb.xcode-ramdisk invokes this path at login.
#
# Defaults: 16 GB, volume name "XcodeRAM". Override with --size N (GB) and
# --name LABEL. Idempotent: bails if the target volume is already mounted.
#
# 16 GB is the standard (2026-07-02): 8 GB overflowed under parallel agent builds.
#
# Usage:
#   setup_xcode_ramdisk.sh                 # 16 GB, /Volumes/XcodeRAM
#   setup_xcode_ramdisk.sh --size 8        # 8 GB
#   setup_xcode_ramdisk.sh --size 6 --name ProjectXRAM
set -euo pipefail

SIZE_GB=16
NAME="XcodeRAM"

while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE_GB="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

MOUNT="/Volumes/$NAME"

if [ -d "$MOUNT" ]; then
    echo "$NAME already mounted — skipping creation."
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
