<!-- moved from Claude memory (reference_gauntlet_tcc_and_exit_masking) on 2026-10-23; operational reference, rewrite in place -->

Merged from: project_gauntlet_testing_vision.md, reference_release_unit_tests_need_testability.md (2026-10-05)

Two operational gotchas confirmed 2026-07-20 while trying to pre-validate main with the gauntlet:

0. **Gauntlet can't run UNATTENDED OVERNIGHT — needs an unlocked, awake desktop (confirmed 2026-07-20 ~23:xx).** Even WITH Rick's Terminal TCC grant that made it work in the afternoon, overnight runs exit 3 ("Timed out while enabling automation mode") consistently (not flaky — two attempts, single-flow probe too). Root cause: XCUITest/`testmanagerd` needs an active, UNLOCKED GUI session; when the M4 screen is locked/asleep overnight it can't enable automation mode. Claude can't unlock the screen. So UI automation is a "Rick-present / screen-unlocked" activity, NOT an overnight-unattended one — schedule gauntlet runs during Rick's active windows (afternoon/evening), or Rick must leave the session unlocked + `caffeinate -d`. Non-UI work (unit tests, builds, the 2AM nightly `xcodebuild test`) runs fine overnight regardless.

1. **Gauntlet (XCUITest) won't run from the Claude Code terminal on the M4.**
   `scripts/run_gauntlet.sh` exits **3** with "✗ AUTOMATION PERMISSION NEEDED — Grant Accessibility/Automation to this terminal in System Settings › Privacy & Security." The terminal/session Claude runs in lacks the Automation/Accessibility TCC grant, so `testmanagerd` can't enable automation mode (same root cause as the `VideoScanUITests-Runner` "Timed out while enabling automation mode" seen in unit runs). Needs Rick to grant it interactively, OR run on a machine/terminal that already has it. Policy is **M1-first** anyway (M4 testmanagerd bootstrap is flaky); the gauntlet UI-test track is codex-owned — delegate M1 runs to codex. See [[project_gauntlet_testing_vision]].

2. **`| tail` (or any pipe) masks the real exit code.** `run_gauntlet.sh ... 2>&1 | tail -40; echo $?` reports **tail's** exit (0), not the script's (3). The testing agent hit the identical trap with a piped `xcodebuild`. When a piped command's exit code matters, use `set -o pipefail`, capture `${PIPESTATUS[0]}`, or read the tool's own printed status line — never trust `$?` after a pipe.


**2026-09-27 — the password wall is gone on the M4:** Rick ran `sudo automationmodetool enable-automationmode-without-authentication` ("succeeded"). `automationmodetool` now reports automation mode does not require authentication. Remaining constraint: an UNLOCKED, awake GUI session (the Gauntlet runs only when Rick says he's away; `caffeinate -dimsu` for the run). Codex was asked for a Gauntlet design the same day (docs/guides/gauntlet.md + codex proposal).

---
## From project_gauntlet_testing_vision.md

Stated 2026-07-13. Rick's testing north star: "hey my AI friends, run my app through the gauntlet" — automated test categories that mimic his spot-testing (real mouse-click-level operations, full Release build, real data, weird/typical-human usage patterns), so that all-categories-green = ready for his human spot test, and his pass = ship. Rationale: unit tests exercise modules, not interactions; his manual spot-testing keeps finding boundary bugs but is very time-consuming and generates artificial video files.

Categories he named: (1) regression/integration tests mimicking mouse clicks (UI tests re-enabled locally), (2) stress tests, (3) accuracy benchmarks — "find Donna in these videos" against clearcut known ground truth, measuring recognition accuracy (ties to feature/person-recognition-evaluator branch + the codex evaluator NSApplication bug), (4) a mini report published into the metrics dashboard.

**Division of labor:** codex owns the UI-testing track (challenges hit re-enabling UI tests; wrote it up in docs — see `codex-ui-testing-handoff.md` (retired 2026-09-16; in git history) in repo). Rick told codex NOT to bump into Claude; codex uses worktrees; Claude+Rick sometimes work directly on main. Standing guardrail applies: check git state before edits, ask about foreign changes.

Connects to: GH #105–#108 integration-test ladder, testing retrospective 2026-07-05 (boundary bugs), TestDriver harness (natural gauntlet home — already Release + metrics publishing), [[complexity-humility]]. Claude's suggested alternative if XCUITest keeps fighting: app-internal scriptable "driver mode" channel invoking the same actions as buttons — most integration coverage, far less flake.


**2026-09-27 revival:** automation-mode password removed on the M4 (Rick ran automationmodetool + DevToolsSecurity). Codex designed it (docs/design/gauntlet-design-codex-2026-09-27.md) and is building PHASE 1 on feature/release-gauntlet: one scripts/run_gauntlet.sh --away, one Release build, timed stages unit→regression→integration→performance→hallie→stress→(ui = phase 2), manifest that fails on unassigned/zero-count tests, result.json + history.jsonl + dashboard trend. Claude's 3 changes: Person Finder flow → Archive Lock/Unlock/Remove; simple confinement (sparse disk image + path allowlist); honest "UI not run". **Rick: first run = a ~15-min SUBSET he watches (proves it + settles permissions), then the dinner-length full run. Long term the thorough Gauntlet lives on the M5 Ultra (96 GB) so it doesn't hog the M4.**

---
## From reference_release_unit_tests_need_testability.md

`xcodebuild test -configuration Release … -only-testing:VideoScanTests` fails at compile time: the VideoScanCore package is built without `-enable-testing` in Release, so the test target cannot import it. Add `ENABLE_TESTABILITY=YES` to the command line — optimizer stays on (-O, whole-module). With it, 2026-09-25 main 44708097: 9,009 tests in 945 s on the M5, only the pre-existing RecoveryOutcomeContractTests failure.

**Why:** the build-mode policy says Release for production-parity test runs, but CI and nightly use Debug, so the gap was never hit.
**How to apply:** any Release unit-test run (gauntlet, perf baselines) passes ENABLE_TESTABILITY=YES. UI gauntlet still needs an UNLOCKED desktop ([[reference_gauntlet_tcc_and_exit_masking]]). M1 timing budgets fail under load (Spotlight/Screen Sharing); judge budgets on the M5.
