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
