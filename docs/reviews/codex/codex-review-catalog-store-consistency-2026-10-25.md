# Codex review — Catalog SQLite store consistency audit

- Range: `17485b1fe..42bcb9b91`
- Credits spent: unavailable
- Tokens: 525007
- Finding count: 6
- Verdict: block — saved edits can be lost, and the writer does not provide the configured durability guarantee.
- Run: 2026-10-26T01:08:10Z (cycle #141, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 6  
Verdict: block — saved edits can be lost, and the writer does not provide the configured durability guarantee.

Reviewed the module at `42bcb9b91`. The checkout advanced to `dd1a6735` during review, but the scoped files remained unchanged. No files were changed and no tests were run. Regression tests below are **proposed RED tests**, not executed results.

**1. P1 — GRDB resets the archival writer to `synchronous=NORMAL`.**

Location: [GRDBCatalogRepository.swift:276](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:276).

The configuration callback sets `synchronous=FULL`, but `DatabasePool` subsequently enables WAL on its writer. The pinned GRDB 7.11.1 implementation then executes `PRAGMA synchronous=NORMAL`: [Database.swift:531](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/.build/checkouts/GRDB.swift/GRDB/Core/Database.swift:531).

Consequently, the archival **writer** uses NORMAL while its readers report FULL. The existing pragma test misses this because [pragmas():1048](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:1048) queries `pool.read`.

Reproduction: open an archival repository and query `PRAGMA synchronous` inside its write closure. It reports `1`, not `2`. An acknowledged commit followed by power loss before WAL synchronization can lose that commit. `fullfsync=1` does not make NORMAL synchronize every commit. This is a durability failure; it does **not** demonstrate a partially applied SQL transaction after process-only SIGKILL.

Proposed Store test, using `StoreTestSupport.swift`:

```swift
@Test func archivalWriterUsesFullSynchronization() async throws {
    let fixture = try await StoreFixture.make(
        .grdb, generation: 0, durability: .archival)
    defer { fixture.remove() }

    let repository = GRDBCatalogRepository(
        host: "writer-pragmas", durability: .archival)
    try #require(await repository.open(at: fixture.url) == .readWrite)

    _ = await repository.write(as: .ui) { transaction in
        let tx = try #require(transaction as? GRDBTransaction)
        #expect(try Int.fetchOne(
            tx.db, sql: "PRAGMA synchronous") == 2)
    }

    await repository.close()
}
```

Restore and verify the writer’s durability setting **after pool initialization, before migration or other writes**.

**2. P1 — Reopen accepts a newer generation without refreshing stale records, allowing committed changes to be overwritten.**

Location: [CatalogCommitter.swift:508](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:508).

Reopen loads the database’s current generation, clears the blocked state, and schedules another commit. It retains the old records and baselines. The repository also resets its generation expectation when opening.

Concrete interleaving:

1. A loads generation `g`, including a record with no footage decision.
2. B opens a second repository on the same database and commits a footage decision at `g+1`.
3. A edits that record’s note during its debounce window or a write hold.
4. A’s first save correctly fails the generation check.
5. A invokes **Reopen SQLite Catalog**. Its expected generation becomes `g+1`; its record still lacks B’s decision.
6. The retry compares A’s stale record with the current database. [CatalogRecordDiff.swift:51](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogRecordDiff.swift:51) treats the missing decision as an edit, and [GRDBCatalogRepository+Live.swift:165](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift:165) deletes B’s decision.
7. Generation `g+2` commits successfully. Relaunch preserves the loss.

The same mechanism can restore stale file metadata. `restrictShared` protects untouched shared curated fields; it does not protect the file or footage-decision portions of the snapshot.

Proposed app regression using `CutoverScene`: commit B’s decision through a second repository, dirty A’s note, assert A’s initial save fails, reopen A, save, then reload. Assert **both** A’s note and B’s decision survive. Parameterize the edit timing for debounce and write hold.

Reopen needs reconciliation against the newly loaded database before it can safely accept retained edits. Resetting only the generation defeats the protection provided by the initial CAS refusal.

**3. P1 — A scoped save advances a dirty sibling’s baseline and converts another copy’s addition into a later deletion.**

Location: [CatalogCommitBaseline.swift:269](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/CatalogCommitBaseline.swift:269), especially line 280.

When a sibling has local edits, propagation correctly leaves its current value alone—but unconditionally replaces its baseline with the committed value.

Reproduction with two records sharing one whole-file digest:

| Step | Copy A | Copy B | B’s baseline | Stored tags |
|---|---|---|---|---|
| Initially | `{base}` | `{base}` | `{base}` | `{base}` |
| Both edited | `{base,a}` | `{base,b}` | `{base}` | `{base}` |
| Save A only | `{base,a}` | `{base,b}` | **`{base,a}`** | `{base,a}` |
| Save B | — | `{base,b}` | — | **`{base,b}`** |

B’s next delta removes `a`, although B never removed—or even received—it. The scoped door is real: `commitNow(ids:)` is used for removal markers and pre-replacement saves.

Proposed regression in the app’s existing cutover tests:

```swift
@Test @MainActor
func scopedSavePreservesBothCopiesTagAdditions() async throws {
    let scene = try CutoverScene.make("scoped_tag_deltas")
    defer { scene.cleanup() }
    try await scene.launchOnSQLite()

    let a = try scene.record(.curatedConflictA)
    let b = try scene.record(.curatedConflictB)
    let committer = try scene.committer()

    a.tags = ["base"]
    b.tags = ["base"]
    try #require(committer.commitNow())

    a.tags = ["base", "a"]
    b.tags = ["base", "b"]
    try #require(committer.commitNow(ids: [a.id]))
    try #require(committer.commitNow())

    let loaded = try await scene.reloaded(.curatedConflictA)
    #expect(Set(loaded.tags) == Set(["base", "a", "b"]))
    await committer.repository.close()
}
```

The same baseline mechanism serves people and backup-attestation sets. Preserve the dirty sibling’s original baseline, or explicitly rebase its pending delta when propagating committed changes.

**4. P2 — Clearing the last curated value causes the next load to restore imported values.**

Location: [GRDBCatalogRepository+Display.swift:21](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Display.swift:21).

The “one-time” display pass uses **all curated display tables being empty** as its completion test. Clearing a scalar deletes its display row. On the next load, [CatalogLoad.swift:96](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Load/CatalogLoad.swift:96) rebuilds empty tables from immutable `knowledge_sources`, ignoring the subsequent live clear.

Reproduction:

1. Import a catalog whose only curated value is one note.
2. Load it, populating `user_notes`.
3. Clear the note and commit successfully.
4. Close and reopen.
5. The display pass restores the original imported note.

This requires **all** the enumerated curated display tables to be empty; clearing one note in an otherwise populated catalog does not trigger it. The source is SQLite import evidence, not the accepted frozen `catalog.json` fallback exception.

Proposed Store regression: use `StoreFixture`, seed one file and one imported `.userNotes` knowledge source, run the display pass, clear through `CatalogCommit`, then reopen and load. Assert the note remains empty and no `user_notes` row reappears.

Use a persistent completion marker rather than table emptiness.

**5. P2 — Live media-ledger events do not commit atomically with catalog mutations.**

Locations: [CatalogCommitBody.swift:299](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/CatalogCommitBody.swift:299), [GRDBCatalogRepository+Writes.swift:385](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+Writes.swift:385).

The SQL ledger insertion path is an import path: it forces `imported=1` and is called by the sidecar importer. Live catalog commits do not insert the corresponding media-ledger events.

Following the date-edit caller establishes the split:

- [InspectorDateView.swift:272](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Catalog/InspectorDateView.swift:272) schedules the debounced catalog save, then immediately requests a ledger append.
- [VideoScanModel+MediaLedger.swift:84](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Archive/VideoScanModel+MediaLedger.swift:84) sends the event to the independent JSONL worker.
- [MediaLedger.swift:402](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/Archive/MediaLedger.swift:402) writes and fsyncs that file independently.

Reproduction: edit a date, allow the JSONL append to finish, then kill before the catalog debounce fires. The durable ledger records the new date while SQLite retains the old one. Even a successful ordinary save does not create the corresponding live SQL ledger row.

This contradicts [migration design §9.7:203](/Users/rickb/dev/VideoScan/docs/design/catalog_sqlite_migration_2026_10_16.md:203), which requires the ledger entry and catalog mutation in the same SQL transaction, with JSONL retained as an export.

Proposed regression: record the existing SQL ledger count for a fixture record, edit its date through the app hook, await the append task, and save. Assert exactly one new matching SQL `dateSet` event exists. Add a crash variant asserting no event claims a catalog mutation that failed to commit.

**6. P2 — A newer-schema database is modified before it is refused.**

Location: [GRDBCatalogRepository.swift:174](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository.swift:174).

The read/write pool is constructed before `checkSchemaVersion`. Pool construction changes journal mode to WAL and can create/drop GRDB’s initialization table before VideoScan checks whether the file is newer.

Reproduction using `StoreFixture`:

1. Create and close a current fixture.
2. Through a test `DatabaseQueue`, set both schema versions to `13`, switch to `journal_mode=DELETE`, and close.
3. Capture the database bytes.
4. Call `repository.open`.
5. Assert it refuses version 13, then compare bytes.

The refusal occurs, but the database has already been changed to WAL. This is a violation of **“refused, never written to”**, not evidence of schema downgrade.

Proposed RED assertion: after the refusal and close, `Data(contentsOf: fixture.url)` must equal the captured bytes. Perform version admission through a read-only connection before creating a writable pool.

Other invariant results:

- **Writer exclusion:** `CatalogFileGuard` checks file identities and latches; it is not a `flock` writer lock. Ordinary competing commits rely on SQLite serialization and generation CAS. Finding 2 identifies where that protection is defeated.
- **SQL crash atomicity:** I found no statement sequence splitting files, knowledge, relations and generation history across successful SQL commits. High-water publication deliberately precedes SQL commit. Findings 1 and 5 concern durability and the external ledger boundary.
- **Migration:** migrations are transactional and resumable per migration. No half-applied migration or migration-induced version mismatch was found. Finding 6 concerns admission before migration.
- **Foreign keys:** the GRDB read/write and `openForReading` configurations enable them. This review does not certify external script connection initialization; `?mode=ro` alone does not establish that pragma.
- **Deletion:** no path was found deleting a `files` record. Pending-row removal follows successful promotion within the transactional path. The duplicate-membership cascade does not delete file records. Finding 2 does expose deletion of a current footage decision.
- **Identity:** no sampled-hash leak into digest-keyed user tables was found. Imported ledger `content_key` remains verbatim evidence; its digest binding comes from the record’s whole-file identity. No case-insensitive path-alias duplication path was found.
- **Trigger premise:** the stated archived-name/date and rejected-value vetoes are not SQL triggers in this schema. I cannot certify them as migration-preserved SQL protections; I did not establish a separate application-level bypass.
- **Rule 8:** findings 2–3 cover retained edits during holds/debounce; finding 4 supplies a relaunch failure. No separate role-flip failure was established: `CatalogSync.mode` is immutable for the instance, and `onWritableAgain` explicitly leaves viewer status intact.

For the Swift 6 escape hatches, these are the claimed invariants and review results:

| Site | Claimed protection; result |
|---|---|
| `CatalogChangeDetector.swift:59` | Disjoint buffer slots; synchronous `concurrentPerform` joins before buffer expiry. No violating call found. |
| `CatalogFileGuard.swift:82` | Test override dictionary protected by its lock. No unlocked access found. |
| `CatalogFileGuard.swift:328` | Close-note state protected by its lock. No violating call found. |
| `CatalogPreflightReader.swift:146` | Interrupt/close coordinated by lock and closed flag; callback lifetime bounded by registration. No violating call found. |
| `GRDBCatalogRepository.swift:1161` | Write-gate state copied under lock; database access uses GRDB serialization. No violating call found. |
| `GRDBCatalogRepository.swift:1188` | Session state locked; generation operations occur within serialized writing. No isolation violation found; finding 2 is a logical reconciliation failure. |
| `CatalogCommit.swift:213` | Commit-result accumulator locked. No violating call found. |
| `CatalogAuthorityFlip.swift:176` | Result box locked, completion synchronized. No violating call found. |

The test-only escape hatches were also read: the lock-backed boxes protect their mutable state; external-writer handles and the hard-kill child are used in ordered lifetimes; the unlocked decision-test result box is read after the awaited write. No concrete race was found. No scoped `assumeIsolated` or `@preconcurrency` site was found.

File coverage follows. References to findings include supporting code; they do not add to the finding count. The Store directory contains **29**, rather than 28, Swift files.

`VideoScan/VideoScanCore/Sources/VideoScanCore/Store/`

```text
CatalogBookkeepingSchema.swift           — read, no findings
CatalogCommitB22Schema.swift             — read, no findings
CatalogDataSchema.swift                  — read, no findings
CatalogDataSchema+Import.swift           — read, no findings
CatalogDataSchema+Knowledge.swift        — read, no findings
CatalogDataSchema+Relations.swift        — read, no findings
CatalogDecisionRows.swift                — read, no findings
CatalogDecisionTablesSchema.swift        — read, no findings
CatalogFileGuard.swift                   — read, no findings
CatalogFolderKindSchema.swift            — read, no findings
CatalogFolderRows.swift                  — read, no findings
CatalogHighWater.swift                   — read, no findings
CatalogHighWaterLedger.swift             — read, no findings
CatalogLiveWritesSchema.swift            — read, no findings
CatalogPendingRowsSchema.swift           — read, no findings
CatalogPreflightReader.swift             — read, no findings
CatalogRepository.swift                  — read, no findings
CatalogRow.swift                         — read, no findings
CatalogRow+Live.swift                    — read, no findings
GRDBCatalogRepository.swift              — read; findings 1, 2, 6
GRDBCatalogRepository+Decisions.swift    — read, no findings
GRDBCatalogRepository+Display.swift      — read; finding 4
GRDBCatalogRepository+Folders.swift      — read, no findings
GRDBCatalogRepository+Live.swift         — read; findings 2, 4
GRDBCatalogRepository+LiveDerived.swift  — read, no findings
GRDBCatalogRepository+LivePending.swift  — read; finding 3
GRDBCatalogRepository+Load.swift         — read, no findings
GRDBCatalogRepository+Reads.swift        — read, no findings
GRDBCatalogRepository+Writes.swift       — read; finding 5
```

`VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/`

```text
CatalogCommit.swift                     — read, no findings
CatalogCommitBody.swift                 — read; findings 2, 3, 5
CatalogCommitConflicts.swift            — read, no findings
CatalogCommit+Copies.swift              — read, no findings
CatalogChangeDetector.swift             — read, no findings
CatalogRecordDiff.swift                 — read; finding 2
CatalogSetDelta.swift                   — read, no findings
CatalogSharedCurated.swift              — read, no findings
CatalogPendingRecord.swift              — read, no findings
HashingEncoder.swift                    — read, no findings
```

`VideoScan/VideoScan/Catalog/`

```text
CatalogCommitter.swift                  — read; finding 2
CatalogCommitBaseline.swift             — read; finding 3
CatalogWriteError.swift                 — read, no findings
CatalogSync.swift                       — read, no findings
CatalogAuthorityFlip.swift              — read, no findings
```

`docs/design/`

```text
catalog_sqlite_migration_2026_10_16.md    — read, no findings
catalog_contract_freeze_2026_10_17.md    — read, no findings
catalog_sqlite_schema_v1.sql            — read, no findings
catalog_sqlite_schema_v1_checks.sql     — read, no findings
integrity_first_2026_10_16.md            — read, no findings
```

`VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/`

```text
CatalogCloseCheckpointTests.swift          — read, no findings
CatalogCommitArchiveProvenanceTests.swift  — read, no findings
CatalogCommitB21Tests.swift                — read, no findings
CatalogCommitB24Tests.swift                — read, no findings
CatalogCommitB25Tests.swift                — read, no findings
CatalogCommitB26Tests.swift                — read, no findings
CatalogCommitRelationTests.swift           — read, no findings
CatalogCommitReplacementTests.swift        — read, no findings
CatalogCommitTests.swift                   — read, no findings
CatalogDataSchemaScaleTests.swift          — read, no findings
CatalogDataSchemaTests.swift               — read, no findings
CatalogDecisionTablesTests.swift           — read, no findings
CatalogDiskFullTests.swift                 — read, no findings
CatalogFileGuardCodex117Tests.swift         — read, no findings
CatalogFileGuardQAR1Tests.swift             — read, no findings
CatalogFileGuardQAR2Tests.swift             — read, no findings
CatalogFolderDoorsTests.swift              — read, no findings
CatalogHardKillTests.swift                 — read, no findings
CatalogLoadReadingTests.swift              — read, no findings
CatalogOpenCornerTests.swift               — read, no findings
CatalogPreflightMeasureTests.swift         — read, no findings
CatalogPreflightReaderQAR1Tests.swift       — read, no findings
CatalogPreflightReaderQAR2Tests.swift       — read, no findings
CatalogPreflightReaderTests.swift          — read, no findings
CatalogReadBackPlanTests.swift             — read, no findings
CatalogRepositoryContractTests.swift       — read, no findings
CatalogRepositoryScaleTests.swift          — read, no findings
CatalogStoreSensorTests.swift              — read, no findings
CatalogTransactionDoorsTests.swift         — read, no findings
CatalogWriteCornerDiskTests.swift          — read, no findings
GRDBCatalogRepositoryLedgerTests.swift     — read, no findings
GRDBCatalogRepositoryTests.swift           — read; finding 1's reader-only assertion
SchemaDocument.swift                      — read, no findings
StoreTestSupport.swift                     — read, no findings
```

`VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Commit/`

```text
CatalogChangeDetectorTests.swift           — read, no findings
CatalogCommitScaleTests.swift              — read, no findings
```

Necessary scope extensions were limited to the load/mapping and import callers, the app’s reopen and date-edit/ledger call chains, existing app regression fixtures, and the pinned GRDB initialization implementation. Those reads establish findings 1, 2, 4–6 and the identity result; no unrelated repository exploration or implementation work was performed.

## Brief

# Codex review brief — Catalog SQLite store: consistency audit after the Swift 6 flip (module review, not a diff review)

**Workflow in one sentence (Rick's words):** "make sure the SQLite database is rock solid, make sure the catalog is entirely consistent" — the catalog (`catalog.sqlite`, GRDB, schema v12) is the one truth for ~16,000 family-video records; a row is never deleted; identity is the whole-file SHA-256; every write goes through one commit door.

**Range:** `17485b1fe..42bcb9b91` (context only — the whole module is in scope, at `42bcb9b91`) on branch `overnight/2026-10-25` · **Checkout:** `/Users/rickb/dev/VideoScan` (read-only for you). The app and Core are in **Swift 6 language mode** since this morning (`docs/design/swift6_migration_2026_10_25.md`); opt-outs carry a `// Swift 6:` invariant comment — treat every one you meet as a claim to attack.

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/` — all 28 files: `CatalogDataSchema*.swift` (DDL, triggers, FKs), `CatalogCommitB22Schema.swift`, `CatalogBookkeepingSchema.swift`, `CatalogDecisionTablesSchema.swift` (v12, `versionBump`), `CatalogFolderKindSchema.swift`, `CatalogLiveWritesSchema.swift`, `CatalogPendingRowsSchema.swift`, `CatalogFileGuard.swift`, `CatalogPreflightReader.swift`, `CatalogHighWater*.swift`, `CatalogRepository.swift`, `GRDBCatalogRepository*.swift` (open, migrate, load, reads, writes, live, derived, pending, folders, decisions, display)
- `VideoScan/VideoScanCore/Sources/VideoScanCore/Commit/` — `CatalogCommit.swift`, `CatalogCommitBody.swift`, `CatalogCommitConflicts.swift`, `CatalogCommit+Copies.swift`, `CatalogChangeDetector.swift`, `CatalogRecordDiff.swift`, `CatalogSetDelta.swift`, `CatalogSharedCurated.swift`, `CatalogPendingRecord.swift`, `HashingEncoder.swift`
- The app-side door: `VideoScan/VideoScan/Catalog/CatalogCommitter.swift`, `CatalogCommitBaseline.swift`, `CatalogWriteError.swift`, `CatalogSync.swift`, `CatalogAuthorityFlip.swift`
- Design promises: `docs/design/catalog_sqlite_migration_2026_10_16.md`, `docs/design/catalog_contract_freeze_2026_10_17.md`, `docs/design/catalog_sqlite_schema_v1.sql`, `catalog_sqlite_schema_v1_checks.sql`, `docs/design/integrity_first_2026_10_16.md`
- Existing tests to read, not to re-run: `VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/` (DiskFull, HardKill, OpenCorner, WriteCornerDisk, CloseCheckpoint, TransactionDoors, FileGuard*, PreflightReader*, Repository*, DataSchema*), `Commit/`

**Invariants to attack** (one line each):
1. **One committer, no lost write.** Two writers (a second process, or a second connection inside the app — `CatalogFileGuard` flock + GRDB pool) can never interleave so that a committed row, a user field keyed by digest, or a decision row is silently overwritten by a stale snapshot. Show the interleaving (write hold, debounce window, role flip, relaunch — rule 8's four cases).
2. **Crash atomicity.** A hard kill at any statement of a commit (WAL on? synchronous level? checkpoint on close?) leaves a database that reopens with `PRAGMA integrity_check = ok`, `foreign_key_check` empty, `user_version == catalog_state.schema_version`, and either the whole commit or none of it. Show a statement sequence that is not atomic across tables (files → knowledge → relations → ledger → high-water).
3. **Migration safety.** v1 → v12 on an old file is idempotent and cannot half-apply; a NEWER file (v13) is refused, never downgraded or written to; `PRAGMA foreign_keys` is ON on every connection including the read-only `?mode=ro` door scripts use; triggers (rejected-value veto, immutable archived names/dates) survive migration.
4. **Rows are never deleted.** Find any `DELETE FROM` on a record-bearing table, any `ON DELETE CASCADE`, any purge that is not a marker, any path where a `pending_rows` record (no whole-file hash yet) can be dropped before it becomes a `files` row.
5. **Identity.** A `files` row's digest is whole-file SHA-256; a sampled/segmented hash never keys a user field, a decision, or a ledger `contentKey` (`MediaLedgerEvent.swift:191` says the ledger's may be sampled — show where that leaks into a digest-keyed table); case-insensitive path aliases cannot create two rows for one file.
6. **Swift 6 isolation.** Every `nonisolated(unsafe)`, `@unchecked Sendable`, `assumeIsolated`, `@preconcurrency` in scope: state the invariant its comment claims and show a call that breaks it (a `DatabasePool` shared across actors, a cached statement reused across connections, a `Date`/formatter shared).

**Evidence already run:** Store + Commit suites green nightly (Core 1,872 / 0 on 10/24; Swift 6 flip Core green today); sensor lane GREEN 570; Codex stage 5–7 and stage 8 reviews (merge, 0 findings) covered the Swift 6 *diffs* only — this review is the module as it stands.

**Known and accepted (do not report):** `catalog.json` is frozen and never read as a fallback; `files.catalogued_at` is never back-filled; bulky derived data (sound prints) lives in a sidecar DB by ruling; scripts read `?mode=ro` only (sensor test_no_script_writes_catalog.py).

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible (Swift Testing, against `StoreTestSupport.swift` helpers). For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
