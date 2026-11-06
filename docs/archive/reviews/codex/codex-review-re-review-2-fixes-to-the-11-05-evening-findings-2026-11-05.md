# Codex review — Re-review 2: fixes to the 11/05 evening findings

- Range: `b1709f7a3..origin/fix/codex-1105-evening`
- Credits spent: unavailable
- Tokens: 163864
- Finding count: 4
- Verdict: block
- Run: 2026-11-06T02:59:26Z (cycle #248, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: block — the previous reproductions are addressed, but scan truth and testbed isolation still have gaps.

Locations below refer to `79b47ae61`.

1. **P0 — “Gone” also means permission denied.**  
   [VideoScanModel+ProbeEngine.swift:795](/Users/rickb/dev/VideoScan-wt/rt-tile/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:795). **Invariant: TRUTH. Checklist: TRUE, TESTED.**  
   `fileExists == false` does not prove disappearance. If a discovered file’s parent becomes inaccessible, the engine sets `fileNotFound`, and the tally shows **Gone, zero errors** although the file remains present. I confirmed the underlying macOS behavior: Foundation returned false while `stat` reported `EACCES` for an existing directory.  
   **Regression needed:** discover a settled file, remove parent-directory search permission, then probe it. Assert inaccessible/error rather than Gone. Distinguish absence from permission and I/O errors.

2. **P1 — The lock ends before surviving test work ends.**  
   [testbed_lock.py:94](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/testbed_lock.py:94), [m4_run.sh:288](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/m4_run.sh:288). **Invariant: isolation/COVERAGE. Checklist: CLEAN, TESTED.**  
   The helper releases its lock when its parent shell dies. The gauntlet runs in a separate session and can survive that shell. A second run then acquires the lock while the first still operates.  
   **Reproduced:** target `hold()` code plus real kernel `flock`, with filesystem writes replaced by in-memory doubles: **B acquired; A’s isolated worker remained alive**. The killed-holder tests release A’s fake workload before starting B, concealing this overlap. Start B while A’s workload remains held and assert exclusion until that workload is stopped and reaped.

3. **P1 — The outer timeout discards actual launch evidence.**  
   [VideoScanModel+ProbeEngine.swift:698](/Users/rickb/dev/VideoScan-wt/rt-tile/VideoScan/VideoScan/Media/VideoScanModel+ProbeEngine.swift:698). **Invariant: TRUTH/count accuracy. Checklist: TRUE, TESTED.**  
   With `useTimeout: true`, launch an ffprobe that exceeds `probeTimeoutSeconds`. The timer wins; task-group cleanup waits for the probe, but the catch constructs a fresh outcome with `ffprobeRan == false`. The dashboard therefore counts zero executions despite the launched subprocess.  
   **Regression needed:** extend the stuck-tool fixture through `probeAndRecord(useTimeout: true)` and assert one execution after timeout. The new launch-failure test explicitly uses `useTimeout: false`; existing timeout tests never check this counter. This finding is source-confirmed, not Swift-runtime reproduced here.

4. **P2 — A contaminated listing still launches package tests.**  
   [Runner.swift:524](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/gauntlet/Runner.swift:524). **Invariant: isolation/COVERAGE. Checklist: CLEAN, TESTED.**  
   When `swift test list` returns `contaminated`, the runner records that flag but immediately invokes `swift test` in the same environment. It bypasses the contamination guard used between stages. The final result remains RED, but additional tests execute after isolation has failed.  
   **Regression needed:** extend the adapter fake so the listing leaves a descendant, then assert no test invocation follows. Return from the package stage before launching further work.

The previous scenarios are addressed as follows:

| Fix | Closure and red evidence |
|---|---|
| Missing files, post-probe changes, failed launches | Corrected on the direct probe path. Counter and engine regression assertions distinguish the old behavior. Swift execution was unavailable here. |
| Bare XCTest ghosts, forged closing summary, `Selected tests` | Closed in the reviewed state machine. A source-regex transcription reproduced old → new: forged count **2 → unavailable**; filtered count **0 → 1**. This was not compiled Swift. |
| Missing/failed gauntlet and earlier-pass/later-failure retry | Closed. Executed the actual decision blocks: old revisions suppress retry; target leaves only `suite` done. Seven target decision cases passed. |
| Acquisition and stale-reclaim races | Closed by kernel exclusion; staging publication/reclamation is gone. Baseline race tests require backporting the pause hook to demonstrate the behavioral RED—an absent-hook timeout alone proves nothing. Worker-lifetime coverage remains inadequate as above. |

`XCTestConsoleTally`, guard selection, rota mapping, `ScanWriteInProgress` flag forwarding, `ProcessRunner.launched`, cache transience, and remaining dashboard/tile wiring: **read, no findings beyond those listed**.

Validation: three shell syntax checks passed. Four fixture-based regression attempts stopped at setup because temporary-directory creation was denied; Swift execution was also denied. No repository changes.

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
