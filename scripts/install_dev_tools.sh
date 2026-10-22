#!/usr/bin/env bash
# scripts/install_dev_tools.sh — bring up a new Mac as a VideoScan dev machine.
#
# Before: Xcode 27 (open it once, accept the license), Homebrew, `gh auth login`,
#         git clone https://github.com/musicalengineer/VideoScan.git ~/dev/VideoScan
# Run:    ~/dev/VideoScan/scripts/install_dev_tools.sh
# After:  open VideoScan/VideoScan.xcodeproj, scheme VideoScan, Debug,
#         Product ▸ Clean Build Folder, then ⌘R.
#
# Installs the dev tools only (brew packages, Python venvs, Swift packages,
# helpers, git hooks). No family data: the catalog and media come later with
# install_videoscan_dev_dependencies/migrate_data.sh. Idempotent; --check
# reports without changing anything. All options pass through to the real
# installer: install_videoscan_dev_dependencies/install.sh --help.

set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install_videoscan_dev_dependencies/install.sh" "$@"
