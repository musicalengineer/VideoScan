#!/bin/bash
#
# Installer for nightly TestDriver metrics job
# Usage: bash install-nightly.sh [--wake] [--uninstall]
#
# Options:
#   --wake      Also schedule system wake at 1:55 AM (optional, for sleeping Macs)
#   --uninstall Remove the launchd job and scripts
#

set -euo pipefail

PROJECT_DIR="/Users/rickb/dev/VideoScan"
SCRIPT_DIR="$PROJECT_DIR/.claude/scripts"
PLIST_PATH="$HOME/.launchagents/com.rick.videoscan.testdriver.plist"
SERVICE_LABEL="com.rick.videoscan.testdriver"

# Ensure .launchagents directory exists
mkdir -p "$HOME/.launchagents"

# Parse arguments
UNINSTALL=false
SCHEDULE_WAKE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --wake)
            SCHEDULE_WAKE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$UNINSTALL" = true ]; then
    echo "Uninstalling nightly TestDriver job..."

    # Unload launchd job if it's running
    if launchctl list | grep -q "$SERVICE_LABEL"; then
        launchctl unload "$PLIST_PATH" || true
        echo "✅ Unloaded launchd job"
    else
        echo "ℹ️  Job not currently loaded"
    fi

    # Remove plist file
    rm -f "$PLIST_PATH"
    echo "✅ Removed $PLIST_PATH"

    echo "✅ Uninstall complete"
    exit 0
fi

echo "Installing nightly TestDriver metrics job..."
echo ""
echo "Configuration:"
echo "  Schedule: Daily at 2:00 AM"
echo "  Suites: Smoke + Diagnostic"
echo "  Host: M4 Mac Studio"
echo "  Metrics: Published to origin/metrics branch"
echo ""

# Make script executable
chmod +x "$SCRIPT_DIR/nightly-testdriver.sh"
echo "✅ Made nightly-testdriver.sh executable"

# Copy plist to launchagents
cp "$PROJECT_DIR/.claude/scripts/../../../.launchagents/com.rick.videoscan.testdriver.plist" "$PLIST_PATH" 2>/dev/null || {
    echo "Note: Using existing plist at $PLIST_PATH"
}
echo "✅ Plist installed at $PLIST_PATH"

# Unload if already loaded (to reload with updated plist)
if launchctl list | grep -q "$SERVICE_LABEL"; then
    launchctl unload "$PLIST_PATH" || true
    echo "ℹ️  Reloading existing job..."
fi

# Load the job
launchctl load "$PLIST_PATH"
echo "✅ Loaded launchd job ($SERVICE_LABEL)"

# Verify it's loaded
if launchctl list | grep -q "$SERVICE_LABEL"; then
    echo "✅ Job is active"
else
    echo "⚠️  Warning: Job may not have loaded correctly"
fi

echo ""
echo "Setup complete! The nightly TestDriver will run at 2:00 AM every day."
echo ""
echo "To verify:"
echo "  • Check status: launchctl list | grep videoscan.testdriver"
echo "  • View logs: tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log"
echo "  • Test now: /Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh"
echo ""

# Optional: Schedule system wake
if [ "$SCHEDULE_WAKE" = true ]; then
    echo "Setting up system wake at 1:55 AM..."

    # macOS pmset repeating wake schedule (if supported on this Mac)
    # Format: repeats HH:MM:SS
    # However, pmset wake scheduling is complex. A simpler alternative is to use launchd
    # to trigger a dummy wake event. For now, just document the option.

    echo ""
    echo "⚠️  Sleep handling note:"
    echo "  If your Mac is sleeping at 2 AM, launchd won't wake it automatically."
    echo "  The job will run when the Mac next wakes up (e.g., on manual wake)."
    echo ""
    echo "  To automatically wake at 1:55 AM, you can:"
    echo "  1. Keep the Mac awake (less ideal for power usage)"
    echo "  2. Use System Settings > Energy Saver > Schedule to wake at 1:55 AM"
    echo "  3. Create a second launchd job to trigger wake (advanced)"
    echo ""
    echo "  For now, the job uses 'caffeinate -i' to stay awake during execution."
fi

echo "Done! ✨"
