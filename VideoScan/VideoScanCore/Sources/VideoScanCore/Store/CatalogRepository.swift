// CatalogRepository.swift (VideoScanCore/Store)
// The SEAM between the catalog's domain and whatever stores it. Step C′
// part 1 of docs/design/catalog_sqlite_migration_2026_10_16.md §10a.
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
// Part 2 adds the record methods (files, content, knowledge) to
// CatalogTransaction / CatalogReader. This part carries only the
// bookkeeping that every later method rides on: open, generation, the
// one-transaction write with its compare-and-set, read, verify, adopt,
// close.
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
// concrete classes, each with an implicit mutex around its members.

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

/// Thrown by `read` when the repository is not open. Everything else a
/// repository can say is an outcome value, not an error.
public enum CatalogRepositoryError: Error, Equatable {
    case notOpen
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

/// The handle a `read` body receives. Part 2 adds the record queries.
public protocol CatalogReader {
    /// The committed generation this read's snapshot was taken at.
    var generation: Int { get }
}

/// The handle a `write` body receives. Part 2 adds the record mutations.
public protocol CatalogTransaction {
    /// The generation this write advances TO (the committed one plus one).
    /// Rows written in this transaction are stamped with it.
    var generation: Int { get }
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
