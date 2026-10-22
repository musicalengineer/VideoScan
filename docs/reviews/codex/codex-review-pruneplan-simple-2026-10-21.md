# Codex review — PrunePlan simple

- Range: `187acfa13..112abb4d4`
- Credits spent: unavailable (usage not exposed)
- Tokens: 69995
- Finding count: 1
- Verdict: fix — candidate `112abb4d4` misses an I5 digest recheck.
- Run: 2026-10-22T02:28:45Z (cycle #118, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (usage not exposed) | Finding count: 1

Verdict: fix — candidate `112abb4d4` misses an I5 digest recheck.

**P2 — A candidate’s catalog digest can change after preparation without holding the move.** [VideoScanModel+PruneVerification.swift:157](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-acb6cb8f27a7b7309/VideoScan/VideoScan/MediaOps/VideoScanModel+PruneVerification.swift:157) checks candidate identity, removal state and path, but only rechecks the **archive’s** digest. [VideoScanModel+PruneApply.swift:254](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-acb6cb8f27a7b7309/VideoScan/VideoScan/MediaOps/VideoScanModel+PruneApply.swift:254) has the same omission.

**Failure scenario:** Change the candidate’s `contentFixity` to another digest after preparation, preserving its object, path and disk bytes; both disk proofs pass and the catalog guard authorizes Trash despite the changed digest.

Code-traced reproduction: use the existing fixture’s `beforeMutation` hook to assign `ContentFixity.captured(path: f.copy.fullPath, digest: String(repeating: "d", count: 64), byteCount: f.copy.sizeBytes)`. The final catalog guard returns `nil`. The existing digest-mutation test changes it **before** rebuilding the plan, so misses this window.

Recheck `CatalogCommit.digest(of: rec) == expectedArchiveDigest` in both live gates and add that regression case. This demonstrates an I5 violation, not lost bytes or curation; hence P2.

Read, no findings:

- `PrunePlan.swift`
- `PrunePlan+Advice.swift`
- `VideoScanModel+PrunePlan.swift`
- `PruneApplyJob.swift`
- `VideoScanModel+TidyCatalog.swift`
- `VideoScanModel+MediaLedger.swift`

Both Apply and Verification were read with the finding above. No additional findings in mandatory full reads, per-batch evidence lifetime, or offered-row admission.

**Verification limits:** I8 remains unproven: [PruneApplyTests.swift:428](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-acb6cb8f27a7b7309/VideoScan/VideoScanTests/PruneApplyTests.swift:428) checks shared digest keys, but never trashes and reloads unsaved curation. I2’s symlink/renamed-volume behavior and I3’s no-Trash-volume fallback depend on implementations outside the permitted files; the scoped caller requests `.toTrash` exclusively.

Static review of `187acfa13..112abb4d4`. No files written; no tests rerun.

## Brief

# Codex brief: PrunePlan rebuilt simple — the delete path (2026-10-21; data-risk; Rick approved codex as needed)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `187acfa13..worktree-agent-acb6cb8f27a7b7309` (head `112abb4d4`, not merged; review it as the candidate).

**Design:** docs/design/pruneplan_simple_2026-10-21.md. Rick's rule: "check for dups and copies, offer to delete; if none, say so; otherwise the person deletes what they want; if it is too hard to tell, say 'no obvious choices'."
- **R1–R5:** a copy is offered only if:
  - its full SHA-256 equals a live, fixity-verified archive_copies digest;
  - the row is live;
  - it is not the archive copy, not under the archive root, not on the archive volume;
  - its drive is mounted, local, not Read-only or Archive-backup;
  - it is not a recovered A/V pair half.
- Everything else gets a reason.
- **At the move:** the archive copy's full SHA-256 is read once per batch and the candidate's full SHA-256 is read; both must match. Then the JunkDeletionGuard recheck, `deleteConfirmedJunk(.toTrash)` only, and ledger lines.
- **Removed:** the ImportanceBar, keeper, override, versions, name-alikes, Hash to confirm, note carry and survivor stamps (−3,572 production lines; CCN-15 excess 80 → 0).

**Files (only these):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift`: `build`, `keeps`, `unarchived`, `confirmingOnDisk`, `shown`, `reasonCounts`, `ArchiveLookup.placement`/`related`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan+Advice.swift`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+PrunePlan.swift`: `pruneSnapshots`, `verifiedArchiveDigest`, `PruneRelevance.contains`, `PruneHoldRules.snapshot`/`hold`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+PruneApply.swift`: `pruneTargets`, `pruneChange`, `preparePrune`, `pruneOneCopy`, `pruneLiveRecord`, `pruneLiveHold`, `pruneArchiveReading`, `pruneMove`, `finishPrune`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+PruneVerification.swift`: `pruneFullRead`, `readArchiveInFull`, `pruneCandidateProof`, `pruneProofProblemOnDisk`, `pruneProofProblemInCatalog`
- `VideoScan/VideoScan/MediaOps/PruneApplyJob.swift`: `run`, `work`, `settle`
- `VideoScan/VideoScan/Catalog/VideoScanModel+TidyCatalog.swift`: `computeTidyCatalogPlan`, `buildTidyPlan`
- `VideoScan/VideoScan/Archive/VideoScanModel+MediaLedger.swift`: `offerArchivedWhatNext`, `ArchivedWhatNextRequest.scope`

**Evidence already run:**
- QA r1 found no data-loss issue; I1–I9 held by code reading, plus a schema check that all curated tables are keyed by digest. 3 UX findings were closed red→green.
- Red-by-mutation on four breaks: archive read reused across batches, archive digest check skipped, candidate digest check skipped, a non-offered row let through.
- Core PrunePlanTests 18; app prune/Tidy suites 135; 100k scale tests; sensor lane 549 green.

**Do only this. Attack these invariants:**
- **I1:** no file moves unless the full SHA-256 of the archive copy AND of the candidate were both read from disk in THIS batch and both equal the archive_copies digest.
- **I2:** nothing on the archive root or volume, or on a Read-only, Archive-backup, network or offline drive, is ever listed or moved, including via symlinks or a renamed volume.
- **I3:** Trash only; no path to a permanent delete, including a volume with no Trash.
- **I5:** a row changed between the list and the move (path, digest, removal state, file replaced) is held.
- **I6:** a version or a name-alike can never reach `pruneOneCopy`.
- **I8:** no note, star, tag, person, date or place is lost when the copy is trashed, including unsaved in-memory edits.

At most FIVE findings. P0/P1 = a file moved without both proofs, a permanent delete, a protected file moved, or curated data lost. One-line failure scenario each.

**Known and declared, NOT findings:**
- Tidy offers less than before (copies without a stored full SHA-256 are "not hashed yet"; intended).
- No "keep one working copy" toggle (by design).
- A Trash failure ends the batch and drops the queue (pre-existing job rule).
- `copyTrashed` ledger lines use a junk batch id (pre-existing).

**Do not explore outside the files listed above and their tests.**

## Findings closed

| # | Finding | Closed by | Pinning test |
|---|---|---|---|
| P2 (I5) | A candidate's catalog digest could change after preparation without holding the move: both live gates rechecked only the archive's digest. | `0eeb053a7` — `pruneLiveRecord` (before the reads) and `pruneProofProblemInCatalog` (the JunkDeletionGuard's main-actor check just before the move) now require `CatalogCommit.digest(of: rec) == archive digest`; otherwise the copy is held: "the catalog's record of this copy changed — kept". | `PruneApplyTests.aCatalogDigestChangeAtTheMoveIsHeld` — red at `a72e19449` (copy trashed), green at `0eeb053a7`. Uses the fixture's `beforeMutation` hook exactly as codex traced it. |
| I8 gap | I8 was unproven: no test trashed a copy with unsaved curation and reloaded the store. | `a72e19449` (test only — no code change needed) | `PruneCuratedSurvivesTests.unsavedCurationOnTheCopySurvivesTheMove` — a sandbox catalog.sqlite (CutoverScene); unsaved note, star, person (Donna), user date and user place on the copy; the copy trashed through the real prune path; `saveCatalogNow` + relaunch from catalog.sqlite; every value present on the archive file's record. Green on first run: the curated tables are keyed by the whole-file digest, and R1 (now rechecked live) makes the copy's digest the archive's. |

**Declined / out of scope, as codex noted:** I2's symlink / renamed-volume behaviour and I3's no-Trash-volume fallback live in `deleteConfirmedJunk` / `BulkDeleteGate` / `ArchiveVolumeProtection`, outside this change; QA r1's `symlinkedFolderIntoTheArchiveNeverMoves` sensor pins the symlink case for the prune path (green), and the prune path requests `.toTrash` only (`PruneSensorTests`).

**Evidence after the fix:** prune suites 76 tests / 9 suites green (Debug); `scripts/run_sensors.sh` → `sensor lane GREEN (549 tests)`. One lane run before that went red on `FamilyTreeCardInvalidationSensorTests.catalogPublishesDoNotRebuildTheTreeCards` (a SwiftUI mount timing out at 38 s under the parallel lane; unrelated to prune) — 5/5 green alone in 7 s, and the full lane green on rerun.
