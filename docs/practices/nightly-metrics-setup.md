# Nightly Metrics Setup

## Overview

The M4 Mac Studio runs a **nightly TestDriver job at 2:00 AM** to generate fresh metrics every morning. This lets you see test coverage, performance baselines, and regressions first thing when you start work.

The job:
1. Builds TestDriver (release mode)
2. Runs Smoke + Diagnostic test suites
3. Publishes metrics to the `metrics` branch on GitHub
4. Updates the dashboard at https://github.com/musicalengineer/VideoScan/wiki/Metrics-Dashboard (or via GitHub Pages)

---

## Installation

### Step 1: Make scripts executable and load launchd job

```bash
bash /Users/rickb/dev/VideoScan/.claude/scripts/install-nightly.sh
```

This:
- Makes `nightly-testdriver.sh` executable
- Installs the launchd plist at `~/.launchagents/com.rick.videoscan.testdriver.plist`
- Loads the job immediately

### Step 2: Verify setup

Check that the job is loaded:
```bash
launchctl list | grep videoscan.testdriver
```

Expected output:
```
- 0  com.rick.videoscan.testdriver
```

(The `-` means it hasn't run yet; `0` means it's scheduled but not currently running.)

---

## Running & Testing

### Test the job manually (right now)
```bash
/Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh
```

This runs the full job outside the scheduled time, useful for debugging.

### View logs
```bash
tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log
```

Or check both stdout and stderr:
```bash
tail -f ~/Library/Logs/VideoScan/nightly-testdriver*.log
```

### Uninstall
```bash
bash /Users/rickb/dev/VideoScan/.claude/scripts/install-nightly.sh --uninstall
```

---

## How It Works

### launchd + caffeinate

The setup uses **launchd** (macOS native scheduler) + **caffeinate** (prevent sleep):

- **launchd** schedules the job to run at 2:00 AM every day
- **caffeinate -i** prevents the Mac from sleeping during the job
- Logs go to `~/Library/Logs/VideoScan/nightly-testdriver.log`

### If your Mac is sleeping at 2 AM

By default, **launchd won't wake a sleeping Mac**. The job will run the next time the Mac wakes (e.g., on manual wake).

**Options:**

1. **Keep the Mac on** — simplest, easiest (system sleep disabled)
2. **System Settings wake schedule** — go to System Settings > Energy Saver > Schedule and set "Start up or wake" at 1:55 AM
3. **Manual wake** — manually wake the Mac around 2 AM (less practical)

Caffeinate ensures the Mac **stays awake during the job**, so once it wakes, the job completes without interrupt.

---

## Metrics Dashboard

After the job runs, metrics appear on:

- **GitHub Pages**: https://github.com/musicalengineer/VideoScan (if docs/index.html is wired)
- **Metrics branch**: `origin/metrics` contains `metrics/testdriver.jsonl` (JSONL rows)

The dashboard renders test results, coverage %, and trends over time.

---

## Troubleshooting

### Job didn't run at 2 AM

**Possible causes:**
1. **Mac was sleeping** → option: enable wake schedule in System Settings
2. **Job didn't load** → verify with `launchctl list | grep videoscan`
3. **Script failed** → check logs: `tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log`
4. **Git credentials** → TestDriver needs git credentials to push to metrics branch
   - Ensure `git` can push (test: `cd ~/dev/VideoScan && git push origin --dry-run`)

### Test build failed

Check the log:
```bash
tail -100 ~/Library/Logs/VideoScan/nightly-testdriver.log
```

Common issues:
- **Xcode not installed or wrong version** → check `xcode-select -p`
- **Swift toolchain mismatch** → `swift --version` should be 5.9+
- **Missing dependencies** → ensure Homebrew ffmpeg is installed

### Metrics not published to GitHub

**Verify git push works:**
```bash
cd ~/dev/VideoScan
git fetch origin
git push origin main --dry-run  # don't actually push
```

If credentials fail, launchd job may not have SSH agent available. Solutions:
1. Use `git credential helper` to cache credentials
2. Set up SSH key with `ssh-add -K` (adds to keychain)

---

## macOS Best Practices (for reference)

This setup follows macOS scheduling best practices:

1. **launchd instead of cron** — native macOS scheduler, more reliable
2. **StartCalendarInterval** — specifies exact time (2:00 AM daily)
3. **caffeinate -i** — prevents sleep during execution
4. **Logs to standard paths** — `~/Library/Logs/` is the macOS convention
5. **User-level agent** — `~/.launchagents/` not `/Library/LaunchDaemons/` (which requires root)

---

## Files

| File | Purpose |
|------|---------|
| `.claude/scripts/nightly-testdriver.sh` | Main job script (runs TestDriver) |
| `.claude/scripts/install-nightly.sh` | Installer / uninstaller |
| `~/.launchagents/com.rick.videoscan.testdriver.plist` | launchd configuration |
| `~/Library/Logs/VideoScan/nightly-testdriver.log` | Job output log |

---

## Next Steps

1. Run installer: `bash /Users/rickb/dev/VideoScan/.claude/scripts/install-nightly.sh`
2. Verify: `launchctl list | grep videoscan.testdriver`
3. Test manually: `/Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh`
4. Check logs: `tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log`
5. Optional: Enable wake schedule in System Settings if you want automatic wake at 1:55 AM

Metrics will appear on the dashboard every morning after the job runs.
