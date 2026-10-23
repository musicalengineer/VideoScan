<!-- moved from Claude memory (reference_test_mac_setup_automation_mode) on 2026-10-23; operational reference, rewrite in place -->

Diagnosed 2026-10-21. The M5 nightly reported "zero-tests-ran: test-rc=65" because the APP's test host (not the UI-test target, which is already skipped) hung for 120 s: "Timed out … initiating control session with daemon"; "The test runner hung before establishing connection".

The cause was setup, not code:
1. `automationmodetool` said "requires user authentication". The M4 has had it password-free since 9/27; the M5 never had. Rick often saw the "allow testbed" dialog, which had already timed out by the time he saw it.
2. Xcode 27.1 was updated without first-launch: `xcodebuild -checkFirstLaunchStatus` gave rc 69, and the log said "CoreSimulator is out of date".

**Fix (Rick ran it at a real terminal, 10/21):**
`sudo automationmodetool enable-automationmode-without-authentication && sudo xcodebuild -runFirstLaunch`
Verify without sudo: `automationmodetool` (expect "DOES NOT REQUIRE"), and `xcodebuild -checkFirstLaunchStatus` (expect rc 0).

3. **Metal Toolchain:** since Xcode 27.1 it's a separate download. Without it, mlx-swift's .metal files fail and every gauntlet stage is BLOCKED (build rc 65). Install it with `xcodebuild -downloadComponent MetalToolchain` (no sudo; a few minutes) and verify with `xcrun -f metal`.

**How to apply:**
- Add both steps to the Ultra setup and to any new test Mac.
- Re-run first-launch after every Xcode update.
- `sudo` cannot prompt for a password through `!` in Claude Code (no TTY); Rick must run it in a real Terminal.

Related: [[reference_gauntlet_tcc_and_exit_masking]], [[project_m5_ultra_migration]].
