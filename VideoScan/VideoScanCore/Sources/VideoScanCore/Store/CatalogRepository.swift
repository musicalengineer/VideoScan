// CatalogRepository.swift (VideoScanCore/Store)
// The SEAM between the catalog's domain and whatever stores it. Step C′
// part 1 of docs/design/catalog_sqlite_migration_2026_10_16.md §10a; part
// 2b adds the record doors the importer writes through and the readings
// the comparator checks.
//
// Rick's ruling (2026-10-17): the database is a PLUGIN behind a protocol.
// Nothing above this layer may name a GRDB or SQLite type, so this file
// imports Foundation only, and CatalogStoreSensorTests fails if
// `import GRDB` appears outside Sources/VideoScanCore/Store/.
//
// Implementations:
//   - GRDBCatalogRepository  — SQLite through GRDB (the authority since 10/18)
//   (JSONCatalogRepository, the read-only catalog.json stub that kept the
//   seam honest during the import, was retired 2026-10-20 — JSON gone.)
//
// Part 2b (2026-10-17): `CatalogTransaction` gains one door per table row
// the importer writes — each one row per call, each raw SQL on the GRDB
// side (Rick reviews SQL). `CatalogRecordReading` holds the readings the
// comparator needs; BOTH the reader handle and the transaction handle
// refine it, because the comparator runs INSIDE the import transaction
// (contract §f: any miss rolls the import back) and a separate reader
// connection could not see the uncommitted rows. Readings stream through a
// visitor closure — no O(records) array where a cursor will do.
//
// THREADING RULE. Every method is safe to call from any task or actor.
// Writes are serialised by the store: one at a time, in call order. The
// `body` closures run on the store's own queue, so they must be `@Sendable`,
// must not call back into the repository (that is a deadlock, not a
// nested transaction), and must not capture state that the caller mutates
// concurrently. Reads run on reader connections and see one consistent
// snapshot each; they never block a writer.
//
// For Rick: a protocol with `async` requirements is an abstract base class
// whose virtual methods may suspend. The conforming `actor` types are the
// concrete classes, each with an implicit mutex around its members. A
// visitor closure (`(Row) throws -> Void`) is a callback per row — the
// cursor stays inside the store.

import Foundation

// MARK: - Outcomes (one case per thing that can happen; callers switch without `default:`)

/// What `open(at:)` did. `.readOnly` means the store opened and can be read
/// but refuses writes until a person acts (its reason says what to do).
public enum CatalogOpenOutcome: Sendable, Equatable {
    case readWrite
    case readOnly(reason: String)
    case refused(reason: String)
}

/// What one `write` did. `.committed` carries the generation the catalog is
/// now at. `.generationMismatch` is the compare-and-set saying no: this
/// session's idea of the generation (`expected`) is not what the database
/// holds (`found`) — another writer got there first. Nothing was changed
/// in either non-committed case.
public enum CatalogWriteOutcome: Sendable, Equatable {
    case committed(generation: Int)
    case refused(reason: String)
    case generationMismatch(expected: Int, found: Int)
}

/// What `verify()` found. `highWater` is the external high-water mark the
/// store answers to (for the JSON store, its own sidecar, or the generation
/// when none exists).
public enum CatalogVerifyOutcome: Sendable, Equatable {
    case ok(generation: Int, highWater: Int)
    case problems([String])
}

/// What `adopt(toHighWater:)` did. Adoption is a person's act: it raises a
/// restored (older) database to the high-water this Mac already wrote, in
/// one step, with its own history row.
public enum CatalogAdoptOutcome: Sendable, Equatable {
    case adopted(from: Int, to: Int)
    case refused(reason: String)
}

/// Thrown by `read` when the repository is not open, and by a store that
/// has no table to answer a record reading from (the JSON store: it is the
/// import SOURCE, nothing was ever imported into it). Everything else a
/// repository can say is an outcome value, not an error.
public enum CatalogRepositoryError: Error, Equatable {
    case notOpen
    case unsupported(String)
}

// MARK: - The doors a write comes through

/// Who is writing — stored verbatim in `generation_history.writer` so the
/// audit trail names the feature, not the thread. The DDL calls this "the
/// door". `adopt` is deliberately absent: only `adopt(toHighWater:)` writes
/// that row kind.
public enum CatalogWriter: String, Sendable {
    case create
    case importRun = "import"
    case rescan
    case promote
    case audit
    case ui
    /// A one-time pass that derives stored values from stored evidence
    /// (cutover B1: the display tables filled from knowledge_sources).
    case migrate
    // Cutover B2: the app's three save funnels, each its own door, so the
    // history says which one committed (generation_history.writer, and
    // `row_knowledge.source` = "app:<door>").
    /// `saveCatalogDebounced` — the 2 s coalesced commit.
    case save
    /// `saveCatalogNow` — the synchronous commit (quit, Delete All).
    case quit
    /// `saveCatalogAcknowledged` — a commit the caller awaits.
    case acknowledged
    /// "Switch Catalog to SQLite…": the Master Archive designation moved
    /// from catalog.json into `catalog_state`.
    case cutover
}

// MARK: - What a body sees

/// The readings the import comparator checks (contract §f "Comparator"),
/// each keyed by the import run and streamed in storage order. Shared by
/// the reader handle and the transaction handle so the comparator can run
/// inside the import's own transaction.
public protocol CatalogRecordReading {
    /// How many rows the record tables hold (the importer refuses a non-empty target).
    func recordCounts() throws -> CatalogRow.TableCounts
    /// Every catalog.json occurrence of `run` and the table row it landed in.
    func rowLandings(run: String, _ visit: (CatalogRow.RowLanding) throws -> Void) throws
    /// `quarantine.raw_row` by ordinal for `run`.
    func quarantineRawRows(run: String, _ visit: (Int, [String: CatalogJSONValue]) throws -> Void) throws
    /// Every quarantine row of `run` with its reason and words (the import report).
    func quarantineEntries(run: String, _ visit: (CatalogRow.QuarantineReading) throws -> Void) throws
    /// Every `content.digest`.
    func contentDigests(_ visit: (String) throws -> Void) throws
    /// Every `knowledge_sources` row of `run`: ordinal, field, value.
    func knowledgeSources(run: String, _ visit: (CatalogRow.KnowledgeReading) throws -> Void) throws
    /// Every `derived_unverified` key of `run`.
    func derivedUnverifiedKeys(run: String, _ visit: (CatalogRow.DerivedKeyReading) throws -> Void) throws
    /// Every `sound_prints.digest`.
    func soundPrintDigests(_ visit: (String) throws -> Void) throws
    // The sidecar rows, read back WHOLE (fix 2026-10-17, codex D′ #3): the
    // comparator compares the row it would write from its own decode with
    // the row that is there — payloads, not ordinals.
    /// Every `events` row of `run`.
    func events(run: String, _ visit: (CatalogRow.Event) throws -> Void) throws
    /// Every `event_decisions` row of `run`, payload decoded.
    func eventDecisions(run: String, _ visit: (CatalogRow.EventDecision) throws -> Void) throws
    /// Every `event_members` row: the resolved digest and range, with the key it came from.
    func eventMembers(_ visit: (CatalogRow.EventMemberReading) throws -> Void) throws
    /// Member keys kept unresolved: the decision stream's keys and `legacy_pair_ids.event_member_keys`.
    func listedMemberKeys(run: String, _ visit: (String) throws -> Void) throws
    /// Every `ledger` row of `run`, payload decoded.
    func ledgerLines(run: String, _ visit: (CatalogRow.Ledger) throws -> Void) throws
    /// Every `ignored_content` row of `run`.
    func ignoredEntries(run: String, _ visit: (CatalogRow.Ignored) throws -> Void) throws
    /// Every `job_markers` row of `run` with the hash of the file it came from.
    func jobMarkers(run: String, _ visit: (CatalogRow.MarkerReading) throws -> Void) throws
    /// Every `audit_results` row of `run`, whole.
    func auditResults(run: String, _ visit: (CatalogRow.AuditResult) throws -> Void) throws
    func personSearchOrdinals(run: String, _ visit: (Int) throws -> Void) throws
    /// The counts of the reconciliation line, read from the rows (contract §f).
    func importReconciliation(run: String) throws -> ImportReconciliation
}

/// The readings a LOAD needs (cutover B1, catalog_cutover_f_prime §2): every
/// `files` row as a `CatalogLoadedRow` (domain values; the SQL stays in
/// Store/), the counts Catalog Status shows beside the records, and the
/// display pass's inputs.
public protocol CatalogLoadReading {
    /// Every `files` row (live and tombstoned), ordered by (digest, id),
    /// streamed — quarantine rows are never records.
    func loadedRows(_ visit: (CatalogLoadedRow) throws -> Void) throws
    func loadCounts() throws -> CatalogLoadCounts
    /// `import_runs` rows that finished with the comparator's word (the
    /// launch rule's evidence that the import is whole, §7).
    func finishedImports() throws -> Int
    /// True while no curated display row has been written.
    func displayTablesEmpty() throws -> Bool
    /// Every curated `knowledge_sources` occurrence that hangs on a digest.
    func displaySources(_ visit: (DisplayValueDerivation.Source) throws -> Void) throws
}

/// What a live commit reads back before it writes (cutover B2): one `files`
/// row exactly as a load would give it, the volume's case rule, and the
/// catalog-level Master Archive designation.
public protocol CatalogLiveReading {
    /// The `files` row `id` with everything a record needs (nil when absent).
    func storedRow(id: String) throws -> CatalogLoadedRow?
    /// `volumes.case_sensitive` (false when the volume is not there yet).
    func volumeCaseSensitive(_ volumeUUID: String) throws -> Bool
    /// `catalog_state.master_archive`, verbatim JSON text; nil when none.
    func masterArchiveJSON() throws -> String?
    /// The newest finished, comparator-ok import (nil when none).
    func lastFinishedImport() throws -> CatalogRow.FinishedImport?
    // Cutover B2.1 (v1.8)
    /// Every `pending_rows` row (new records waiting for a whole-file digest), by id.
    func pendingRows(_ visit: (CatalogRow.PendingRow) throws -> Void) throws
    /// The revisions of `fileID`'s tombstones, ascending.
    func tombstoneRevisions(fileID: String) throws -> [Int]
}

/// The handle a `read` body receives.
public protocol CatalogReader: CatalogRecordReading, CatalogLoadReading, CatalogLiveReading, CatalogFolderReading,
                               CatalogDecisionReading {
    /// The committed generation this read's snapshot was taken at.
    var generation: Int { get }
}

/// The handle a `write` body receives: one door per table row, each ONE
/// row per call, plain INSERT (never REPLACE: a duplicate is a finding).
/// The store's DDL — not the door — refuses a row that breaks a constraint;
/// the thrown error carries the engine's words and the write rolls back.
/// Catalog folders (v1.10, CatalogFolderRows.swift) and Rick's decision
/// tables (v1.11, CatalogDecisionRows.swift): their readings and doors ride
/// on the same transaction.
public protocol CatalogTransaction: CatalogRecordReading, CatalogLiveReading, CatalogFolderWriting, CatalogDecisionWriting {
    /// The generation this write advances TO (the committed one plus one).
    /// Rows written in this transaction are stamped with it.
    var generation: Int { get }

    // The occurrence's own rows (CatalogRecordDTO)
    func insertVolume(_ volume: CatalogRecordDTO.VolumeRowDTO, caseSensitive: Bool) throws
    func insertContent(_ content: CatalogRecordDTO.ContentRow) throws
    func insertFile(_ file: CatalogRecordDTO.FileRow, volumeCaseSensitive: Bool) throws
    func insertTombstone(_ tombstone: CatalogRow.Tombstone) throws
    func insertArchiveCopy(fileID: String, _ copy: CatalogRecordDTO.ArchiveCopyRow, sourceFileID: String?) throws
    func insertBackupDestination(fileID: String, _ destination: CatalogRecordDTO.BackupDestinationRow) throws

    // Knowledge and derived evidence
    func insertKnowledgeSource(_ source: CatalogRow.KnowledgeSource) throws
    /// False when the same (digest, kind, seq, source row) key is already there.
    func insertDerivedUnverified(_ derived: CatalogRow.DerivedUnverified) throws -> Bool
    /// The one BOUND derived value an import carries (§e.8). False when the digest already has a print.
    func insertSoundPrint(_ print: CatalogRecordDTO.SoundPrintRow) throws -> Bool
    func insertRegenContext(_ context: CatalogRow.RegenContext) throws
    func insertLegacyPairIDs(_ pair: CatalogRow.LegacyPairIDs) throws
    func insertRelation(_ relation: CatalogRow.Relation) throws -> CatalogRow.RelationLanding

    // Quarantine and the import map
    /// Returns the `quarantine.qid` the row received.
    func insertQuarantine(_ row: CatalogRow.Quarantine) throws -> Int64
    func insertImportRun(_ run: CatalogRow.ImportRun) throws
    /// The one UPDATE that closes a run; the DDL's finish trigger recounts every counter.
    func finishImportRun(_ runID: String, counters: CatalogRow.ImportCounters, finishedAt: Int64) throws
    func insertImportItem(_ item: CatalogRow.ImportItem) throws

    // Sidecars
    func insertEvent(_ event: CatalogRow.Event) throws
    func insertEventDecision(_ decision: CatalogRow.EventDecision) throws
    func insertIgnored(_ entry: CatalogRow.Ignored) throws
    func insertLedgerLine(_ line: CatalogRow.Ledger) throws
    func insertJobMarker(_ marker: CatalogRow.JobMarker) throws
    func appendAuditResult(_ result: CatalogRow.AuditResult) throws
    func insertPersonSearch(_ search: CatalogRow.PersonSearch) throws

    // The display pass (cutover B1): re-checked and filled inside one write.
    func displayTablesEmpty() throws -> Bool
    func insertDisplayRows(_ rows: DisplayValueDerivation.Rows) throws

    // Live writes (cutover B2, GRDBCatalogRepository+Live.swift). Unlike the
    // import doors these REPLACE what one row (or one content) owns: a
    // commit writes the record's current state. The DDL still refuses what
    // must be refused (a digest change, a live-path collision, a marker
    // change without its tombstone) with the engine's words.
    /// Run `body` in a SAVEPOINT: a throw undoes only `body`'s writes and
    /// is rethrown, so one refused row does not undo its neighbours.
    func inSavepoint(_ body: () throws -> Void) throws
    /// INSERT the volume, or refresh its names (never its case rule, F12).
    func upsertVolume(_ volume: CatalogRecordDTO.VolumeRowDTO) throws
    /// INSERT the content row unless the digest is already there.
    func ensureContent(_ content: CatalogRecordDTO.ContentRow) throws
    /// UPDATE every mutable column of an existing `files` row; the removal
    /// marker only when `markerChanged` (its tombstone must already be in);
    /// the audit stamp last, after the path trigger has run.
    func updateFile(_ file: CatalogRecordDTO.FileRow, markerChanged: Bool) throws
    /// The row's archive copy as `copy` says (nil = none).
    func replaceArchiveCopy(fileID: String, _ copy: CatalogRecordDTO.ArchiveCopyRow?) throws
    func replaceBackupDestinations(fileID: String, _ rows: [CatalogRecordDTO.BackupDestinationRow]) throws
    func replaceFootageDecisions(rowID: String, digest: String, _ rows: [CatalogRecordDTO.FootageDecisionRow]) throws
    /// Duplicate analysis is rebuildable: a member the DDL cannot hold is
    /// left out and named in the returned words.
    func replaceDuplicateMember(fileID: String, _ member: CatalogRecordDTO.DuplicateMemberRow?) throws -> String?
    func replaceSoundPrint(digest: String, _ print: CatalogRecordDTO.SoundPrintRow?) throws
    /// The content's SCALAR display row for `field` from `curated`,
    /// `conflict = 0` (a person's write resolves a conflict for that
    /// content). The sets (tags, people, attestations) are never written
    /// here: only as a copy's delta (`write…Delta`, cutover B2.4).
    func writeDisplayValue(digest: String, field: CatalogDDL.KnowledgeField,
                           _ curated: CatalogRecordDTO.CuratedKnowledge, setAt: Int64) throws
    /// The content's scalar display row for `field` as an unresolved
    /// conflict: `conflict = 1`, no value (B2.3, regression F2 — two copies
    /// changed it differently in one commit). Set fields: nothing to do.
    func writeDisplayConflict(digest: String, field: CatalogDDL.KnowledgeField) throws
    func appendRowKnowledge(_ row: CatalogRow.RowKnowledge) throws
    /// The content's BOUND rows of one derived kind replaced by `rows`
    /// (empty = none bound). The unverified evidence is never touched.
    func replaceDerived(digest: String, kind: CatalogDDL.DerivedKind, _ rows: [CatalogRecordDTO.DerivedValueRow]) throws
    /// `catalog_state.master_archive` (JSON text, nil = none).
    func setMasterArchive(json: String?) throws

    // Cutover B2.1 (v1.8, GRDBCatalogRepository+LivePending.swift)
    /// Hold a new record with no whole-file digest: its encoded payload.
    /// False when the same id already holds exactly `json` (nothing written).
    func putPendingRow(_ row: CatalogRow.PendingRow) throws -> Bool
    /// The record became a `files` row (or was purged): drop its pending
    /// row. False when there was none.
    func removePendingRow(id: String) throws -> Bool
    /// The record left the app's catalog: the purge marker on its `files`
    /// row (tombstone first; never a DELETE), or its pending row dropped.
    func purgeFile(id: String, since: Int64, writtenAt: Int64, door: String) throws -> CatalogRow.PurgeLanding
    /// True when the store holds record `id`: a LIVE `files` row, or a
    /// `pending_rows` payload that is not purged. Two indexed reads. A
    /// purge whose replacement is not in this commit lands only when this
    /// says yes (P0 2026-10-22, codex #123).
    func storedRecordPresent(id: String) throws -> Bool
    /// The people a person changed on one copy, as a delta on the content's
    /// display rows: `removed` rows deleted only where name, kind AND
    /// confirmed_at all match (the exact row the copy saw — B2.6), `added` rows
    /// written with `conflict = 0` — a name the person set resolves that
    /// name's conflict (its other-kind conflict row goes); every other name,
    /// conflicts included, is left exactly as it was.
    func writePeopleDelta(digest: String, added: [CatalogRecordDTO.PeopleTagRow],
                          removed: [CatalogRecordDTO.PeopleTagRow]) throws

    // Cutover B2.4 (GRDBCatalogRepository+LivePending.swift)
    /// The tags a person changed on one copy, as a delta on the content's
    /// set: `removed` tags deleted, `added` tags inserted; every other tag —
    /// another copy's addition in the same commit included — left as it was.
    func writeTagsDelta(digest: String, added: [String], removed: [String]) throws
    /// The backup attestations a person changed on one copy, as a delta:
    /// `removed` deleted only where the WHOLE row matches (kind, time,
    /// answer, who AND label — B2.5: a relabel by another copy survives a
    /// removal of the old label), `added` written settled (`conflict = 0`);
    /// every other attestation left as it was.
    func writeAttestationsDelta(digest: String, added: [CatalogRecordDTO.BackupAttestationRow],
                                removed: [CatalogRecordDTO.BackupAttestationRow]) throws
}

// MARK: - The seam

public protocol CatalogRepository: Sendable {

    /// Open the store at `url` (the database file, or catalog.json for the
    /// JSON store). Runs every check that can say no BEFORE anything is
    /// written. Opening an already-open repository is refused.
    func open(at url: URL) async -> CatalogOpenOutcome

    /// The same, refused with GH #354's words unless catalog.cutover is
    /// beside `url` (QA r1 D, #359): the app's launch and Reopen use it, so
    /// a session without the latch can never write.
    func open(at url: URL, requiringLatch: Bool) async -> CatalogOpenOutcome

    /// The generation this session last loaded or committed — the
    /// compare-and-set expectation for the next write. 0 before `open`.
    var generation: Int { get async }

    /// ONE transaction: `body` runs, the generation advances by exactly one
    /// (a compare-and-set against `generation`), a `generation_history` row
    /// names the new generation, and the external high-water is raised
    /// BEFORE the commit (two-phase, contract F8). Any throw from `body`
    /// rolls the whole thing back and is reported as `.refused`.
    func write(as door: CatalogWriter,
               _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome

    /// The SAME transaction as `write`, run on the CALLING thread, which
    /// waits for the store's writer (cutover B2.2). Only the app's
    /// CatalogCommitter calls it, and only from the main actor: its commit is
    /// one synchronous turn — snapshot, write, baseline — so no record can
    /// change while a commit runs. Everything else uses `write`.
    /// (For Rick: a blocking call into the writer thread, like a
    /// `std::future::get()` right after the `async` — on purpose.)
    func writeBlocking(as door: CatalogWriter,
                       _ body: (any CatalogTransaction) throws -> Void) -> CatalogWriteOutcome

    /// One consistent snapshot. Throws `CatalogRepositoryError.notOpen`
    /// or whatever `body` throws.
    func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T

    /// The engine's own checks plus the bookkeeping invariants. Costs
    /// O(database size) — a Verify Catalog tier, not something to run on
    /// every save.
    func verify() async -> CatalogVerifyOutcome

    /// Adopt a restored database: jump its generation to `highWater` (which
    /// must be what the external mark says) with an `adopt` history row,
    /// then allow writes again.
    func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome

    /// Release the store. Safe to call twice.
    func close() async

    /// A sealed, self-contained copy of the store at `target`, on the
    /// calling thread (cutover B2.3): the pre-change safety copy a door
    /// takes before removing records. nil = written; else the words.
    func sealedCopyBlocking(to target: URL) -> String?

    /// GH #359: the words when the store's file (or its latch) is no longer
    /// the file this session opened — nothing more may be saved until the
    /// app quits and reopens; nil while it is the same file. Synchronous,
    /// any thread. A Reopen in-session would open the REPLACEMENT, so the
    /// committer refuses it while this is non-nil.
    var fileStopWords: String? { get }

    /// What the last `close()` said that a person must see (GH #359 QA r2-2:
    /// the -wal quarantine's START / OUTCOME lines). The app logs them
    /// through its one sink after it closes the store; empty otherwise.
    var lastCloseNotes: [String] { get }

    /// codex #117 F3: after a quit's close timed out — quarantine this
    /// session's -wal / -shm ONLY if catalog.sqlite is confirmed not its file.
    func quarantineAfterTimedOutClose() -> CatalogTimedOutClose
}

extension CatalogRepository {
    /// A store with no sealed-copy door says so (the JSON repository; test fakes).
    public func sealedCopyBlocking(to target: URL) -> String? {
        "this catalog store cannot make a sealed copy"
    }

    /// A store with no file guard never stops for a moved file (test fakes).
    public var fileStopWords: String? { nil }

    /// A store that never quarantines has nothing to say at close (test fakes).
    public var lastCloseNotes: [String] { [] }

    /// A store with no file guard has nothing to quarantine (test fakes).
    public func quarantineAfterTimedOutClose() -> CatalogTimedOutClose { .notOpen }

    /// A store with no latch notion opens as `open(at:)` does (test fakes).
    public func open(at url: URL, requiringLatch: Bool) async -> CatalogOpenOutcome {
        await open(at: url)
    }
}
