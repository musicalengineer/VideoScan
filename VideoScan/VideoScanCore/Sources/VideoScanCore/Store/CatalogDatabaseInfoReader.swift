// CatalogDatabaseInfoReader.swift (VideoScanCore/Store)
// Catalog ▸ Catalog Database Info… (Rick 2026-11-01, BACKLOG "Catalog ▸
// Catalog Info"): the facts about the catalog DATABASE itself, read from the
// file at the moment the sheet opens — never from a field the app keeps
// (hard rule 1). Lives in Store/ because only Store/ may import GRDB
// (CatalogStoreSensorTests); the app sees plain Swift values.
//
// One short-lived READ-ONLY connection (`CatalogPreflightReader.openReadOnly`:
// SQLITE_OPEN_READONLY, no migration, no write, no high-water), closed before
// returning. A WAL reader sees the last commit and never blocks the app's
// writer. The one file it may create is the EMPTY `-wal` of a WAL-mode
// catalog whose read-write last closer removed it (#386, create-only) — the
// same as the launch preflight; the sizes are stat'ed BEFORE the open, so
// the sheet reports the folder as it found it.
//
// Every fact is a `CatalogDatabaseReading`: `.known(value)` or
// `.unknown(why)` — a missing table, an empty singleton, an unopenable file
// each give their own words, never a zero or a blank.
//
// Cost (all indexed or one-row reads): user_version, the singleton rows and
// the sqlite_master table list are O(1) in records (never integrity_check); the newest generation_history row is a primary-key seek;
// `count(*)` on `files` / `content` walks the smallest covering b-tree
// (SQLite keeps no row count) — measured in CatalogDatabaseInfoReaderTests
// at 100k rows, inside its budget. Memory: SQLite's page cache for one
// connection (default ≈ 2 MB), freed at close; the result is a few Ints and
// strings.
//
// (For Rick: an enum of statics ≈ a C++ namespace of free functions;
// `Sendable` structs ≈ plain-old-data safe to hand to another thread.)

import Foundation
import GRDB

/// One fact read from the database: the value, or why it is not known.
public enum CatalogDatabaseReading<Value: Sendable & Equatable>: Sendable, Equatable {
    case known(Value)
    case unknown(String)

    public var value: Value? {
        if case .known(let v) = self { return v }
        return nil
    }
}

/// The newest `generation_history` row: which commit door wrote last, and when.
public struct CatalogLastCommit: Sendable, Equatable {
    public var generation: Int
    public var committedAt: Date
    public var host: String
    /// `generation_history.writer` — the door (`CatalogWriter.rawValue`: save, quit, ui, …).
    public var writer: String
    /// `commit` or `adopt`.
    public var kind: String

    public init(generation: Int, committedAt: Date, host: String, writer: String, kind: String) {
        self.generation = generation
        self.committedAt = committedAt
        self.host = host
        self.writer = writer
        self.kind = kind
    }
}

/// The live file's table list against the tables this build's migrations
/// create (`GRDBCatalogRepository.expectedTableNames`).
public struct CatalogSchemaLayout: Sendable, Equatable {
    /// Tables in the file (`sqlite_*` internals left out).
    public var tableCount: Int
    /// In the file, not created by this build — sorted.
    public var extra: [String]
    /// Created by this build, not in the file — sorted.
    public var missing: [String]

    public var matches: Bool { extra.isEmpty && missing.isEmpty }

    public init(tableCount: Int, extra: [String], missing: [String]) {
        self.tableCount = tableCount
        self.extra = extra
        self.missing = missing
    }

    /// Pure: the diff of two table sets.
    public static func compare(live: Set<String>, expected: Set<String>) -> CatalogSchemaLayout {
        CatalogSchemaLayout(tableCount: live.count, extra: live.subtracting(expected).sorted(),
                            missing: expected.subtracting(live).sorted())
    }
}

/// What the read found inside catalog.sqlite.
public struct CatalogDatabaseFacts: Sendable, Equatable {
    /// `PRAGMA user_version`.
    public var userVersion: CatalogDatabaseReading<Int>
    /// `catalog_state.schema_version` (singleton 1).
    public var schemaVersion: CatalogDatabaseReading<Int>
    /// The file's tables against this build's (sqlite_master; no integrity_check).
    public var schemaLayout: CatalogDatabaseReading<CatalogSchemaLayout>
    /// `generations.generation` (id 1) — the committed generation.
    public var generation: CatalogDatabaseReading<Int>
    /// `count(*) FROM content` — one row per whole-file digest.
    public var contents: CatalogDatabaseReading<Int>
    /// `count(*) FROM files WHERE removal_state IS NULL`.
    public var liveFiles: CatalogDatabaseReading<Int>
    /// `count(*) FROM files` — every record, live and removed (rows are never deleted).
    public var records: CatalogDatabaseReading<Int>
    /// The newest `generation_history` row.
    public var lastCommit: CatalogDatabaseReading<CatalogLastCommit>

    public init(userVersion: CatalogDatabaseReading<Int>, schemaVersion: CatalogDatabaseReading<Int>,
                schemaLayout: CatalogDatabaseReading<CatalogSchemaLayout>, generation: CatalogDatabaseReading<Int>, contents: CatalogDatabaseReading<Int>,
                liveFiles: CatalogDatabaseReading<Int>, records: CatalogDatabaseReading<Int>,
                lastCommit: CatalogDatabaseReading<CatalogLastCommit>) {
        self.userVersion = userVersion
        self.schemaVersion = schemaVersion
        self.schemaLayout = schemaLayout
        self.generation = generation
        self.contents = contents
        self.liveFiles = liveFiles
        self.records = records
        self.lastCommit = lastCommit
    }

    /// Every fact unknown for the same reason (the file could not be opened).
    public static func allUnknown(_ why: String) -> CatalogDatabaseFacts {
        CatalogDatabaseFacts(userVersion: .unknown(why), schemaVersion: .unknown(why),
                             schemaLayout: .unknown(why), generation: .unknown(why),
                             contents: .unknown(why), liveFiles: .unknown(why), records: .unknown(why),
                             lastCommit: .unknown(why))
    }
}

public enum CatalogDatabaseInfoReader {

    /// The `catalog_state.schema_version` this build migrates to (the sheet
    /// says when the file differs).
    public static var expectedSchemaVersion: Int { GRDBCatalogRepository.currentSchemaVersion }

    /// Read every fact from the file at `databaseURL`. Never throws, never
    /// writes a row; safe off the main actor and beside the open catalog.
    public static func read(at databaseURL: URL) -> CatalogDatabaseFacts {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .allUnknown("no file at \(databaseURL.path)")
        }
        let queue: DatabaseQueue
        do {
            queue = try CatalogPreflightReader.openReadOnly(databaseURL, label: "catalog-database-info")
        } catch {
            return .allUnknown("the file could not be opened read-only: \(error)")
        }
        defer { try? queue.close() }
        do {
            return try queue.read { db in facts(db) }
        } catch {
            return .allUnknown("the file could not be read: \(error)")
        }
    }

    /// Each question on its own: one failing never hides the others.
    static func facts(_ db: Database) -> CatalogDatabaseFacts {
        let filesWhy = tableMissing(db, "files")
        return CatalogDatabaseFacts(
            userVersion: reading { try Int.fetchOne(db, sql: "PRAGMA user_version") },
            schemaVersion: tableMissing(db, "catalog_state").map { .unknown($0) } ?? reading(
                empty: "catalog_state has no row (singleton 1) — no schema_version was ever stored") {
                    try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1")
                },
            schemaLayout: layout(db),
            generation: tableMissing(db, "generations").map { .unknown($0) } ?? reading(
                empty: "generations has no row (id 1) — the counter was never started") {
                    try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1")
                },
            contents: tableMissing(db, "content").map { .unknown($0) } ?? reading {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM content")
            },
            liveFiles: filesWhy.map { .unknown($0) } ?? reading {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM files WHERE removal_state IS NULL")
            },
            records: filesWhy.map { .unknown($0) } ?? reading {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM files")
            },
            lastCommit: tableMissing(db, "generation_history").map { .unknown($0) } ?? reading(
                empty: "generation_history has no rows — nothing was ever committed") {
                    try Row.fetchOne(db, sql: """
                        SELECT generation, committed_at, host, writer, kind
                          FROM generation_history ORDER BY generation DESC LIMIT 1
                        """).map { row in
                        CatalogLastCommit(generation: row[0], committedAt: Date(timeIntervalSince1970: TimeInterval(row[1] as Int64)),
                                          host: row[2], writer: row[3], kind: row[4])
                    }
                })
    }

    /// sqlite_master's tables against this build's. Deliberately NOT
    /// `PRAGMA integrity_check` (seconds on a 315 MB file — Validate
    /// Catalog's job, not a sheet's): one read of the schema table.
    static func layout(_ db: Database, expected: Set<String>? = GRDBCatalogRepository.expectedTableNames) -> CatalogDatabaseReading<CatalogSchemaLayout> {
        guard let expected else { return .unknown("this build's own table list could not be built") }
        return reading {
            let live = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"))
            return CatalogSchemaLayout.compare(live: live, expected: expected)
        }
    }

    /// nil when `table` exists; otherwise the words.
    private static func tableMissing(_ db: Database, _ table: String) -> String? {
        do {
            return try db.tableExists(table) ? nil : "the file has no \(table) table"
        } catch {
            return "the schema could not be read: \(error)"
        }
    }

    private static func reading<T>(empty: String = "the query returned no row",
                                   _ body: () throws -> T?) -> CatalogDatabaseReading<T> {
        do {
            guard let value = try body() else { return .unknown(empty) }
            return .known(value)
        } catch {
            return .unknown("the query failed: \(error)")
        }
    }
}
