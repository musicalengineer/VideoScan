# Codex brief: P0, a rescan purge landed when its replacement row was refused (2026-10-22 night; Rick approved this pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**Range:** `e96c51663..f59f6d841` (branch `worktree-agent-a8bd550582aa69e8e`). One commit.

## The incident (facts, from the logs and a backup copy)
- A rescan of /Volumes/FamilyArchive gives every re-seen record a NEW id and asks the store to purge the old ids (`Volumes/VideoScanModel+ScanMerge.swift:574`, `purgeCatalogRows(ids: replacedIDs …)`).
- Generation 681 committed `written 456 · held 502 · refused 95 · removed 641` in ONE commit.
- `CatalogCommitBody.run()` applied every purge first, each in its own savepoint, with no link to its replacement.
- 95 replacements were then refused: `SQLite error 19: an archive copy names its source`. The cause is the `archive_copies_need_source` trigger, reached via `replaceArchiveCopy` in `GRDBCatalogRepository+Live.swift:117–131`.
- Result: 95 archived Masters on FamilyArchive had NO live catalog row while their files were on disk. No media was touched.
- Separately, the Archive tab hid any archive copy whose source row existed but was inactive (trashed by Prune), so it showed 9 of 144 Masters.

## The fix (files in scope; do not explore outside them)
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift`: a purge and the record replacing it at the same path commit together in one savepoint. If the replacement is not stored, the purge is undone, logged `NOT REMOVED … kept in the catalog`, and flagged `keptForReplacement`.
- `…/Commit/CatalogCommit.swift`, `…/Store/CatalogRepository.swift`, `…/Store/GRDBCatalogRepository+LivePending.swift`: the new `CatalogTransaction.storedLivePath(id:)`.
- `VideoScan/VideoScan/Catalog/CatalogCommitter.swift`: a purge the store kept is never re-sent alone on the next save.
- `VideoScan/VideoScan/Catalog/CatalogQueries.swift`, `VideoScan/VideoScan/Archive/ArchiveView+Categories.swift`: an archive copy stands in for its asset when the source is gone or inactive (`sourceRepresents`, `pfIsActive`).
- Tests: `VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCommitReplacementTests.swift` (7), `VideoScanTests/CatalogRescanRefusedReplacementTests.swift` (end to end: rescan → 4 commits → reload), `VideoScanTests/ArchiveTimelineCompletenessSensorTests.swift` (6, including 100k and a production-scale "every live archive copy appears exactly once"). All were red before the fix and green after. The sensor lane is green (555).

## Rick's ruling (not a finding)
On a rescan, an archived Master's row may be replaced ONLY when its replacement, carrying provenance and fixity, is actually stored. "Never replace" was declined because it conflicts with the fixity-refresh contract (`RescanPreservationTests`).

## Invariants to attack
1. **No row is ever lost.** For ANY combination in one commit of purges, writes, holds (pending rows awaiting a full hash) and refusals, can a purged id end with neither itself nor a stored replacement at its path? Consider:
   - the replacement held (pending) rather than refused;
   - a replacement at a DIFFERENT path (rename or move on rescan);
   - several old ids for one path;
   - a purge with no replacement at all ("gone from disk");
   - case-insensitive volumes (`path_fold`).
2. **Atomicity.** Is "purge + its replacement in one savepoint" truly all-or-nothing, including a failed trigger, a crash mid-commit, and the ledger and tombstone writes?
3. **Retry semantics.** `keptForReplacement` plus the committer's "never re-send a kept purge alone": can a kept purge be dropped forever (a stale duplicate row stays live), or re-sent alone through another path (another save, a relaunch, catalog reload, cutover)?
4. **The "gone from disk" purges still work.** A truly deleted file must still be purged; the fix must not keep dead rows forever.
5. **The Archive view.** Can `sourceRepresents` show an archive copy twice (source active AND copy), or hide one whose source is active on an offline volume?
6. **Are the tests real?** Do they pin the exact incident (95 refusals by the trigger, with old rows already purged), or a softer variant?

## Evidence already run
Red→green for all three test files. Core: 46 tests in 8 CatalogCommit suites. App: 125 tests in 12 suites, including RescanPreservation, cutover-purge and ScanMerge. Sensor lane green (555).

## Known and declared, NOT findings
- `replaceArchiveCopy` still refuses re-created import-era copies whose source was never stored. Every FamilyArchive rescan will log about 95 `NOT REMOVED` lines, safely, until a provenance decision is made. That's a separate decision.
- The recovery of the 95 rows is a separate, not-yet-run tool.

At most FIVE findings, most serious first, each with a one-line failure scenario and the fix. P1 = any path that still loses a catalog row of a file that's on disk, or that shows a false archive state.

**Do not explore outside the files listed above.**
