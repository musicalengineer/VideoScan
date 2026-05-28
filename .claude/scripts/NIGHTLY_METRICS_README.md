# Nightly Metrics Job — Quick Start

## What's Running

Your M4 Mac Studio is now scheduled to run tests at **2:00 AM every day** and publish fresh metrics to GitHub.

- **Status**: ✅ Installed and active
- **Command**: `launchctl list | grep videoscan.testdriver` → should show `-  0  com.rick.videoscan.testdriver`
- **Schedule**: Daily, 2:00 AM
- **Behavior**: Runs TestDriver (Smoke + Diagnostic suites), prevents Mac from sleeping during execution, publishes to `origin/metrics` branch

---

## What You'll See in the Morning

After the job runs, metrics appear on the dashboard:
- Test pass/fail counts
- Code coverage %
- Build times
- Concurrency/lint/periphery findings

Metrics are cumulative — each morning adds a new row to `metrics/testdriver.jsonl`.

---

## Important: Sleep Handling

⚠️ **If your M4 is sleeping at 2 AM**, the job won't auto-wake it. It will run the next time you manually wake the Mac.

**To auto-wake at 1:55 AM:**
1. Go to **System Settings > Energy Saver > Schedule**
2. Check "Start up or wake"
3. Set time to **1:55 AM**
4. launchd job then runs at 2:00 AM on a warm Mac

Alternatively, keep the Mac awake all night (less ideal for power).

---

## Test It Now

Run the job manually (takes ~3–5 min depending on test suite):
```bash
/Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh
```

Watch the logs:
```bash
tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log
```

---

## Files

| Path | Purpose |
|------|---------|
| `~/.launchagents/com.rick.videoscan.testdriver.plist` | launchd configuration (2 AM daily) |
| `.claude/scripts/nightly-testdriver.sh` | Main test runner script |
| `.claude/scripts/install-nightly.sh` | Installer/uninstaller |
| `docs/nightly-metrics-setup.md` | Detailed docs |
| `~/Library/Logs/VideoScan/nightly-testdriver.log` | Job output |

---

## Troubleshooting

**Job didn't run?**
- Check: `launchctl list | grep videoscan.testdriver`
- If missing, reinstall: `bash .claude/scripts/install-nightly.sh`
- Check logs: `tail -f ~/Library/Logs/VideoScan/nightly-testdriver.log`

**Script failed?**
- Run manually to see error: `/Users/rickb/dev/VideoScan/.claude/scripts/nightly-testdriver.sh`
- Check TestDriver build: `cd TestDriver && swift build -c release`

**Git push failed?**
- TestDriver needs git credentials to push metrics
- Test: `cd ~/dev/VideoScan && git push origin --dry-run`
- If it fails, add SSH key to keychain: `ssh-add -K ~/.ssh/id_ed25519`

---

## Uninstall

To turn off the nightly job:
```bash
bash /Users/rickb/dev/VideoScan/.claude/scripts/install-nightly.sh --uninstall
```

---

**That's it!** Your metrics will be fresh every morning. 📊
