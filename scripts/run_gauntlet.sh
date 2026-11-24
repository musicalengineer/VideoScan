#!/bin/bash
# Phase 1 release runner. No app/UI work without the explicit --away flag.
set -euo pipefail
SCRIPT_DIR="$(/usr/bin/dirname "$0")"
RUNNER="$SCRIPT_DIR/gauntlet/Runner.swift"
# A new scratch compiler cache avoids inherited cache paths and symlink reuse. It is this script's
# own allocation, so this script frees it when swift exits (2026-11-24: it used to `exec` swift, and
# one cache per run stayed in /private/tmp for good). In TMPDIR: the caller's scratch when it has one.
SWIFT_CACHE="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/videoscan-gauntlet-swift.XXXXXX")"
trap '/bin/rm -rf "$SWIFT_CACHE"' EXIT
# A signal still frees it: bash runs the EXIT trap once the runner (same process group, same signal) is done.
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
case " $* " in
  *" --dry-run "*|*" --help "*|*" -h "*) /usr/bin/swift -module-cache-path "$SWIFT_CACHE" "$RUNNER" "$@" ;;
  *) /usr/bin/caffeinate -dimsu /usr/bin/swift -module-cache-path "$SWIFT_CACHE" "$RUNNER" "$@" ;;
esac
