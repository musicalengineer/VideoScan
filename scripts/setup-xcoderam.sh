#!/bin/bash
# setup-xcoderam.sh — create a RAM-disk-backed DerivedData volume for Xcode.
#
# Source code stays on SSD; only the build cache lives in RAM. Re-run any time
# /Volumes/XcodeRAM (or your chosen name) is missing — e.g. after a reboot.
#
# Defaults: 4 GB, volume name "XcodeRAM". Override with --size N (GB) and
# --name LABEL. Idempotent: bails if the target volume is already mounted.
#
# Usage:
#   setup-xcoderam.sh                 # 4 GB, /Volumes/XcodeRAM
#   setup-xcoderam.sh --size 8        # 8 GB
#   setup-xcoderam.sh --size 6 --name ProjectXRAM
set -euo pipefail

SIZE_GB=4
NAME="XcodeRAM"

while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE_GB="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

MOUNT="/Volumes/$NAME"

if [ -d "$MOUNT" ]; then
    echo "$NAME already mounted — nothing to do."
    df -h "$MOUNT"
    exit 0
fi

# hdiutil takes sectors; 512 B each → 2 Mi sectors per GB.
SECTORS=$(( SIZE_GB * 1024 * 1024 * 2 ))

DEV=$(hdiutil attach -nomount "ram://$SECTORS" | awk '{print $1}')
echo "Created ${SIZE_GB} GB RAM device: $DEV"
diskutil erasevolume APFS "$NAME" "$DEV"

# Point Xcode at the RAM-backed DerivedData. Persists across reboots, but
# re-assert each run in case prefs were reset (or this is a fresh machine).
defaults write com.apple.dt.Xcode IDECustomDerivedDataLocation "$MOUNT"
defaults write com.apple.dt.Xcode IDEDerivedDataLocationStyle 2

echo ""
echo "Ready. Restart Xcode if it's open so it picks up the new DerivedData."
df -h "$MOUNT"
