#!/usr/bin/env bash
#
# Select a Swift 6.2+ toolchain for CI and verify it.
#
# WHY THIS EXISTS
# ---------------
# Since 8826951f (2026-06-10) the app uses Swift 6.2 isolated conformances
# — `final class TranscodeJob: @MainActor MediaFileOperationJob` (SE-0470),
# in 18 files. Swift 6.1, which ships with Xcode 16.4, cannot parse that;
# it reports `error: unknown attribute 'MainActor'`. CI was pinned to
# /Applications/Xcode_16.4.app, so every run from mid-June to 2026-08-30
# died in SwiftCompile without reaching a single test.
#
# The 16.4 pin was deliberate once (a5b9e755, 2026-05-11) — a workaround
# for slow hosted test runs. It is no longer a choice: 16.4 cannot compile
# this source at all.
#
# Two design points, both aimed at not repeating the failure:
#
#  1. Resolve by glob, newest first, never a hard-coded app path. GitHub's
#     images add and retire Xcode point releases continuously; a pinned
#     path silently rots. Today the macos-15 image carries 26.0.1, 26.1.1,
#     26.2 and 26.3.
#  2. Verify the resulting compiler is actually >= 6.2 and fail loudly here
#     if not. Otherwise the failure surfaces 4 minutes later as "unknown
#     attribute", which reads like a source bug — that misdirection is why
#     this went unnoticed for ten weeks.
#
# Usage:  scripts/ci_select_xcode.sh          # newest Xcode 26.x
#         scripts/ci_select_xcode.sh 27       # newest Xcode 27.x
#         RESOLVE_ONLY=1 scripts/ci_select_xcode.sh   # print path, don't switch
#
# -e matters here (codex review, #885): without it a failing
# `sudo xcode-select -s` would fall through and the checks below would then
# describe whatever toolchain was ALREADY selected. On an image whose default
# happens to be 26.x that turns a failed selection into a silent pass — the
# exact class of masking this script exists to prevent.
set -euo pipefail

MAJOR_WANTED="${1:-26}"
MIN_SWIFT_MAJOR=6
MIN_SWIFT_MINOR=2

DEV=""
for app in $(ls -d "/Applications/Xcode_${MAJOR_WANTED}"*.app 2>/dev/null | sort -Vr || true); do
  if [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]; then
    DEV="$app/Contents/Developer"
    break
  fi
done

if [ -z "$DEV" ]; then
  echo "::error::No Xcode ${MAJOR_WANTED}.x found — this source needs Swift ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR}+. Installed: $(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
  exit 1
fi

if [ -n "${RESOLVE_ONLY:-}" ]; then
  echo "$DEV"
  exit 0
fi

if ! sudo xcode-select -s "$DEV"; then
  echo "::error::xcode-select failed to switch to $DEV"
  exit 1
fi
echo "Selected $DEV"
xcodebuild -version

# `|| true` so an unparseable or failing toolchain reaches the explicit
# message below instead of exiting bare under -e/pipefail.
SWIFT_RAW=$(swift --version 2>&1 || true)
echo "$SWIFT_RAW"
SWIFT_VER=$(printf '%s\n' "$SWIFT_RAW" | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
if [ -z "$SWIFT_VER" ]; then
  echo "::error::Could not parse a Swift version from the selected toolchain at $DEV."
  exit 1
fi
SWIFT_MAJOR=${SWIFT_VER%%.*}
SWIFT_MINOR=$(echo "${SWIFT_VER}." | cut -d. -f2)
if [ "$SWIFT_MAJOR" -lt "$MIN_SWIFT_MAJOR" ] || \
   { [ "$SWIFT_MAJOR" -eq "$MIN_SWIFT_MAJOR" ] && [ "${SWIFT_MINOR:-0}" -lt "$MIN_SWIFT_MINOR" ]; }; then
  echo "::error::Swift $SWIFT_VER is too old — isolated conformances need ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR}+ (Xcode ${MAJOR_WANTED}.x)."
  exit 1
fi
echo "Swift $SWIFT_VER OK (need >= ${MIN_SWIFT_MAJOR}.${MIN_SWIFT_MINOR})"
