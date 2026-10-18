# Codex review — Cutover B2.1 closing pass

- Range: `3f6e17025..efab05ed8`
- Credits spent: unavailable (metering not exposed)
- Tokens: 94261
- Finding count: 4
- Verdict: block** — at `efab05ed8`, two prior defects remain and two new P1 defects can lose accepted edits.
- Run: 2026-10-18T02:37:14Z (cycle #101, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (metering not exposed) | Finding count: 4

Verdict: **block** — at `efab05ed8`, two prior defects remain and two new P1 defects can lose accepted edits.

Original seven findings:

1. **CLOSED — stale dirty sibling.** Per-record curated baselines restrict writes to edited fields: [CatalogCommitBody.swift:142](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:142).
2. **OPEN — propagation still suppresses concurrent edits.** [CatalogCommitBaseline.swift:244](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:244) advances baselines through historical shares. **Reproduction:** same-content records ordered A,B; snapshot notes A=`one`, B=`two`; during commit edit B=`one`. SQLite ends at `two`, but propagation sets B’s baseline to `one`. The next save suppresses B’s accepted edit, reports success, and relaunch restores `two`.
3. **CLOSED — overlapping quit/acknowledged commits.** Every door drains and absorbs the previous flight before snapshotting: [CatalogCommitter.swift:168](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:168), [:224](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:224).
4. **CLOSED — Switch misses pending edits.** Initial flush precedes import; the final pending-save check and freeze share one main-actor turn: [CatalogSwitchToSQLite.swift:219](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:219), [:239](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:239).
5. **CLOSED — stale designation.** Designation and SHA come from identical bytes: [CatalogSwitchToSQLite.swift:162](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogSwitchToSQLite.swift:162).
6. **CLOSED — unrelated people edit clears conflicts.** Delta writes preserve untouched names: [GRDBCatalogRepository+LivePending.swift:80](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:80).
7. **CLOSED — rejected derived write advances baseline.** Partial results remain dirty and report failure: [CatalogCommitBaseline.swift:164](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:164).

Original ranked gaps:

1. **CLOSED — digestless rows lack durable retention.** Payload persistence exists at [CatalogCommitBody.swift:111](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:111); subsequent failed edits have the new defect below.
2. **OPEN — missing intermediate marker revisions.** [CatalogCommitBaseline.swift:73](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:73) drops snapshots before a new row’s first baseline exists. **Reproduction:** start its revision-0 insert, Trash→Undo during that flight, then save again: only revision 2 remains; SQLite requires revision 1 and refuses subsequent saves. Pending-to-files promotion has the same boundary.
3. **OPEN — closure unverified within scope.** The direct-save sensor’s allowlist exists at [CatalogCutoverB21Tests.swift:317](/Users/rickb/dev/VideoScan/VideoScanTests/CatalogCutoverB21Tests.swift:317), but its migrated callers are outside the permitted files.
4. **CLOSED — unrelated hold owner bypass.** Owner identity is compared at [CatalogCommitter.swift:318](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:318).
5. **CLOSED — intentionally purged IDs resurrect.** Missing IDs are detected and purged rows excluded on load: [CatalogCommitBaseline.swift:102](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:102), [CatalogLoad.swift:74](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Load/CatalogLoad.swift:74).

Two new **P1** findings:

- **An old pending payload falsely certifies a newer edit.** [CatalogCommitBaseline.swift:174](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:174), [:108](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:108). **Failure:** persist a digestless row, reject its next pending UPDATE, edit notes; first save fails, but the next quit-save skips the failed fingerprint and returns true because the old `held` flag remains; relaunch restores old notes.
- **Marker replay loses a curated reversion.** [CatalogCommitter.swift:366](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:366), [CatalogCommitBody.swift:142](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:142). **Failure:** persisted note A→edit B→Trash→edit A→Undo→save; both snapshots use baseline A, so revision 1 writes B and revision 2 suppresses A; save succeeds with B stored.

Pending-ID collision insertion is guarded; files insertion and pending deletion share a savepoint/transaction, so a crash between them does not expose half-promotion.

Rescan under a new ID creates churn. If a save observes temporary absence, it hides the old files row and **deletes a held row’s sole payload** ([LivePending.swift:58](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+LivePending.swift:58)). Caller fencing is outside scope, so loss-freedom is unproven. Synchronous 1,000-row marker mutations coalesce; throughput across yields lacks a scoped regression test.

**The requested durability guarantee is refuted.** Besides these defects, the two-second debounce leaves accepted edits volatile before commit; a crash needs no “Quit and lose N” answer.

Other reviewed scoped files/tests: **read, no independent findings**. No files written; tests not executed under the no-files constraint.

## Brief

# Codex brief: cutover B2.1 — closing pass on the SQLite write side (2026-10-18 night; data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~800 words.

**Your B2 pass:** `docs/reviews/codex/codex-review-cutover-b2-write-side-switch-door-2026-10-17.md` (block: 6 P1 + 1 P2 + 5 ranked gaps). **The fix:** range `3f6e17025..efab05ed8` on main (merges: the import quit-path fence `069d59586`, the store close checkpoint `35edc1e18`-ish, B2.1 `7cb1420fc` + sensor allowlist). Files under `VideoScan/`: Core `VideoScanCore/Sources/VideoScanCore/Commit/*` (CatalogSharedCurated, CatalogPendingRecord, CatalogCommit, CatalogCommitBody, CatalogRecordDiff, CatalogChangeDetector), `Store/GRDBCatalogRepository+LivePending.swift`, `Store/CatalogPendingRowsSchema.swift`, `Store/GRDBCatalogRepository.swift` (close checkpoint), `Load/CatalogLoad.swift`; app `VideoScan/Catalog/CatalogCommitter.swift`, `Catalog/CatalogCommitBaseline.swift`, `Catalog/CatalogMarkerRelay.swift`, `Catalog/CatalogSwitchToSQLite.swift`, `Catalog/CatalogAdoptSQLite.swift`, `Catalog/SQLiteCatalogLoader.swift`, `MediaOps/VideoScanModel+RemovalMarker.swift`, `MediaOps/FullHashBackfillScoped.swift`; tests `VideoScanTests/CatalogCutoverWriteSideTests.swift`, the new app suites (CatalogPendingRows, CatalogMarkerRevision, CatalogPurgeMarker, CatalogDirectSaveSensor, CatalogAdopt) and Core `Tests/VideoScanCoreTests/Commit/*`.

**Do only this:** (1) for each of your 7 findings and the 5 ranked gaps: CLOSED (file:line) or OPEN (why). (2) at most THREE new P1 findings the fix introduced, each with file:line and a one-line failure scenario — focus on: the pending_rows path (a held row that also gets edited; a pending id colliding with a files id; a crash between the files insert and the pending delete), the per-revision marker snapshots (ordering; a Trash of 1,000 rows), the purge path (a record removed from memory by a rescan that will re-add it under a new id — churn or loss?), the Switch flush+freeze in one turn. Confirm or refute: after the flip, an edit accepted by the app is never lost on quit, crash, or relaunch, except by an explicit 'Quit and lose N' answer.

**Do not explore outside the files listed above and their tests.**
