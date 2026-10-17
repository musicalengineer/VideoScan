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
// Two implementations exist from day one so the seam is real, not a
// wrapper around one engine:
//   - GRDBCatalogRepository  — SQLite through GRDB (the future authority)
//   - JSONCatalogRepository  — the existing catalog.json, read-only (the
//                              import source; it is never written here)
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

/// The handle a `read` body receives.
public protocol CatalogReader: CatalogRecordReading {
    /// The committed generation this read's snapshot was taken at.
    var generation: Int { get }
}

/// The handle a `write` body receives: one door per table row, each ONE
/// row per call, plain INSERT (never REPLACE: a duplicate is a finding).
/// The store's DDL — not the door — refuses a row that breaks a constraint;
/// the thrown error carries the engine's words and the write rolls back.
public protocol CatalogTransaction: CatalogRecordReading {
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
}

// MARK: - The seam

public protocol CatalogRepository: Sendable {

    /// Open the store at `url` (the database file, or catalog.json for the
    /// JSON store). Runs every check that can say no BEFORE anything is
    /// written. Opening an already-open repository is refused.
    func open(at url: URL) async -> CatalogOpenOutcome

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
}
