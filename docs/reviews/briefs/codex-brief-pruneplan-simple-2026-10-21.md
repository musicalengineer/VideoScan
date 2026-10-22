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
