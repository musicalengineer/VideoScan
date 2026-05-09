# Codex Focus for VideoScan

This repo should be worked like an engineering project, not a demo. Prefer
measured, repeatable changes with focused verification.

## Priorities

- Automated testing: unit tests, regression tests, smoke tests, and UI tests.
- Bug fixes and code changes that include a way to prove the behavior.
- Regression coverage for bugs that were found in real use.
- Real-world video/audio fixtures, kept local when too large or private for git.
- Performance benchmarks and code metrics that make progress measurable.
- Conservative worktree use so active user/agent work is not overwritten.

## MacBook Pro Test Target

Use the MacBook Pro when asked to run UI tests or "all tests on my MBP".

- Host: `ricksmacbookpro.local`
- Repo: `~/Developer/VideoScan`
- Main branch should be fast-forwarded before testing:

```bash
ssh ricksmacbookpro.local 'cd ~/Developer/VideoScan && git status --short --branch && git pull --ff-only'
```

The alternate `~/dev/VideoScan` path has existed but was not a git checkout.

## Running All Tests on MBP

Direct `xcodebuild test` over SSH can fail before tests run with an Xcode
LaunchServices assertion. For full UI-inclusive runs, launch a `.command` file
into the logged-in GUI session with `open`, then poll the log over SSH.

Known good pattern:

```bash
ssh ricksmacbookpro.local 'cat > /tmp/videoscan_run_full_tests.command <<'\''EOF'\''
#!/bin/zsh
cd "$HOME/Developer/VideoScan" || exit 2
LOG=/tmp/videoscan_full_tests_gui_mbp.log
STATUS=/tmp/videoscan_full_tests_gui_mbp.status
rm -f "$LOG" "$STATUS"
echo "Starting VideoScan full tests on $(hostname) at $(date)" | tee "$LOG"
echo "Commit: $(git rev-parse --short HEAD)" | tee -a "$LOG"
set -o pipefail
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath .derivedData-mbp-gui-full \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-device-destinations 1 \
  2>&1 | tee -a "$LOG"
rc=$?
echo "$rc" > "$STATUS"
echo "VideoScan full tests finished with exit code $rc at $(date)" | tee -a "$LOG"
exit $rc
EOF
chmod +x /tmp/videoscan_run_full_tests.command
open /tmp/videoscan_run_full_tests.command'
```

Poll with:

```bash
ssh ricksmacbookpro.local 'test -f /tmp/videoscan_full_tests_gui_mbp.status && cat /tmp/videoscan_full_tests_gui_mbp.status; tail -120 /tmp/videoscan_full_tests_gui_mbp.log'
```

## Python Tests on MBP

The default Xcode Python may not have `numpy`. Use the existing `mlx-env`
environment for Python tests:

```bash
ssh ricksmacbookpro.local 'cd ~/Developer/VideoScan && ./mlx-env/bin/python -m unittest discover tests'
```

## Useful Artifacts

- Full test log: `/tmp/videoscan_full_tests_gui_mbp.log`
- Exit status: `/tmp/videoscan_full_tests_gui_mbp.status`
- Result bundle path is printed near the end of the log under
  `.derivedData-mbp-gui-full/Logs/Test/*.xcresult`

## Crash And Log Monitoring

When the user reports a crash or asks to monitor app behavior, check VideoScan
crash reports and logs first. Agents cannot see the UI state the user is
driving, so logs are part of the debugging interface.

Crash reports:

```bash
ls -lt ~/Library/Logs/DiagnosticReports/VideoScan*.ips 2>/dev/null | head
sed -n '1,220p' ~/Library/Logs/DiagnosticReports/<latest VideoScan crash>.ips
```

Persistent app logs:

```bash
ls -lt ~/Library/Logs/VideoScan
tail -200 ~/Library/Logs/VideoScan/catalog.log
tail -200 ~/Library/Logs/VideoScan/facedetect_<person>.log
```

Unified logs:

```bash
/usr/bin/log stream --process VideoScan \
  --predicate 'subsystem == "Rick-Breen.VideoScan" OR process == "VideoScan"' \
  --style compact --info --debug

/usr/bin/log show --last 30m \
  --predicate 'subsystem == "Rick-Breen.VideoScan" OR process == "VideoScan"' \
  --style compact --info --debug
```

Crash-handling rule:

- If a new VideoScan crash appears and the cause is small and clear, fix it in
  a narrowly themed commit with a regression or smoke test when practical.
- If the cause is not immediately safe to fix, file a GitHub issue with the
  crash path, exception, likely subsystem, and acceptance criteria, then tell
  the user it is queued.
- During interactive bug hunts, run `log stream` while the user pushes the app
  around, then correlate timestamps with persistent logs and crash reports.

Known crash issue:

- GH #81 tracks `VideoScan-2026-05-08-203107.ips`, an `EXC_BAD_ACCESS` in
  ImageIO/AppleJPEGReadPlugin while SwiftUI/AppKit rendered an `NSImage`.
  Likely area: user-selected/imported photo thumbnails in Family Tree or People
  editing paths. Prefer eager decode/copy into stable bitmap representations
  and graceful handling of corrupt/unsupported images.

## Last Known MBP Result

On 2026-05-08, main at `0578b87` built and ran through the GUI-launched path.
Python tests passed with `mlx-env`. Full Xcode tests failed in
`ScanConfigurationTests` because tests expected startup diagnostic logs but the
current code returned early with offline-volume messages. UI tests ran; one
Light-mode launch screenshot timed out, while the Dark-mode launch pass
succeeded.
