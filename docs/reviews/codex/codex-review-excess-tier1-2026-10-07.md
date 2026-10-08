# Codex review — Excess Tier 1

- Range: `928df4d895badeff76a5433cc9bc8db04273df91..c7450c83e`
- Credits spent: unavailable
- Tokens: 67949
- Finding count: 3
- Verdict: fix — two safety gaps and one outcome-reporting mismatch at `c7450c83e`.
- Run: 2026-10-08T21:52:03Z (cycle #52, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3

Verdict: fix — two safety gaps and one outcome-reporting mismatch at `c7450c83e`.

1. **P1 — Preparation replaces the shown survivor’s path.**  
   `VideoScanModel+ExcessCopies.swift:313–315,343–347` looks up shown survivor IDs but captures and accepts their **current** paths, without checking `live.fullPath == s.fullPath`.

   **Reproduction:** Show an offered copy and a held survivor. Remove the survivor’s shown file, update that survivor record to another existing path, then prepare the job. Preparation accepts the replacement path and sets `forceArchiveRead = false`, instead of holding because the shown survivor disappeared. This breaks invariant 2 at preparation.

   **Fix:** Require the survivor to remain at its shown path before capturing its stamp. Reject survivors that alias the target or archive.

2. **P1 — Snapshot filtering can disconnect an archive file from its preservation master.**  
   `VideoScanModel+ExcessCopies.swift:133–137` omits nonmatching lineage intermediates. `ExcessCopiesPlan.swift:357–365,387–399` builds ancestry exclusively from those filtered snapshots, then falls back to the matched archive file as master.

   **Reproduction:** Catalog lineage is `preservation master → intermediate → source` and `archived original → source`. The intermediate has no matching digest or sampled hash, so snapshot capture excludes it. Give the preservation master a one-hour duration and the archived original plus candidate two-hour durations. Their roots become disconnected; the candidate is compared against the two-hour original and offered despite exceeding the preservation master.

   **Fix:** Preserve complete ancestry separately from nomination filtering, or resolve master identity before filtering. Add a model-level regression covering the omitted intermediate.

3. **P2 — Trash failures are FAILED rather than HELD.**  
   `VideoScanModel+PruneApply.swift:768–770` maps removal errors to `.failed(reason)`. `ExcessCopiesJob.swift:175–178,155–156` propagates that outcome and fails the job.

   **Reproduction:** Make `hooks.removeFile` throw a Trash-unavailable error. The copy produces a failed outcome rather than the held outcome required by invariant 6.

   **Fix:** Translate Trash failures to held outcomes specifically for excess cleanup, preserving existing prune callers’ behavior. The scoped code contains no permanent-delete fallback; the delegated removal implementation is outside this review’s scope.

All four scoped files were read. **Shared prune seams with nil/false defaults: read, no findings. Job `run`/`work`: read, no additional findings.**

These are source-traced reproductions, not executed regression tests. `git diff --check` passed; the supplied 164-test Release result was not independently rerun.

I could not write `docs/reviews/codex/codex-review-excess-tier1-2026-10-07.md`: this session permits filesystem reads only. Credit usage telemetry is unavailable.

## Brief

# Codex brief: Delete excess copies, Tier 1 (branch feat/delete-excess-tier1)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line: `Verdict: <merge | fix | block> …`.

**Range:** `origin/main...feat/delete-excess-tier1` (tests first c424491a → fbb2527f → 75d8b569, plus the QA fixes after it).
Design, amendments and Rick's decisions: `docs/design/delete_excess_copies_2026_10_06.md` (read the "Amendments" and
"Rick's decisions" sections; they override the body).

**Do not explore outside these files/functions:**
- `VideoScanCore/Sources/VideoScanCore/ExcessCopiesPlan.swift`: `compute`, `keepReason`, `Item.survivors`, `ArchiveIndex`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+ExcessCopies.swift`: `excessCopySnapshots`, `excessTargets`, `prepareExcess`, `applyExcess`, `excessPruneItem`, `excessLaneGuard`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+PruneApply.swift`: `pruneOneCopy`, `pruneArchiveEvidenceNow` (and the new seams `laneGuard` / `forceArchiveRead`)
- `VideoScan/VideoScan/MediaOps/ExcessCopiesJob.swift`: `run`, `work`

**Invariants to attack (prove or break):**
1. No copy reaches the Trash unless, IN THIS JOB, the copy was read in full and digest-matched, AND either a survivor the sheet SHOWED was re-stat'd present, or the archive file was read in full and matched.
2. Moved ⊆ the sheet's offered set; survivors are taken from the SHOWN plan, and a shown survivor that's now missing HOLDS the move.
3. Never a target: the archive set or its volume (any path spelling: symlink, case, firmlink), an attested archive-backup drive, a read-only drive, a network mount (checked at move time), an Angel or Rick hold, a viewer-mode Mac, a copy LONGER than the archive master (Rick's rule) or of unknown length, a sampled-hash-only match.
4. When the archive becomes the only copy, the dialog said so (Rick's decision 1).
5. Existing prune callers behave exactly as before (seams nil / false).
6. (Added 2026-10-08, Rick: the Trash is his safety net; he empties it daily.) When a copy's volume cannot take it to the Trash (no Trash support, trash call fails, ExFAT/network quirks), that copy is HELD and reported with a reason. Nothing on this path falls back to a permanent delete / unlink.

**Evidence already run:** the Excess* suites (164 tests in 14 suites, Release); in-house qa round 1 (2 major + 2 minor, all fixed red → green).
**Known/accepted, do not report:** the ★★★ hold threshold (≥ 4) is pending Rick's decision; SMB trashing is unverified on a real Mac.

**Write the verdict to:** `docs/reviews/codex/codex-review-excess-tier1-2026-10-07.md`

## Closure

Branch `feat/delete-excess-tier1-codex` (child of `feat/delete-excess-tier1` at `c7450c83e`; worktree
`.claude/worktrees/excess-tier1-codex`). Every finding was reproduced by EXECUTION before its fix (the red
tests actually moved files into the sandbox Trash), then fixed and pinned. Release, `ENABLE_TESTABILITY=YES`,
`-only-testing` by suite.

| Finding | Fix commit | Pinning tests (suite → test) | Red → green |
|---|---|---|---|
| **F1 (P1)** shown survivor's path replaced | `d2e5febe0` | ExcessCopiesApplyTests → `aShownSurvivorRepointedElsewhereHoldsTheMove`, `aShownSurvivorAliasingTheTargetHoldsTheMove`, `survivorAliasTable` | RED 17 tests / 2 failed (source moved in both) → GREEN 34 tests in 4 excess suites |
| **F2 (P1)** filtered snapshots disconnect master | `ccc22e913` | ExcessCopiesApplyTests → `anOmittedIntermediateStillJoinsTheMaster` (codex's exact model-level scenario: master 1 h → intermediate → source; original + candidate 2 h → flagged LONGER, nothing moved); ExcessCopiesPlanTests → `completeLineageJoinsTheMasterThroughAnOmittedIntermediate` | RED 19 tests / 1 failed (both 2 h copies moved) → GREEN 36 tests in 4 excess suites |
| **F3 (P2)** Trash failure = FAILED | `8f2716575` | ExcessCopiesApplyTests → `aTrashFailureIsHeldAndNothingIsDeleted` (removeFile seam throws: HELD with drive + reason, exactly one attempt per copy, files on disk, no copyTrashed/copyDeleted/approval, job rows HELD, job not `.failed`), `onlyATrashFailureBecomesAHold` | RED 20 tests / 1 failed → GREEN |

How each was fixed:
- F1: `prepareExcess` stamps only the SHOWN survivor paths (plus each target and its archived file);
  `excessSurvivor` holds unless the live record is active at the shown path, on disk there, and not an alias
  of the target or the archived file (`excessSurvivorAlias`: `ArchiveVolumeProtection.canonical` + case fold,
  or same device+inode — `FileIdentityStamp.capture` opens through symlinks; hard links share the inode).
- F2: `ExcessCopiesPlan.compute(_:lineage:)` / `ArchiveIndex(_:lineage:)` take a complete child→parent map;
  `VideoScanModel.excessLineage()` builds it from every record's `derivedFrom` (purged included), one O(records)
  pass on main per plan, not cached, not in a view body. 100k scale suite still within budget.
- F3: `excessOneCopy` maps `.failed` → `.held("couldn't move it to the Trash on <volume>: <reason> — nothing was
  deleted")` via the pure `excessTrashFailureHeld`. `pruneOneCopy` / `pruneCopyResult` are untouched, so other
  prune callers are byte-for-byte as before (invariant 5).

Final regression run (head `8f2716575`): 191 tests in 16 suites — the 14 from the brief's evidence (164 before,
171 now) + ReadOnlyVolumeCodex258Tests + AtomicFilePublishSensorTests. 190 passed. 1 PRE-EXISTING failure:
`AtomicFilePublishSensorTests.onlyKnownSitesCallRenameDirectly` — its exact-set list still names
`CyberBrainWriter.swift` after the rename moved to `CyberBrainWriter+Persistence.swift` in `7b9197804` (already
in `c7450c83e`); unrelated to this lane.

Related, NOT changed (out of scope, invariant 5): the older "Archived — what next?" prune lane has the same
shape as F1 — `pruneSurvivorRequirements` takes an unchecked survivor's CURRENT `record.fullPath` at prepare,
not the shown row's path. Filed here for a separate decision.

## Closed

Closed by `8f2716575` at 2026-10-08T22:41:57Z.
