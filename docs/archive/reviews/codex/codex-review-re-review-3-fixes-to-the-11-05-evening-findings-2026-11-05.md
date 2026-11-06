# Codex review — Re-review 3: fixes to the 11/05 evening findings

- Range: `b1709f7a3..origin/fix/codex-1105-evening`
- Credits spent: unavailable
- Tokens: 157023
- Finding count: 4
- Verdict: block
- Run: 2026-11-06T03:26:23Z (cycle #251, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: block — the previous examples are addressed, but scan truth, testbed exclusion, and regression coverage remain incomplete.

Reviewed `b1709f7a3..8b542eaad`. Locations below refer to `8b542eaad`.

1. **P0 — Post-probe permission errors still become “Still writing, zero errors.”**  
   **Invariant: TRUTH. Checklist: TRUE, TESTED.**  
   [ScanWriteInProgress.swift:52](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/VideoScan/VideoScan/Volumes/ScanWriteInProgress.swift:52) discards every attributes error into `nil`; line 104 interprets that as “gone after the probe.” [ProbeEngine:915](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:915) then returns `stillBeingWritten`, which suppresses the error count. The new errno mapping protects only the initial stat.

   **Reproduction:** probe a settled file; in `scanSecondStatForTesting`, remove its parent’s search permission and return `ScanFileStat.of(path:)`. The existing file becomes “Still writing,” with a disappearance reason and zero errors.  
   **RED needed:** assert an inaccessible/error outcome and preserved launch evidence. Source-confirmed; Swift execution was unavailable.

2. **P1 — The nightly watchdog drops fd 9 before launching the actual work.**  
   **Invariant: ownership lasts through surviving work. Checklist: CLEAN, TESTED.**  
   [nightly_gauntlet.sh:98](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/nightly_gauntlet.sh:98) calls the real nightly suite, whose [process_group_watchdog.sh:148](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/lib/process_group_watchdog.sh:148) uses `Popen` without `pass_fds`. Its isolated worker therefore cannot retain the lock after its supervisors disappear or abandon it.

   **Reproduced:** executed the actual `Popen` expression with a real kernel lock. After closing supervisor descriptors: **second owner admitted while worker alive**. The `m4_run.run_bounded` expression correctly remained **BUSY** under the same test.  
   **RED needed:** exercise this real watchdog handoff, not just the fake gauntlet shell. I followed `nightly_local_tests.sh` into its watchdog specifically to verify inheritance.

3. **P1 — Remote startup mutates the shared testbed before acquiring ownership.**  
   **Invariant: a live run’s tested tree remains stable. Checklist: TRUE, CLEAN, TESTED.**  
   [m4_run.sh:195](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/m4_run.sh:195) probes and releases the lock. It subsequently checks out the requested SHA at line 222 and bootouts the existing LaunchAgent at line 249. Actual acquisition occurs only in `host_main`, line 433.

   **Reproduction:** pause caller A after its FREE probe; let B acquire and start testing; resume A requesting another SHA. A can replace B’s worktree and stop its agent before A’s eventual lock refusal. Kernel exclusion inside `host_main` cannot protect those earlier operations.  
   **RED needed:** this interleaving must leave B’s HEAD, installed runner, and LaunchAgent untouched. Source-confirmed; no real checkout was modified.

4. **P1 — The severe-fix regressions remain excluded from the gauntlet.**  
   **Invariant: COVERAGE. Checklist: TESTED.**  
   The manifest still marks [ScanStillBeingWrittenTests:36228](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/gauntlet/manifest.json:36228), [ProbeTimeoutRegressionTests:37679](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/gauntlet/manifest.json:37679), and the four relevant Python suites beginning at [37791](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/gauntlet/manifest.json:37791) as `blocked`.

   **Reproduction:** inspect each suite’s stage membership: all six are blocked. The new permission, timeout-evidence, lock-lifetime, and parser regressions therefore do not execute in the gauntlet. This conflicts with PROCESS §4’s requirement that severe fixes receive an executing regression selector, never `blocked`. Direct development runs do not satisfy that requirement.

Previous-scenario closure:

| Scenario | Closure and RED assessment |
|---|---|
| Missing file, failed launch, post-probe change | Execution evidence is correctly wired. Missing-file and failed-launch tests distinguish the broken behavior; the post-probe engine test is explicitly a coverage pin. |
| Initial permission denial; outer timeout loses launch evidence | Exact examples closed. New assertions distinguish the old outcomes; commit records behavioral REDs. Finding 1 remains. |
| XCTest ghosts, forged summary, `Selected tests` | Reviewed state machine closes these examples; regression assertions distinguish old counts. No new finding. |
| Missing/failed gauntlet; earlier pass hides later failure | Closed. Seven actual guard decision cases passed, including predecessor comparisons. |
| Acquisition/stale-reclaim races; killed shell | Kernel acquisition closes the races. Actual helper retained BUSY after helper exit and became FREE after the last descriptor closed. End-to-end gaps remain in findings 2–3. |
| Contaminated listing launches tests | Closed: returns RED before test execution. Regression checks that no invocation follows. |

`Runner.swift`, guard/rota logic, `ProcessRunner.launched`, `ProbeOutcome`, cache transience, and remaining dashboard/tile wiring: **read, no additional findings**.

Validation limits: three shell syntax checks passed. Fixture suites were attempted, but temporary-file restrictions prevented their execution; Swift caches were also denied. Full behavioral red/green reruns were therefore **not independently verified**. No repository changes.

Credits spent: unavailable | Finding count: 4  
Verdict: block

## Brief

# Codex brief: re-review of the fixes to your 11/05 evening findings

Range: b1709f7a3..origin/fix/codex-1105-evening (one commit, 79b47ae61). You blocked b1709f7a3 on four findings, then 39cd17304 on five more (stale-lock reclaim race, forged closing bracket+summary, Selected tests bracket, launch failure counted as ffprobed, earlier passing gauntlet hiding a later failure); the branch now has two commits:
(1) P0 "ffprobed" counted files ffprobe never opened; (2) P1 printed XCTest-shaped text inflated package counts;
(3) P1 a green suite suppressed retries of a failed/missing gauntlet; (4) P1 the shared testbed lock allowed two
live owners. The commit message has the red/green table.

For each: does the fix close the scenario you reproduced, and does its test go red without the fix? Then look for
what the fixes broke: the new "Gone" tile and `ffprobeRan`/`fileNotFound` in `ProbeOutcome`
(`Volumes/ScanTileTally.swift`, `VideoScanModel+ProbeEngine.swift`, `ScanWriteInProgress.swift`); the
`XCTestConsoleTally` state machine in `scripts/gauntlet/Runner.swift` (can a real test be lost, or the counts go
unavailable on a normal run?); the guard's both-rows rule and `--gauntlet-only` (`scripts/nightly_guarded.sh`,
`scripts/nightly_gauntlet.sh`, `scripts/nightly_rota.py machine`); the rename-published lock shared by
`scripts/m4_run.sh` and `scripts/nightly_gauntlet.sh` (stale reclaim, crash between staging and publish, staging
dirs left behind).

Invariants: TRUTH, a RED never hidden, bug fixes seen red, COVERAGE. Output contract: one finding per failing
invariant with file:line, scenario, P0–P3, checklist item. End with `Credits spent: … | Finding count: N` and
`Verdict: merge|fix|block`.

Round 2 changed the design: the testbed lock is now a kernel flock held by scripts/testbed_lock.py (both m4_run.sh and nightly_gauntlet.sh, plus the remote probe); XCTest counts are cross-checked against `swift test list` for the same filter; ProcessRunner reports `launched`. Attack those designs, not only the old scenarios.

Round 3 (8b542eaad) answers your third pass (Gone vs permission denied via stat errno; the lock now lives on fd 9, an open file description the work inherits, so it frees only when the last holder exits; the useTimeout path carries launch evidence; a contaminated swift test list returns RED before launching tests). Verify closure, then attack the fd-9 lock (fd leaks into unrelated long-lived children, close-on-exec paths, the remote probe) and the errno mapping.
