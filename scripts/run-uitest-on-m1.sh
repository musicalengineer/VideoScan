#!/bin/bash
# run-uitest-on-m1.sh
#
# Runs the PauseRestartUITests canary on M1 via SSH + launchd. Captures
# every gotcha discovered during the initial bring-up (see
# docs/xcuitest-pause-resume-plan.md and the "VideoScanUITests-Runner
# crash" PR section for the why).
#
# Usage (from M4 or anywhere with SSH access to ricksm1.local):
#   bash scripts/run-uitest-on-m1.sh
#
# Tails /tmp/m1-uitest.log so you can watch progress. Returns the
# launchd job's exit code.
#
# Prerequisites:
#   1. ricksm1.local reachable via SSH from this machine (no password
#      prompt — public-key auth set up).
#   2. ~/dev/VideoScan exists on M1 and is checked out to a branch
#      with PauseRestartUITests + UITestStorageOverride in place.
#   3. ONE-TIME: Rick has granted Accessibility permission to the
#      VideoScanUITests-Runner.app bundle in System Settings →
#      Privacy & Security → Accessibility on M1. macOS 26.5's
#      TCC for the xctrunner bundle ID is the gating factor —
#      without this grant, the runner times out 60s into automation
#      bootstrap with "Timed out while enabling automation mode."
#
# Sequence:
#   1. SSH-write the wrapper script and LaunchAgent plist.
#   2. launchctl bootstrap the agent (RunAtLoad=true, KeepAlive=false).
#   3. Tail the test log until the wrapper exits.
#   4. Print the exit code and last 30 lines.

set -uo pipefail

HOST=ricksm1.local
LABEL=com.rickb.videoscan-uitest

# Heredoc'd wrapper. Lives at /tmp/m1-uitest-wrapper.sh on the M1.
read -r -d '' WRAPPER <<'EOS' || true
#!/bin/bash
set -uo pipefail
exec >>/tmp/m1-uitest.log 2>&1
echo "===== $(date '+%Y-%m-%d %H:%M:%S') wrapper start ====="
cd /Users/rickb/dev/VideoScan
echo "branch: $(git rev-parse --abbrev-ref HEAD)"
echo "HEAD:   $(git rev-parse --short HEAD)"

# DerivedData under ~/Library/Developer/Xcode/DerivedData/ — NOT /tmp.
# macOS 26.5 AppleSystemPolicy denies launching unsigned binaries from
# /tmp regardless of RegisterExecutionPolicyException. The standard
# DerivedData location works.
DERIVED=$HOME/Library/Developer/Xcode/DerivedData/m1-uitest-dd
rm -rf "$DERIVED"
mkdir -p "$DERIVED"

# CRITICAL: do NOT use CODE_SIGNING_ALLOWED=NO. The resulting unsigned
# runner cannot launch on macOS 26.5 via xctest's automation channel.
# Use ad-hoc signing instead — CODE_SIGN_IDENTITY=- produces a runner
# whose CDHash satisfies the loader.
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -only-testing:VideoScanUITests/PauseRestartUITests \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS=
rc=$?
echo "===== $(date '+%Y-%m-%d %H:%M:%S') wrapper end rc=$rc ====="
exit $rc
EOS

# LaunchAgent plist. RunAtLoad=true triggers the job on bootstrap;
# KeepAlive=false (NOT a respawn loop — we did that the wrong way on
# 2026-06-02 with launchctl submit, see feedback_mbp_fast_user_switching).
read -r -d '' PLIST <<EOF || true
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/tmp/m1-uitest-wrapper.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>/tmp/m1-uitest-launchd.out.log</string>
    <key>StandardErrorPath</key><string>/tmp/m1-uitest-launchd.err.log</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

echo "[run-uitest-on-m1] Pushing wrapper to $HOST..."
echo "$WRAPPER" | ssh "$HOST" 'cat > /tmp/m1-uitest-wrapper.sh && chmod +x /tmp/m1-uitest-wrapper.sh'

echo "[run-uitest-on-m1] Pushing LaunchAgent plist..."
echo "$PLIST" | ssh "$HOST" "mkdir -p ~/Library/LaunchAgents && cat > ~/Library/LaunchAgents/$LABEL.plist"

echo "[run-uitest-on-m1] Bootstrapping launchd job..."
ssh "$HOST" "launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist 2>/dev/null; rm -f /tmp/m1-uitest.log; launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist && echo bootstrap-ok"

echo "[run-uitest-on-m1] Waiting for job exit (this can take 5-10 min on a clean build)..."
while ssh "$HOST" "launchctl print gui/\$(id -u)/$LABEL 2>/dev/null | grep -q 'state = running'"; do
    sleep 30
    line_count=$(ssh "$HOST" "wc -l /tmp/m1-uitest.log 2>/dev/null | awk '{print \$1}'")
    echo "  ... still running ($line_count log lines)"
done

EXIT_CODE=$(ssh "$HOST" "launchctl print gui/\$(id -u)/$LABEL 2>/dev/null | grep -E 'last exit code' | awk '{print \$NF}'")
echo ""
echo "[run-uitest-on-m1] Job exited with code: $EXIT_CODE"
echo ""
echo "[run-uitest-on-m1] Last 30 lines:"
ssh "$HOST" 'tail -30 /tmp/m1-uitest.log'

# Map xcodebuild rc to script rc: 0 = pass, 65 = test failure / runner crash.
case "$EXIT_CODE" in
    0)  exit 0 ;;
    65) exit 65 ;;
    *)  exit 1 ;;
esac
