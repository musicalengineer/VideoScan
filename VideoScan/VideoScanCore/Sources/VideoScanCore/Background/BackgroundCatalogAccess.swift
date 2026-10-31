// BackgroundCatalogAccess.swift — VideoScanCore/Background
//
// The helper's ONLY door to catalog.sqlite, and it opens one way: READ.
// Hard rule 6 says one committer; the design (§0.2, §3.6) says the service
// never writes the catalog and a sensor proves it. This type is that proof
// at the type level: `openFlags` is a constant — SQLITE_OPEN_READONLY — there
// is no parameter, no second initializer and no `execute`, so read-write
// cannot be EXPRESSED here, let alone reached. BackgroundServiceSensorTests
// pins the flags in source and the handle at runtime (sqlite3_db_readonly).
//
// Plain SQLite3, not GRDB: Store/ owns GRDB (CatalogStoreSensorTests) and
// the writer; this door borrows nothing from the writer's class so the
// helper binary carries none of it. The one file it may create is the EMPTY
// `-wal` of a WAL-mode catalog whose read-write last closer removed it
// (#386, SQLiteWALSidecar — create-only, never a rewrite), the same as the
// preflight reader.
//
// Memory: one SQLite connection, default page cache (≈ 2 MB), freed at close.
// `strings(_:)` collects at most `maxRows` text cells.
//
// C++ reading: an RAII handle whose constructor is private and whose only
// factory hard-codes the read-only flag.

import Foundation
import SQLite3

public final class BackgroundCatalogAccess: @unchecked Sendable {

    /// The one way this type can open: read-only, serialized threading.
    public static let openFlags: Int32 = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

    public static let readOnlyWords = "VideoScan Background opens the catalog for reading only; it never writes it (the app's one committer does)"

    /// Rows a single `strings` query may return (a bounded answer, not a dump).
    public static let maxRows = 10_000

    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    private init(url: URL, db: OpaquePointer) {
        self.url = url
        self.db = db
    }

    /// Open `url` read-only. A missing file, a missing `-wal` that cannot
    /// be created, or an engine error is a `Refusal` in words.
    public static func open(at url: URL) throws -> BackgroundCatalogAccess {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Refusal("could not open the catalog: no file at \(url.path)")
        }
        if case .refused(let words) = SQLiteWALSidecar.prepareForReadOnlyOpen(url) {
            throw Refusal(words)
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, openFlags, nil)
        guard rc == SQLITE_OK, let handle else {
            let words = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw Refusal("could not open the catalog read-only: \(words)")
        }
        return BackgroundCatalogAccess(url: url, db: handle)
    }

    /// What SQLite itself says about the handle — the runtime half of the
    /// sensor. True for every handle this type can make.
    public var isReadOnly: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return true }
        return sqlite3_db_readonly(db, "main") == 1
    }

    /// `catalog_state.schema_version`, or nil when the file has no such table.
    public func schemaVersion() throws -> Int? {
        let tables = try strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'catalog_state'")
        guard !tables.isEmpty else { return nil }
        return try strings("SELECT schema_version FROM catalog_state WHERE singleton = 1").first.flatMap(Int.init)
    }

    /// The first column of each row of `sql`, as text (NULL → ""). A
    /// statement that would write is refused by the engine (SQLITE_READONLY)
    /// and surfaces as a `Refusal` carrying `readOnlyWords`.
    public func strings(_ sql: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw Refusal("the catalog handle is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Self.refusal(db)
        }
        defer { sqlite3_finalize(statement) }
        var out: [String] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { out.append(String(cString: text)) } else { out.append("") }
                if out.count >= Self.maxRows { break }
                continue
            }
            if rc == SQLITE_DONE { break }
            throw Self.refusal(db)
        }
        return out
    }

    private static func refusal(_ db: OpaquePointer) -> Refusal {
        let code = sqlite3_extended_errcode(db) & 0xFF
        let message = String(cString: sqlite3_errmsg(db))
        if code == SQLITE_READONLY { return Refusal("\(readOnlyWords) — \(message)") }
        return Refusal("catalog read failed: \(message)")
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }
}
