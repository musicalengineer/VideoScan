# Codex review — P0 purge relation verify

- Range: `f59f6d841..3197ef431`
- Credits spent: unavailable
- Tokens: 52154
- Finding count: 3
- Verdict: fix — a plan-level row-loss variant and a stranded retry relation remain.
- Run: 2026-10-23T14:34:32Z (cycle #125, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — a plan-level row-loss variant and a stranded retry relation remain.

1. **P1 — Successful snapshots do not prove the replacement finishes live.** [CatalogCommitBody.swift:168](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a8bd550582aa69e8e/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:168) accepts any `.written`, `.partial`, or `.unchanged` result without checking final presence.

   **Failure scenario:** A is live; plan A→B supplies B’s live snapshot followed by its valid revision-1 `removedFromCatalog`/`purged` snapshot. Both writes succeed, so A’s purge stands although B also finishes purged. The file remains on disk. An already-purged B supplied as an unchanged snapshot has the same problem.

   **Fix:** Require `storedRecordPresent(B)` after all group snapshots, including successful ones. Add both cases as behavioral tests. This is a source-derived plan reproduction, not an executed UI reproduction.

2. **P2 — Another rescan strands a kept purge; explicit removal also fails to release it.** [CatalogCommitter.swift:423](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a8bd550582aa69e8e/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:423) filters through `baseline.holds` before processing replacement relations.

   **Failure scenario:** A→B is refused; a subsequent rescan explicitly swaps unstored B→C. B fails that filter, leaving A tied to absent B. `duePurges` never sends A with C, whose hashed insert can then collide with A’s live path. If a complete scan instead proves B’s file gone, its explicit purge is likewise ignored and A remains indefinitely in-session. This differs from the declared exclusion: the door **does request the purge**.

   **Fix:** Reconcile incoming relations before filtering stored IDs: retarget A→C for B→C; release A’s dependency for a genuine removal of B. Report unresolved dependencies. Extend the retry test using a fresh C UUID.

3. **P2 — The mixed incident test would not fail the previous design.** [CatalogCommitRelationTests.swift:172](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a8bd550582aa69e8e/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogCommitRelationTests.swift:172) creates hashed live predecessors at unique paths, each with one replacement snapshot.

   **Failure scenario:** Adapt the API call to `f59f6d841`: its path pairing matches all 300 replacements correctly and already rolls back the 100 refused pairs.

   **Fix:** Include pending predecessors or repeated refused snapshots within that mixed generation. Assert 100 written and 100 held outcomes separately. The current test does request that mix and verifies 100 genuine source-provenance refusals without installing an injected trigger.

The original F1–F3 cases are closed; F4’s same-ID retry is closed, with finding 2 remaining. All four scoped swap doors supply relations. Ordinary unrelated purges remain independent. Failed full-hash promotion preserves the pending payload through rollback. Reopen/adopt retain retry maps; baseline adoption clears both together. Broader relaunch/cutover plumbing remains outside this scope.

**Read, no additional findings:** `CatalogCommit.swift`, `CatalogRepository.swift`, `GRDBCatalogRepository+LivePending.swift`, `VideoScanModel+CatalogPurge.swift`, `VideoScanModel+ScanMerge.swift`, `CatalogCommitReplacementTests.swift`, and `CatalogKeptPurgeRetryTests.swift`.

Reviewed `3197ef431` against `f59f6d841`. No files written; tests were not rerun because they create build/database artifacts. Supplied green results were not independently reproduced.

## Brief

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

## Closure

Fixes in `868c8d2ae` (branch `worktree-agent-a8bd550582aa69e8e`, on top of `4c7810861`). Debug throughout.

| Finding | Status | Pinning test | Red at 3197ef431 | Green at 868c8d2ae |
|---|---|---|---|---|
| 1 P1 — successful snapshots do not prove the replacement ends live | Fixed: `CatalogCommitBody.replace` asks the store (`storedRecordPresent`) AFTER all of the group's snapshots; if the record is not there (or carries the purge marker) the group is undone, the old row stays `keptForReplacement`, and the undone snapshots are reported refused so the app keeps them changed | `CatalogCommitRelationTests.replacementPurgedLaterInTheGroupKeepsTheOldRow` (live snapshot then purge snapshot) · `…alreadyPurgedReplacementUnchangedKeepsTheOldRow` (already-purged B sent unchanged) | red: 5 + 2 issues (path lost, A purged) | green |
| 1 (control) — the predicate must not over-refuse | `storedRecordPresent` now means "a `files` row without the purge marker, or an un-purged pending row". A replacement In the Trash / missing / removed by a person is still the file's row (a rescan's fresh record inherits the marker), so its purge stands | `CatalogCommitRelationTests.replacementEndingInTrashLetsThePurgeStand` | n/a (new contract); red by mutation with the old `removal_state IS NULL` predicate (3 issues) | green |
| 2 P2 — a kept purge strands on a re-swap / never releases on removal | Fixed: `CatalogCommitter.purge` reconciles kept relations over EVERY id the door names before the stored-id filter (`reconcileKept`). B→C retargets A→C, so A goes with C. B removed outright (no relation) RELEASES A: its relation and its purge request are dropped, A is **not** purged on B's account, stays live, and catalog.log says `KEPT <A> …`; it is then also named once as a record that left memory without a purge, and after a reload its own evidence decides it. A replacement gone from memory without a door's purge (the declared case) is now named once (`noteUnresolved`) | `CatalogKeptPurgeRetryTests.keptPurgeFollowsTheNextReplacement` (fresh C UUID) · `…removedReplacementReleasesTheKeptRow` | red: C refused at A's live path (A still at the path); no release line | green |
| 3 P2 — the incident test could not fail the path-paired design | Fixed: the mixed generation now has pending predecessors (half of each group) and two snapshots of every refused replacement; it asserts 100 `.written`, 100 held (`.deferred` + `heldPending`), 200 refused rows (100 records) with the trigger's reason, 100 kept, 100 `.purged(revision: 1)` and 100 `.pendingPurged` separately | `CatalogCommitRelationTests.incidentShapeLosesNothing` | red **by mutation**: `replacementGroups` temporarily skipped (a) a purged id with no `files` row and (b) a replacement sent more than once — exactly f59f6d841's blind spots — and ran those purges as plain: **100 paths lost**, 5 issues. The previous version of the test PASSED under the same mutation. Mutation reverted before commit | green |

Choice on finding 2's release: a released A stays live. The relation said "A is replaced by B", not "A's file is gone"; the complete scan proved only B's path empty, and Rick's invariant allows an old row to go only beside a stored replacement. A dead row kept and named is recoverable; a purged live file's row is the P0.

Runs (all Debug):
- Core `swift test --filter CatalogCommit`: 56 tests in 9 suites, green (was 53; +3).
- App `xcodebuild test -only-testing` (22 suites: CatalogCommit*/Committer*, CatalogPurge*, CatalogExplicitPurge, AdvUndoPurgeWhileHeld, CatalogMarkerVeto, SwallowedTrashThenPurgeSensor, RescanPreservation, ScanMerge* ×5, CatalogKeptPurgeRetry, CatalogRescanRefusedReplacement): 154 tests, green. Red run before the committer fix: CatalogKeptPurgeRetryTests, 4 tests, 2 failed (the two new ones).
- `scripts/run_sensors.sh`: sensor lane GREEN (555 tests).

Residual, declined:
- A released A (finding 2) stays in catalog.sqlite until a relaunch reloads it and a later scan decides it on its own evidence. In-session it is named, not acted on. Conservative by design.
- An already-refused B whose snapshots are undone under finding 1 waits at its fingerprint (as any refused row does) until it changes; its rows say why.
