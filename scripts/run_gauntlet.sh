#!/bin/bash
# Phase 1 release runner. No app/UI work without the explicit --away flag.
set -euo pipefail
SCRIPT_DIR="$(/usr/bin/dirname "$0")"
RUNNER="$SCRIPT_DIR/gauntlet/Runner.swift"
# A new scratch compiler cache avoids inherited cache paths and symlink reuse.
SWIFT_CACHE="$(/usr/bin/mktemp -d /private/tmp/videoscan-gauntlet-swift.XXXXXX)"
case " $* " in
  *" --dry-run "*|*" --help "*|*" -h "*) exec /usr/bin/swift -module-cache-path "$SWIFT_CACHE" "$RUNNER" "$@" ;;
  *) exec /usr/bin/caffeinate -dimsu /usr/bin/swift -module-cache-path "$SWIFT_CACHE" "$RUNNER" "$@" ;;
esac
