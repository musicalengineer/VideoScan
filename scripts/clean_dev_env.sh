#!/usr/bin/env bash
#
# clean_dev_env.sh — purge Xcode caches and tune env for faster builds.
#
# What it does:
#   1. Quits Xcode + VideoScan if running (graceful AppleEvent).
#   2. Deletes DerivedData, Xcode's user cache, and SwiftPM caches.
#   3. Marks DerivedData with .metadata_never_index so Spotlight skips it.
#   4. Adds DerivedData and project build dirs to Time Machine exclusions.
#   5. Sets a handful of Xcode defaults to stop background polling
#      (source-control auto-refresh, preview auto-rebuild on save).
#
# When to run:
#   - When Xcode incremental builds start feeling sluggish.
#   - After an Xcode upgrade.
#   - When SourceKit gets confused ("Cannot find type X" with no real cause).
#
# Safe to run repeatedly. Xcode must be quit to apply the defaults.

set -u

echo "=== Quitting Xcode + VideoScan (silent if not running) ==="
osascript -e 'tell application "Xcode" to quit' 2>/dev/null || true
osascript -e 'tell application "VideoScan" to quit' 2>/dev/null || true
sleep 2
pkill -f sourcekit 2>/dev/null || true
pkill -f SourceKitService 2>/dev/null || true

echo ""
echo "=== Before ==="
du -sh ~/Library/Developer/Xcode/DerivedData \
       ~/Library/Caches/com.apple.dt.Xcode \
       ~/Library/Caches/org.swift.swiftpm 2>/dev/null || true
df -h ~ | tail -1

echo ""
echo "=== Purging caches ==="
rm -rf ~/Library/Developer/Xcode/DerivedData
rm -rf ~/Library/Caches/com.apple.dt.Xcode
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf ~/Library/org.swift.swiftpm
rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport/* 2>/dev/null || true

mkdir -p ~/Library/Developer/Xcode/DerivedData
touch ~/Library/Developer/Xcode/DerivedData/.metadata_never_index

echo ""
echo "=== Time Machine exclusions ==="
tmutil addexclusion ~/Library/Developer/Xcode/DerivedData 2>/dev/null || true
tmutil addexclusion ~/dev/VideoScan/build 2>/dev/null || true
tmutil addexclusion ~/dev/VideoScan/.build 2>/dev/null || true

echo ""
echo "=== Xcode defaults (Xcode must be quit) ==="
defaults write com.apple.dt.Xcode IDESourceControlAutomaticallyRefreshSnapshotInformation -bool NO
defaults write com.apple.dt.Xcode IDESourceControlEnableSourceControl -bool YES
defaults write com.apple.dt.Xcode IDEPreviewsRebuildOnSave -bool NO
defaults write com.apple.dt.Xcode BuildSystemScheduleInherentlyParallelCommandsExclusively -bool NO
defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks -int 8

echo ""
echo "=== After ==="
du -sh ~/Library/Developer/Xcode/DerivedData \
       ~/Library/Caches/com.apple.dt.Xcode 2>/dev/null || true
df -h ~ | tail -1

echo ""
echo "Done. Re-open Xcode; first build will be a full cold compile."
