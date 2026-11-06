# Codex review — Re-review 4: fixes to the 11/05 evening findings (final)

- Range: `b1709f7a3..origin/fix/codex-1105-evening`
- Credits spent: unavailable
- Tokens: 148583
- Finding count: 2
- Verdict: fix
- Run: 2026-11-06T03:55:19Z (cycle #253, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2  
Verdict: fix — no new P0 demonstrated; functional fixes close the reviewed scenarios, but coverage and one behavioral-RED claim remain incomplete.

Reviewed `b1709f7a3..b618d04f1`.

1. **P1 — Severe script regressions still do not execute in the gauntlet.**  
   **Invariant: COVERAGE. Checklist: TESTED.**  
   [manifest.json:37784](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/scripts/gauntlet/manifest.json:37784), plus lines 37792, 37800 and 37812, still block the package-parser, lock, caller-race and guard suites.

   **Reproduction:** inspect the regression stage: all four Python suites remain in `blocked`. Reintroducing those bugs therefore cannot fail their regressions in a normal gauntlet run. Issue #436 documents the gap; it does not satisfy PROCESS §4’s “executing regression selector, never blocked” requirement. The Swift-suite portion of the previous finding **is closed**.

2. **P2 — The caller-race test’s reported RED does not reach the race.**  
   **Invariant: bug fixes seen red. Checklist: TESTED.**  
   [test_m4_run.py:567](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a46965e48a3e5ef6d/tests/test_m4_run.py:567) waits for a rendezvous introduced alongside the fix.

   **Reproduction:** run this test against `8b542eaad`: the predecessor lacks that hook, so it times out before starting caller B. The commit acknowledges “no pause hook.” That demonstrates a missing test seam, not the checkout/runner/agent corruption.

   Keep the rendezvous on the predecessor and observe a protected-state assertion fail, then restore the fix and observe GREEN. This is an evidence gap; the new host-side ordering addresses the race in source.

| Scenario | Closure and RED assessment |
|---|---|
| Missing file, failed launch, changed file, timeout execution count | Closed in source. Regression assertions distinguish the old behavior; Swift reruns unavailable here. |
| Permission denial at either stat | Closed: only ENOENT/ENOTDIR mean Gone; other errors preserve errno and execution evidence. Behavioral REDs recorded in commits. |
| XCTest ghosts, forged summary, `Selected tests` | Closed for the reproduced scenarios. Tests distinguish the old counts; no additional normal-run defect found. |
| Missing/failed gauntlet; earlier pass hiding later failure | Closed. Seven actual guard decision cases passed; predecessor reproduced the latest-row failure. |
| Stale reclaim and watchdog lock handoff | Kernel locking removes reclaim. Independently exercised the actual old/new watchdog `Popen` expressions: old admitted another owner while work lived; new stayed BUSY until worker exit. |
| Caller mutates a live run | Source closure confirmed; behavioral-RED qualification above. |
| Contaminated listing launches tests | Closed: returns RED before launching package tests. |

Scan/tile/dashboard/cache wiring, `ProcessRunner.launched`, `Runner.swift`, guard/rota logic and remaining lock code: **read, no additional findings**. `caffeinate` preserved fd 9 in an independent check; full Swift/Xcode descendant inheritance was not independently verified.

Four shell syntax checks passed. Full fixture suites and Swift execution were prevented by read-only temporary-file/cache restrictions. No repository files changed.

Credits spent: unavailable | Finding count: 2  
Verdict: fix

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

Pass 5: b618d04f1 answers your fourth pass (second-stat errno; the watchdog passes fd 9; m4_run caller steps are additive — per-run bin/label, checkout only under the host lock; the two Swift regression suites now execute in the gauntlet regression stage). This is the FINAL pass before Rick decides: rank strictly and mark true P0s (a false fact or a hidden failure in normal use) vs edge cases.
