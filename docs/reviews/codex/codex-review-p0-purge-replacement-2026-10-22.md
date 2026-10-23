# Codex review — P0 purge replacement

- Range: `e96c51663..f59f6d841`
- Credits spent: unavailable
- Tokens: 77333
- Finding count: 4
- Verdict: fix — three reproducible plan shapes still lose catalog representation; corrected replacements can also become permanently blocked.
- Run: 2026-10-23T02:48:24Z (cycle #123, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — three reproducible plan shapes still lose catalog representation; corrected replacements can also become permanently blocked.

These are source-traced reproductions at `f59f6d841`, not newly executed tests.

1. **P1 — A pending predecessor bypasses protection.** [GRDBCatalogRepository+LivePending.swift:89](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:89)  
   **Scenario:** Commit live A → held B; next rescan submits purge B plus refused replacement C at the same path. `storedLivePath` reads only `files`, so B receives an independent pending purge. Loading excludes its tombstoned payload; A is already purged and C was never stored.  
   **Fix:** Include pending predecessors in replacement pairing and roll back their pending tombstones when the replacement fails.

2. **P1 — Case folding can bind a purge to the wrong file.** [CatalogCommitBody.swift:125](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:125)  
   **Scenario:** On a case-sensitive volume, purge old `/A.mov`; submit valid `/a.mov` B first, then refused `/A.mov` C. Both keys fold identically, so A pairs with B. B’s success commits A’s purge despite C’s refusal, leaving `/A.mov` without its row. Insertion itself honors `volumeCaseSensitive`; pairing does not.  
   **Fix:** Match using the stored volume’s case rule and path identity.

3. **P1 — Repeated replacement snapshots disable protection.** [CatalogCommitBody.swift:124](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:124)  
   **Scenario:** Submit purge A and two ordered snapshots of replacement UUID B at A’s path; both snapshots refuse. Because `sent[B] != 1`, neither pairs with A. A’s independent purge commits with no replacement. Ordered snapshots are explicitly supported by the commit contract.  
   **Fix:** Keep the ordered replacement sequence and its predecessor purge in one savepoint; retain A unless the sequence leaves a stored replacement.

4. **P2 — Forgetting the kept purge prevents successful correction.** [CatalogCommitter.swift:685](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:685)  
   **Scenario:** B refuses, A is retained, and its purge request is erased. Correct B’s refusal and save: B retries without A’s purge and hits A’s live-path collision. `duePurges` deliberately never reconstructs a purge from absence, so ordinary saves cannot complete the replacement.  
   **Fix:** Retain the A→B dependency and retry them together when B is eligible; suppress standalone retries without discarding the dependency.

For pairs actually formed, I found no separate atomicity defect under the repository’s documented transaction contract: the savepoint encloses the purge tombstone and replacement writes. Genuine standalone purges still execute. Crash behavior was not fault-injected.

Different-path replacements remain indistinguishable from legitimate disappearance purges because the plan carries no replacement relationship. The destructive plan shape is clear, but actual renamed-rescan caller reachability cannot be established within the permitted files; I have not counted that as a fifth finding.

The tests construct the real missing-source/import-era incident shape, but cover one such archive row. The 2,000-row test uses an injected trigger. They do not pin **95 real-trigger refusals within a mixed committed generation**, and the trigger-specific test asserts refusal without checking its reason.

**Read, no additional findings:** `CatalogCommit.swift`, `CatalogRepository.swift`, `CatalogQueries.swift`, `ArchiveView+Categories.swift`, `CatalogCommitReplacementTests.swift`, `CatalogRescanRefusedReplacementTests.swift`, and `ArchiveTimelineCompletenessSensorTests.swift`. The Archive predicate correctly retains an active offline source as representative and substitutes the copy when its source becomes inactive.

No files written. Supplied green results were not rerun; billing credits are not exposed to this session.

## Brief

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

## Closure (bug-fix agent, 2026-10-22 night): fixed in `3197ef431`, on top of `f59f6d841`

**Root cause of F1–F3:** the replacement was *inferred* by matching paths. The scan merge already knows which old id each fresh record replaces, so the relation is now carried explicitly. Every swap door names it:

- both scan merges (`VideoScanModel+ScanMerge.swift`, via `replacementRelation`);
- `placeRecord`'s inherit and uncurated-swap paths (`VideoScanModel+CatalogPurge.swift`).

The relation travels `purgeCatalogRows(replacedBy:)` → `CatalogCommitter.purge(replacements:)` → `CatalogCommit.Plan.replacements` (purged id → replacement id). In `CatalogCommitBody`, every purge a record replaces, plus ALL of that record's snapshots, commit in ONE savepoint. The purges stand only when the record ends up stored (written, partial or unchanged) or held in `pending_rows`. When the record is not in the commit, they stand only if the store already holds it. The new door `CatalogTransaction.storedRecordPresent(id:)` checks for a live `files` row or an un-purged pending row, and replaces `storedLivePath`. A purge with no relation is a plain removal ("gone from disk", Delete All) and runs alone, as before. No path matching remains; a source pin forbids it.

Files beyond the brief's list: `VideoScanModel+ScanMerge.swift` and `VideoScanModel+CatalogPurge.swift`, the doors that state the relation.

| # | Finding | Status | Pinning test (red at `f59f6d841`, green at `3197ef431`) |
|---|---|---|---|
| F1 | A pending predecessor bypasses protection | **Fixed.** A pending predecessor is purged inside the group's savepoint, so its `pending_purges` tombstone rolls back with a refused replacement. | `CatalogCommitRelationTests.pendingPredecessorKept` |
| F2 | Case folding binds a purge to the wrong file | **Fixed.** No path matching at all. A case-variant sibling never satisfies another row's purge. | `CatalogCommitRelationTests.caseSensitiveSiblingDoesNotSatisfyThePurge` (a real case-sensitive volume) |
| F3 | Repeated replacement snapshots disable protection | **Fixed.** All snapshots of the record join its group, in plan order (gap 2 preserved). The old row is kept unless one of them stores the record. | `…repeatedSnapshotsKeepTheOldRow`; control `…oneOfTwoSnapshotsLanding` |
| F4 | Forgetting the kept purge blocks a corrected replacement | **Fixed.** The committer keeps the purge request WITH its relation. `duePurges` sends it only when the replacement is sent in the same commit, or once the store holds it; it is never sent alone. The relation is void if a door removes the replacement itself. | `CatalogKeptPurgeRetryTests.correctedReplacementCompletesThePair`. Red at f59: the corrected B was refused with "files rows are never replaced (id or live path already taken)". Plus source pin `…swapDoorsNameTheirReplacement`. |
| Tests | The real incident shape was not pinned; the trigger test did not check the reason | **Fixed.** | `CatalogCommitRelationTests.incidentShapeLosesNothing`: one generation with 100 writes, 100 holds and 100 REAL `archive_copies_need_source` refusals, no injected trigger. Zero paths lost or doubled; exactly 100 kept purges, each naming "an archive copy names its source". `CatalogCommitReplacementTests.archiveCopyWithoutStoredSourceKeepsOldRow` now asserts the same reason. |

**Codex's unnumbered note** ("different-path replacements are indistinguishable from disappearance"): **addressed by the explicit relation.** A replacement at another path purges its predecessor only when it is stored. Renames and moves the merge detects keep the OLD instance (`applyMoveAdoptions`), so no purge happens for them.

**Known residual, declined here, a separate decision:**
- **A replacement removed from memory without a door's purge.** The kept old row stays live and its purge request stays pending in the session. This is conservative: the row is kept. A relaunch reloads it.
- **Re-created import-era copies.** `replaceArchiveCopy` still refuses them, now safely (`NOT REMOVED`). That needs a provenance decision.

**Evidence:**
- Core: `swift test --filter CatalogCommit`, 53 tests in 9 suites, green.
- App (Debug, `-only-testing`): 121 tests in 14 suites, green. They include RescanPreservation, ScanMerge×3, cutover purge/pending/committer/sync, and both P0 end-to-end tests.
- Sensor lane: app 537 passed, 1 failed (the known flaky `FamilyTreeCardInvalidationSensorTests.catalogPublishesDoNotRebuildTheTreeCards`); core 17/17.
