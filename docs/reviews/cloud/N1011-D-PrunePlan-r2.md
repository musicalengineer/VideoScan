Brief: N1011-D-PrunePlan (second pass) | Source: main@4e3210e5 | Wall clock: ~25 | Files read: 7
Finding count: 1 (REAL 1 / NEEDS-MAC 0 / NOISE 0)
Verdict: The first pass's F1 and F2 are fixed and pinned (b6fa28fd). F3, F4 and the step-0 oracle are still open, and the refactor plan stands unchanged. One new duplication: the Excess Copies planner added on 10-07 honours "you tagged it Keep", while the prune checklist cannot see the tag and can pre-check that copy for the Trash.

## Why a second pass
- This row already ran on 10-06 (`N1011-D-PrunePlan.md`, on main; ledger: 2 confirmed, issue GH #288). It is tonight's dated row (10-11), and Rick named it again, so this pass covers **what changed since** (`ebcd2f09..4e3210e5`). It does not repeat the first report's guard inventory or plan.
- **Changed in range:**
  - `PrunePlan.swift`: +9/−4, only the F1 fix in `Family.selection`.
  - `PrunePlanTests.swift`: +48, two new tests.
  - `VideoScanModel+PruneApply.swift`: +125/−43, the Excess Tier 1 seams (`PruneItem.forceArchiveRead`, `PruneLaneGuard`, extracted archive-evidence and result-mapping helpers), and the junk P1 fix `33967b31`.
  - New, outside the row's file but answering the same question: `VideoScanCore/ExcessCopiesPlan.swift` (465 lines).
- **Read:**
  - `PrunePlan.swift` (`selection`, `plan` 999-1150, `lockedReason` / `softReason` 1204-1219, `copyFacts` / `protection` 148-153, 238-242)
  - the `b6fa28fd` diff and its two tests
  - `ExcessCopiesPlan.swift` (`keepReason`, `personHold`, `verdict`, `compute`)
  - the prune snapshot builder `archiveCopySnapshots` (Archive/VideoScanModel+MediaLedger.swift:250-285)
  - grep-only: `VideoScanModel+PruneApply.swift`, `ArchivedWhatNextSheet.swift`, the tests folders
- **Measurements:** `ci/baselines/complexity_debt.json` and `origin/metrics` (last line ts 2026-10-10T10:52Z, sha 40912078). Unchanged for this file: `plan` CCN 52 / 108 NLOC (still #1 in the repo top 15), `Family.logLine` 26, `group` 16, `selection` 16. No new offenders in the file.
- **Line shift:** from line ~705 onward, the first report's line numbers are now **+4/5** (for example `plan` 995 → 999, `lockedReason` 1199 → 1204). The guard table's rules and pins are otherwise unchanged.

## First pass on current main

| First pass | Status | Evidence |
|---|---|---|
| F1 P3: `selection` counted an archive-volume copy as an extra device | **Fixed** | b6fa28fd: `case .kept(let reason)` with `reason != .onArchiveVolume` (PrunePlan.swift:708-715). `testSelectionDoesNotCountAnArchiveVolumeCopyAsAnExtraDevice`, red before and green after per the commit. |
| F2 P3: the plan rule "archive-volume copy holds no device" was unpinned | **Pinned** | `testAnArchiveVolumeCopyHoldsNoDeviceForTheBar` asserts `keeperRequired`, the keeper, no default check and `.kept(.onArchiveVolume)`. Red by mutation per the commit. |
| F3 P3: the protection line says "Archive ✓verified" over rows locked for "only a version archived" | **Open** | `copyFacts` (148-153) still marks any archive-side copy with fixity as verified. No test calls `protection(families:)` on the trim-only shape; the three existing calls are other shapes. |
| F4 P3: "latest answer across the whole family" unpinned at plan level | **Open** | `plan` :1061 is unchanged (`latestPerKind(fam.flatMap(\.attestations))`). No new PPT case puts a later "no" on a different member than an earlier "yes". |
| F5 NOISE: two repair-kind sets | Unchanged | — |
| Step 0: the `legacyPlan` oracle and property test | **Not built** | No `legacyPlan` / oracle in the Core tests. It is still the precondition for steps 1-5. |
| Backlog: `selection` reuses step 2's `holdsDevice` | Now **due** | F1's fix wrote the rule a second time, inline (`reason != .onArchiveVolume` at :713 vs `locked != .onArchiveVolume` at :1044). Step 2's `holdsDevice(_:)` should own both. Two spellings of one rule is exactly how F1 happened. |

## Finding

### N1011-D-PrunePlan-r2-F1: P3 · REAL · Two planners answer "has Rick said keep this copy?" differently: Excess Copies holds a Keep-tagged copy, the prune checklist pre-checks it for the Trash
- **Symbols:**
  - `ExcessCopiesPlan.personHold(starRating:tags:keptInLane:)`, VideoScanCore/ExcessCopiesPlan.swift:273-278: `tags.contains { $0.caseInsensitiveCompare("keep") == .orderedSame }` returns "you tagged it Keep". It is reached from `keepReason` (:317-326), so the copy is **left alone**. The comment at :270 says "Rick's live holds are the Keep tag and Keep here".
  - `PrunePlan.softReason`, VideoScanCore/PrunePlan.swift:1215-1219: only `isVersion` and `hasHumanNote` make a copy soft. `ArchiveCopySnapshot` has **no tags field**, and the builder (Archive/VideoScanModel+MediaLedger.swift:265-285) passes notes, stars and disposition but not tags.
  - `PrunePlan.plan`, bar-met branch, :1138-1150: every plain copy except the keeper goes into `trash`, and its row is `(.candidate, nil, true)`, i.e. **default-checked**.
- **Scenario:**
  1. A family has a fixity-verified archive copy and two working copies, A and B, on two connected drives. Rick has tagged B "Keep" (stars 0-2, no note). The level is ordinary and the bar is met by the keeper.
  2. **Excess Copies** (Curator ▸ CLEAN UP) lists B under "left alone — you tagged it Keep".
  3. **Archived — what next?** on the same family: B is plain, so it is in `trash` and its box is pre-checked, with no reason shown. Apply moves B to the Trash. `PruneLaneGuard`, which carries the live holds, is passed only by the Excess lane (`excessLaneGuard`, VideoScanModel+ExcessCopies.swift:257). The prune paths call `pruneOneCopy` without it (PruneApplyJob.swift:541, PruneApply.swift:868), so the default `laneGuard: nil` applies (PruneApply.swift:647).
- **The guard that would make it false, and why it doesn't hold:**
  - The prune sheet's contract is "your checks are the truth", and Rick sees the row before Apply. But the row is pre-checked, and nothing on it says he tagged it Keep. The default is the plan's recommendation, and that recommendation contradicts his tag.
  - The archive copy is verified and B goes to the Trash, not deleted, so nothing is lost. That is why this is P3, not higher.
- **Why it is the D-theme's "debt that bites":** C01-F1 class, one question with two answers in two planners. Each planner has its own keep list:
  - `lockedReason` + `softReason`: archive volume, offline, missing, pair; version, note.
  - `keepReason`: backup drive, the gate, network mount, backup-like drive, offline, pair, Angel, person hold.
  - The lists overlap on offline and pair only. Network mount and the Angel hold also differ, but both of those fail safely at the prune removal boundary (no Trash on a network mount; the Angel's buffer is its own). Only the person hold changes what is **pre-checked**.
- **Pinning test (fails today; add to `PruneApplyTests`, app level, because the tag lives on `VideoRecord`):**
  1. A catalog with a verified archive copy and two working records on connected drives; one record has `tags = ["Keep"]`.
  2. Build the snapshots with `archiveCopySnapshots`, then compute the plan with the default options.
  3. Expect the Keep-tagged row to be not `defaultChecked` and to carry a hold reason. Today it is default-checked with reason nil.
- **Fix direction (design; Rick to rule, because it changes a default):** one Core rule for person holds, `CopyHold.person(starRating:tags:keptInLane:)`, moved out of `ExcessCopiesPlan` into a shared file. Carry `tags` on `ArchiveCopySnapshot`, and give `softReason` a `.personHold` reason (checkable, never default-checked, never elected, like a noted copy). Both planners then call the one function.

## Plan changes since the first pass
- **Steps 0-5 stand as written.** Two additions:
  - **Step 2 gains:** `holdsDevice(_:)` replaces both inline spellings (:713 and :1044), as in the table above.
  - **New step 2b (S, after Rick rules on r2-F1):** `softReason` reads a shared `CopyHold`. Pins needed first: r2-F1's test, plus the oracle extended with a `tags` dimension (Keep / none).
- **Concept and canon (theme D step 4) for r2-F1's fix:** a **pure function** in Core (`CopyHold.person`) that both planners call. This is the single-source-of-truth rule the playbook's "decision with several outcomes" job states (`docs/practices/swift_playbook.md`). In C++ terms: one free function in a shared header instead of two private copies of the same `if`.
- **Rejected:** copying `personHold`'s three lines into `softReason`. That is a third copy, the same drift that produced F1.

## Not covered
- `ExcessCopiesPlan` beyond its keep rules: nomination, `ArchiveIndex`, the length rule, `backupLikeVolumes`. It is new, data-risk code that belongs to its own R or T row (suggest N1019-R-week or a C-brief), not to this D row.
- The `PruneApply` diff (`forceArchiveRead`, the extracted helpers) was grepped, not reviewed. It is the apply path, outside this row's "PrunePlan.plan and its file".
- Nothing was built or run.

## Blockers & environment
- **Branch:** README rule 3 names `cloud/N1011-D-PrunePlan`. This session may push only to its designated branch, so the report is on `claude/compassionate-babbage-kn9mbj`, like the rest of this batch.
- No lizard (PyPI is blocked; not needed). The numbers come from `complexity_debt.json` and `origin/metrics`. No other failures.
