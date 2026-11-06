# Codex review — Re-review: fixes to the 11/05 evening findings

- Range: `b1709f7a3..origin/fix/codex-1105-evening`
- Credits spent: unavailable
- Tokens: 150622
- Finding count: 5
- Verdict: block
- Run: 2026-11-06T02:24:52Z (cycle #246, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5  
Verdict: block — the original examples are addressed, but execution truth, package counts, retry visibility, and lock exclusion still have gaps.

All line numbers below refer to `39cd17304`.

| Original finding | Closure and regression evidence |
|---|---|
| Missing files counted as ffprobed | Closed. The changed counter expectations expose the old behavior. The post-probe “Still writing” test supplies `ran: true` directly; it does not verify the engine sets it. |
| Printed XCTest result inflated counts | The original bare-line reproduction is closed. Baseline regex versus target state-machine reproduction confirms the difference; complete forged transcripts remain accepted below. |
| Green suite suppressed gauntlet retry | Closed for missing/failed gauntlets without an earlier passing row. Executed both revisions’ decision blocks: old skips; target requests gauntlet-only. |
| PID-less acquisition permitted two owners | Closed at the original pause point. The regression needs its pause hook backported to exercise the old race; unchanged baseline merely times out waiting for that hook. Stale reclamation remains unsafe below. |

1. **P0 — Failed process launches still count as “ffprobed.”**  
   [VideoScanModel+ProbeEngine.swift:888](/Users/rickb/dev/VideoScan-wt/rt-tile/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:888). **Invariant: TRUTH. Checklist: TRUE, TESTED.**  
   `runFFProbe` returns normally when `ProcessRunner` cannot launch the executable; the caller then unconditionally sets `ffprobeRan = true`. Reproduce with an existing, settled, uncached `.mov` and `model.ffprobePath` pointing to a nonexistent executable. No subprocess starts, but the dashboard increments “ffprobed.”  
   **Missing regression:** drive `probeAndRecord` through that launch failure and assert `ffprobeRan == false` and zero cache misses. Execution evidence must survive from the process runner.

2. **P1 — Stale reclamation can remove a newly published live lock.**  
   [nightly_gauntlet.sh:83](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/nightly_gauntlet.sh:83), [m4_run.sh:341](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/m4_run.sh:341). **Invariant: isolation/COVERAGE. Checklist: CLEAN, TESTED.**  
   A reads the stale PID and confirms it is dead. B reclaims that directory, publishes its own lock, and starts work. A resumes and renames **B’s live lock** aside, then publishes its own. Both owners continue. Renaming is atomic; the preceding ownership check is not tied to the directory renamed.  
   **RED reproduced:** executed the target’s acquisition loop with deterministic in-memory I/O doubles: `A LOCK_HELD=1; B LOCK_HELD=1`. Existing tests pause before publication, not between stale inspection and reclamation.

3. **P1 — A printed closing bracket and summary still inflate package counts.**  
   [Runner.swift:185](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/gauntlet/Runner.swift:185). **Invariant: TRUTH / a RED never hidden. Checklist: TRUE, TESTED.**  
   Inside real `testA`, print its own passing result, a ghost start/pass pair, an `All tests` closing line, and `Executed 2 tests, with 0 failures`. The parser accepts that summary and stops before the runner’s real result and one-test summary. One executed test becomes two; a floor miss can pass with exit zero.  
   **Reproduction:** source-regex/state-machine transcription returned **2 instead of 1**. Extend the ghost regression with this complete transcript; its current fixture never forges the bracket or summary.

4. **P1 — Filtered XCTest runs lose their real tests.**  
   [Runner.swift:173](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/gauntlet/Runner.swift:173), [Runner.swift:201](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/gauntlet/Runner.swift:201). **Invariant: COVERAGE/count accuracy. Checklist: TESTED, TRUE.**  
   Package stages invoke `swift test --filter`, whose XCTest bracket is `Selected tests`. The parser recognizes only `All tests`, then treats the missing recognized bracket as zero XCTest executions. Successful tests disappear, potentially making a healthy stage fail its floor.  
   **Reproduction:** changing only the bracket in the one-test fixture to `Selected tests` yields **0 instead of 1**. The real-toolchain tests are unfiltered; the adapter fake always prints `All tests`.

5. **P1 — An earlier passing gauntlet still suppresses retry after a newer failure.**  
   [nightly_guarded.sh:87](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/nightly_guarded.sh:87). **Invariant: a RED never hidden. Checklist: WORKFLOW, TESTED.**  
   Supply today’s green suite, an earlier passed gauntlet, and a later failed gauntlet for `m4`. The accumulating `done` set retains `gauntlet`, so the guard exits zero without retrying.  
   **RED reproduced:** the actual decision block returned `gauntlet suite`; the expected result is `suite`. Add this ordered-history case to `GuardRetryTests` and evaluate the latest applicable result.

The remaining Gone-tile wiring, `ScanTileTally`, `ScanWriteInProgress`, transient `ProbeOutcome` fields/cache handling, and rota machine mapping are **read, no findings** beyond the producer issue above. A crash before publication leaves a staging directory that later PIDs ignore; crash cleanup is untested.

Validation: **12 Python tests passed**; three shell syntax checks passed. Four integration-test setups were blocked by denied temporary-file creation. Swift suites were not executed; parser reproductions used a transcription, not the compiled Swift implementation. No repository changes.

Credits spent: unavailable | Finding count: 5  
Verdict: block

## Brief

# Codex brief: re-review of the fixes to your 11/05 evening findings

Range: b1709f7a3..origin/fix/codex-1105-evening (one commit, 39cd17304). You blocked b1709f7a3 on four findings:
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
