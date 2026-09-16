# Tech-debt review — September 15, 2026

Reviewed main `e3a093eb` after Rick's M4 migration to Xcode 27. This is a
headless source, metrics, and existing-test-evidence review by Codex Manager,
metrics, QA, and testing agents. No app launch, build, fresh app test run,
live-media change, or remote mutation was performed.

## Recommended order

1. **Establish a usable test baseline.** Diagnose the current failures and
   incomplete hosted run before using that lane to approve refactors.
2. **Bound Drive Health's three subprocesses.** Small first production patch:
   opt into existing ProcessRunner deadlines and preserve current fallback
   behavior. Follow separately with the inspector's ffprobe call.
3. **Fix web-proxy admission accounting.** Queued requests count against active
   capacity and can prevent all queued work from starting, even with healthy
   ffmpeg. Keep this independent of runner replacement.
4. **Consolidate remaining subprocess lifecycle handling.** Rescue, Hallie
   encoding, and RAM-disk cleanup each need a separate patch and review.
5. **Resume responsibility-focused refactors.** People storage and Hallie turn
   orchestration remain high-churn boundaries; retain the September 13 assessment
   as a backlog, updated for work already merged.

The first implementation slice should be Drive Health while testing triages the
baseline independently. No new dependencies, storage schema, threading model,
or logging format are needed for that slice. Manager protocol requires this
prioritized review before production edits; this pass makes no production edits.

## Confirmed source findings

These are control-flow findings, not freshly reproduced runtime hangs.

| Priority | Location | Trigger and consequence | Bounded remedy |
|---|---|---|---|
| Major | `DriveHealth.swift:294,421,471`; `ScanEngine.swift:22` | diskutil, smartctl, system_profiler, and inspector ffprobe omit `deadlineSeconds`. A nonreturning child leaves its caller waiting. | Explicit tool-appropriate budgets using the existing runner; report timeout through current warning/diagnosis fields. |
| Major | `HallieWebProxy.swift:117,151` | `inFlight` includes queued requests, but its count controls admission. With two runners plus three queued requests, both runners can finish and leave three waiters that all re-suspend; no active runner remains to wake them. | Track active work separately, as the poster cache already does; preserve per-volume limits and duplicate-request coalescing. |
| Major | `VolumeCompare.swift:428–498` | Raw mkdir/rsync processes wait without deadlines; rsync stderr is drained only after exit. Cancel between process registration and launch can miss the child. | Use existing ProcessRunner cancellation latch, concurrent draining, and escalation while preserving partial-file publication and verification. |
| Major | `HallieWebProxy.swift:172–190`; `HallieWebPoster.swift:97–108` | Completion depends on child exit, with no deadline/cancellation bridge; proxy stderr is drained only after termination. A stuck child retains capacity. | Keep injected runner interfaces and adapt production runners to bounded ProcessRunner calls. |
| Major | `RAMDisk.swift:50,69,110,151`; `VideoScanApp.swift:139,270` | Synchronous hdiutil waits can block startup or termination. | Separate lifecycle patch using existing runner and terminate-later handling; preserve current logging. |

Scope corrections to the earlier overnight report: RAMDisk now has begin/end
logging. ProcessRunner lives in the core package and already escalates task
cancellation through kill and abandonment. Its default deadline is still nil.
The ScanEngine finding concerns `PersonFinderInspectorTypes.swift:37`, not proof
that ordinary catalog scanning lacks deadlines. More logging alone would not
resolve these control-flow problems.

## Test baseline: evidence, not a green-light claim

- M4 currently selects **Xcode 27.0 (27A266a), Apple Swift 6.4**.
- [Hosted CI at da179d63](https://github.com/musicalengineer/VideoScan/actions/runs/34991676106)
  used **Xcode 26.3 / Swift 6.2.4**. App and tests built successfully. The test
  step reported failures and timed out after 20 minutes; the result bundle was
  incomplete. The old issue title about a compiler failure is not the current
  failure diagnosis.
- Failures in that hosted log include several 100k-record time budgets, the
  dry-run/apply/undo scale test, and VHS media-matrix/original-preservation tests.
  These require triage; the log does not justify calling all of them either
  product defects or runner slowness. CI currently uses Debug, so performance
  budgets need interpretation against the project's Release measurement policy.
- Current-head [Python CI](https://github.com/musicalengineer/VideoScan/actions/runs/35027552816)
  passed. [App CI at e3a093eb](https://github.com/musicalengineer/VideoScan/actions/runs/35027552844)
  was still running at this review's last check.
- [Latest hosted static analysis](https://github.com/musicalengineer/VideoScan/actions/runs/34953949410)
  succeeded at `34aeda64`; this is a separate lane from application tests.
- Existing local log
  `/Users/rickb/Library/Logs/VideoScan/nightly_test_20260915_020003.log`, at
  `34aeda64`, reports **7,677 Swift Testing tests / 1,064 suites, 22 issues
  including one known issue**, in 1,144.672 seconds. Legacy XCTest reports
  138 tests, four skipped, zero failures. This is not a fresh Xcode 27 run.
  Its published combined summary reports 7,748 passed, nine failed, 57 skipped.
  Failure families include catalog-migration scale (113.05s against 15s), a
  missing inferred-date recovery sidecar, and seven tree-identity/badge tests.
- Fresh headless source ratchets: **zero new subprocess-injection findings;
  zero new check-then-act findings, one grandfathered finding** in
  `VideoScanModel+Rename.swift:116`. These narrow checks are not general safety
  or coverage measurements. Baselines were not changed.

### Acceptance contract for the first patch

Drive Health currently has parser/heuristic tests but no caller-level injected
subprocess seam. ProcessRunner has deadline/escalation tests; those alone cannot
prove a caller supplied a deadline. Add a narrow test seam preserving actor
ownership, then exercise success, unavailable tools, timeout, and fallback through
the actual caller. A hung fake command must finish within a bounded test budget;
the resulting warning must be distinguishable from healthy data. Isolate tool
paths, cache state, and defaults. Retain a sensor covering all three commands.

Preserve successful nonzero smartctl exits with usable JSON and Apple NVMe
fallback. For the later ScanEngine patch, `runCapturingStderr` currently drops
the runner's `timedOut` field; merely passing a deadline may leave empty stderr
and an unhelpful diagnosis, or allow partial output to be mistaken for success.
Pin that caller behavior and distinguish cancellation from deadline expiry.

Drive Health does not traverse catalog records or open media, so the 100k-record
and media-matrix dimensions are inapplicable to that patch. The later ffprobe
patch does open media and needs the required synthetic container matrix. App-host
validation must be explicitly routed to M5/M1 or an M4 quiet window; this review
does not schedule or claim those runs.

For the proxy admission fix, an injected, gated runner should queue more than
the concurrency limit, finish active work, and prove every queued request
eventually runs while global/per-volume limits remain enforced.

## Metrics at the reviewed commit

Tracked Swift files only; physical lines include comments and blanks. Build
outputs, dependencies, worktrees, tools, and CLI targets are excluded.

| Scope | Files | Physical lines |
|---|---:|---:|
| App production | 656 | 231,997 |
| Core production | 91 | 23,924 |
| App tests | 649 | 194,762 |
| Core tests | 58 | 12,526 |
| UI tests | 12 | 1,485 |

Relative to assessment commit `01d94091`, app production grew **4.1%**, app
tests **5.2%**, and core production **6.3%**. App files over 1,000 lines rose
from 34 to 35. There is no fresh coverage or compiler-derived complexity result.
SwiftLint/lizard and `.Codex/metrics-baseline.json` are absent locally.

Largest production files are ArchivistChatWindow (2,650), HallieTurnExecutor
(2,351), FamilyTreeLiveModel (1,973), HallieTurnExecutor+Conversation (1,961),
and HallieLineageQuestion (1,911). Since September 1, the conversation extension
has 31 nonmerge commit touches, executor 26, and lineage recognizer 23.
Churn and size identify review candidates; neither establishes a defect.

Reproduce with `git ls-tree` plus `git cat-file` over the five listed trees;
count newline bytes. Churn uses `git log --no-merges --numstat --no-renames`
since `2026-09-01T00:00:00-04:00`. Existing `collect_metrics.sh` uses a different
scope, including CLI and excluding core; do not directly compare its total.

## Previously reported debt: current status

- **Hallie response commit extraction is merged**, ancestor `2dbc6c6f` via
  `8f209fa2`. The existing local nightly log records all **12** behavioral tests
  passing, including real conversation-memory publication (lines 13467–13492).
  Its September 13 document's pending integration statement is historical.
- **ConfirmPersonSheet is split**: original file 1,832 → 761 lines, but its
  four-file family totals 2,224 lines. This is code organization progress;
  it does not by itself prove reduced runtime coupling or total complexity.
- People stale-identity, tag-writeback, and symlink-rebase follow-ups have
  landed (`bcea1af3`, `f1aa88ac`, `57a51ca6`). Do not reissue the old HOLD list
  without reviewing those fixes. This pass did not re-audit all identity paths.
- POIStorage grew 345 → 1,176 lines and DateInference 416 → 881 since the prior
  assessment. Review their operation boundaries after the reliability slices.

Track debt paid by closed failure paths, focused regression evidence, and clearer
ownership. Moving lines among extensions is insufficient on its own.
