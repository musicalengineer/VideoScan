# Codex brief: P0 purge fix, verify pass on the redesign (2026-10-23; Rick approved this pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**Range:** `f59f6d841..3197ef431` (branch `worktree-agent-a8bd550582aa69e8e`). One commit. This answers your cycle #123 (4 findings on `f59f6d841`).

## Workflow in one sentence
A rescan replaces an old catalog row with a fresh one; the old row may go only when the fresh row is actually stored (or held awaiting its full hash).

## What changed since #123
Path-inferred pairing is gone. The scan merge already knows which old id each fresh record replaces, so the relation is carried explicitly:
`purgeCatalogRows(replacedBy:)` → `CatalogCommitter.purge(replacements:)` → `CatalogCommit.Plan.replacements` (purged id → replacement id).
In `CatalogCommitBody`, every purge a record replaces plus ALL of that record's snapshots commit in ONE savepoint; the purges stand only if the record ends stored (written / partial / unchanged) or held in `pending_rows`. If the record is not in this commit, they stand only if `CatalogTransaction.storedRecordPresent(id:)` (live `files` row or un-purged pending row) says the store already holds it. A purge with no relation is a plain removal and runs alone. The committer keeps a kept purge WITH its relation; `duePurges` sends it only alongside its replacement or once the store holds it.

## Files in scope (do not explore outside them)
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommit.swift`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogRepository.swift`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift`
- `VideoScan/VideoScan/Catalog/CatalogCommitter.swift`
- `VideoScan/VideoScan/Catalog/VideoScanModel+CatalogPurge.swift` (`placeRecord` inherit / uncurated-swap doors)
- `VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift` (`replacementRelation`, both merges)
- Tests: `VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCommitRelationTests.swift`, `…/CatalogCommitReplacementTests.swift`, `VideoScan/VideoScanTests/CatalogKeptPurgeRetryTests.swift`

## Invariants to attack
1. **Your four #123 findings are really closed** (pending predecessor; case-variant sibling; repeated snapshots; forgotten kept purge). Name any variant that still loses a row.
2. **No row is ever lost.** Any mix in one commit of related purges, unrelated purges, writes, holds and refusals: can a purged id end with neither itself nor its stored replacement live? Include: one replacement naming several old ids; one old id named by two replacements; a relation whose replacement id is also purged in the same plan; a held replacement whose pending row is later purged or fails its full hash.
3. **No dead row is kept forever.** A truly gone file (no relation) still purges. Can a mis-stated relation (a door names a replacement that will never be stored) pin an obsolete row live indefinitely, and is that visible?
4. **Retry state.** Can the committer's kept-purge-with-relation be lost or sent alone across another save, relaunch, catalog reload or cutover? Is the relation voided correctly when a door removes the replacement itself?
5. **Callers.** Does every swap door in ScanMerge and CatalogPurge name its relation, and is there any remaining door that purges a replaced id without one (which would now run as a plain removal, i.e. the original bug)?
6. **Tests are real.** `incidentShapeLosesNothing` claims 100 writes + 100 holds + 100 real `archive_copies_need_source` refusals in one generation, no injected trigger. Confirm it would fail on `f59f6d841`'s design.

## Evidence already run
Each of F1–F4 has a pinning test red at `f59f6d841` and green at `3197ef431`. Core `swift test --filter CatalogCommit`: 53 tests in 9 suites, green. App Debug: 121 tests in 14 suites, green. Branch with main merged (`4c7810861`): sensor lane green, 555. Nightly on main (without this branch) green, 12,249 / 0.

## Known and declared, NOT findings
- `replaceArchiveCopy` still refuses re-created import-era copies whose source was never stored; each FamilyArchive rescan logs ~95 `NOT REMOVED` lines, safely. Separate provenance decision.
- A replacement removed from memory without a door's purge leaves the old row live and its purge pending in-session (conservative; a relaunch reloads it).
- Recovery of the 95 already-purged rows is a separate, not-yet-run tool.

At most FIVE findings, most serious first, each with a one-line failure scenario and the fix. P1 = any path that still loses a catalog row of a file that's on disk.

**Do not explore outside the files listed above.**
