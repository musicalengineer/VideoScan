<!-- moved from Claude memory (reference_mbp_test_runner) on 2026-10-23; operational reference, rewrite in place -->

Merged from: feedback_mbp_fast_user_switching.md (2026-10-05)
Remote test machine: M1 Max MacBook Pro
- Hostname: ricksm1.local (verified 2026-06-01; previous `ricksmacbookpro.local` no longer resolves on the network)
- User: rickb
- Repo path on MBP: `~/dev/VideoScan` (matches Mac Studio; verified 2026-06-01 — older `~/developer/VideoScan` path is gone)
- SSH: `ssh rickb@ricksm1.local`
- Use for: xcodebuild test runs to avoid stealing focus on Mac Studio

## Workflow — sync code via git, never rsync

Rick's hard rule: **use git push/pull via origin, do not rsync working trees.**
Confirmed 2026-05-02 after I tried rsync — got bounced.

Standard sequence to run tests on a feature branch:
1. Local: commit on the feature branch (ask first per CLAUDE.md unless explicitly authorized).
2. Local: `git push -u origin <branch>`.
3. MBP: `ssh rickb@ricksm1.local 'cd ~/dev/VideoScan && git fetch origin <branch> && git checkout <branch>'`.
4. MBP: `xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination "platform=macOS" -only-testing:VideoScanTests` (skip UI tests per test-etiquette memory).

**Why git over rsync:** clear history of what was tested, no working-tree drift between machines, and the MBP can be left dirty-free at HEAD of whatever branch was last checked out.

**Why:** dual-monitor focus stealing on Mac Studio when xcodebuild runs UI tests; MBP isolates that.
**How to apply:** any time tests should run remotely, commit + push + ssh-fetch — never rsync the working tree.

## When NOT to use the MBP for tests

Rick uses the MBP for non-VideoScan work too. Established 2026-05-04:
- **2:30–4 PM daily**: MBP is reserved for Rick's own use (lunch + afternoon).
  Do NOT run xcodebuild tests on the MBP during this window.
- **Outside that window**: still ASK before running tests on the MBP unless
  Rick has just said it's free for a specific time. Don't assume availability.
- The Mac Studio is always fine for tests (focus-steal cost accepted when
  Rick isn't actively working on it).

Future: Rick is getting a new M5 in May 2026; once that's set up the M1 MBP
will be less central as a test runner. This rule applies until then; revisit
when the M5 lands.

**2026-08-29 gotcha:** app-hosted `xcodebuild test` over ssh on ricksm1 FAILS when the console user is `donna` (fast user switching): rickb has no GUI launchd domain → testmanagerd "Failed to establish communication with the test runner". Symptom earlier: "Executed 0 tests" tails. Use `ricksm5.local` (rickb has a GUI session) or wait for rickb to be the console user on the M1. Headless Core `swift test` is unaffected.

---
## From feedback_mbp_fast_user_switching.md

Symptom: `ssh rickb@ricksmacbookpro.local 'xcodebuild test ...'` exits 134 with
`DVTAssertions: ASSERTION FAILURE in IDELaunchServicesLauncher.m:418 — Assertion
failed: childPID > 0`. Build phase succeeds, "Testing started" prints, then the
test runner spawn aborts.

Root cause: Xcode 26.x's IDELaunchServicesLauncher needs the user's *Aqua* launchd
domain to spawn the app-hosted test runner. SSH sessions land in a different
launchd domain. Even with rickb on the foreground console, direct invocation
fails. `caffeinate -is`, `ssh -t`, and clean DerivedData do not help.

**Fix (verified working, recipe from claude-4-6 on 2026-05-02):** wrap the
xcodebuild call in `launchctl submit`, which schedules it via launchd and runs
it in the right context.

```bash
# From Mac Studio over SSH — kick off (returns immediately):
ssh rickb@ricksmacbookpro.local 'launchctl submit -l com.videoscan.test -- bash -c "cd ~/developer/VideoScan && xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination \"platform=macOS\" -only-testing:VideoScanTests > /tmp/unit_test_output.txt 2>&1"'

# Poll for completion (blocks until done):
ssh rickb@ricksmacbookpro.local 'while ! grep -q "TEST SUCCEEDED\|TEST FAILED" /tmp/unit_test_output.txt 2>/dev/null; do sleep 10; done; grep -c "passed" /tmp/unit_test_output.txt; grep "TEST SUCCEEDED\|TEST FAILED" /tmp/unit_test_output.txt; launchctl remove com.videoscan.test 2>/dev/null'
```

For full suite including UI tests, drop `-only-testing:VideoScanTests`.

**Why:** Verified empirically 2026-05-02 — five direct-SSH attempts failed identically.
**How to apply:** Always wrap MBP-side xcodebuild test in `launchctl submit -l <label> -- bash -c "..."`,
then poll a log file for the SUCCEEDED/FAILED line. Direct `ssh ... xcodebuild test` is broken.
Skip the MBP entirely if Rick is using it (background videos, etc.) — run on Mac Studio.
