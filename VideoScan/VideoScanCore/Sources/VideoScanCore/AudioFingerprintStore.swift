// AudioFingerprintStore.swift (VideoScanCore)
// ONE SENTENCE: the SQLite sidecar that holds audio-fingerprint BYTES, keyed
// by content identity, so catalog.json carries only a small stamp per record
// (Rick 2026-10-14: "the catalog points to the file and the fingerprint").
//
// File: `audio-fingerprints.sqlite` — in production beside catalog.json in
// ~/Library/Application Support/VideoScan; the job passes the catalog's
// folder, a test passes a scratch folder (`init(directory:)`), and the
// default on a test host is the per-process sandbox (TestHostDetection).
// NEVER beside a media file; media is read-only everywhere in this feature.
//
// Shape (the MetadataCache pattern, hardened for a store that is NOT a
// rebuildable cache — recomputing a fingerprint costs a full read of the
// file): one connection behind an NSLock, WAL journal, synchronous=NORMAL
// (a crash loses at most the last transaction, never the file), prepared
// statements, every return code checked and thrown as a named `Failure`,
// a `schema` version table, and `put` writes a whole batch in ONE
// transaction. Opening REFUSES (throws) when the folder is not writable,
// the file is not a database (poisoned), or the schema is newer than this
// build — so a job can say why before it reads a single media file.
//
// Table `fingerprints`, PRIMARY KEY (content_digest, size_bytes,
// engine_version): two copies of the same bytes share one row; a new engine
// version writes a new row and leaves the old one (an old build can still
// read its own). `blob` is `AudioFingerprint.encoded()` ("VSAF");
// `recipe_id`, `analyzed_seconds` and `complete` sit beside it so a
// "shared" stamp can be honest without decoding the blob.
//
// MEMORY: a lookup returns one summary (a few words) or one fingerprint
// (8 B per landmark: ~150 KB for a 16-minute tape, ~2.3 MB for 4 h). A
// batch put holds the batch's blobs while they are bound — the job caps the
// batch (AudioFingerprintBackfillJob.checkpointFiles).
//
// (For Rick: `OpaquePointer` is the `sqlite3*` / `sqlite3_stmt*` handle;
// `lock.withLock { }` ≈ std::lock_guard around every public method, so the
// connection is used from one thread at a time.)

import Foundation
import SQLite3

public final class AudioFingerprintStore: @unchecked Sendable {

    public static let fileName = "audio-fingerprints.sqlite"
    /// The schema this build writes and understands. 2 = `recipe_id` and
    /// `complete` beside the blob (2026-10-14, engine codex round 1). A
    /// pre-release schema-1 file is dropped and re-created — nothing was
    /// ever persisted under it outside tests.
    public static let schemaVersion = 2

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The folder could not be created or is not writable.
        case directoryNotWritable(path: String)
        /// SQLite would not open the file (permissions, a directory in the way…).
        case cannotOpen(path: String, reason: String)
        /// The file exists but is not a SQLite database (poisoned).
        case notADatabase(path: String)
        /// Written by a newer VideoScan.
        case schemaNewer(found: Int, supported: Int)
        /// Any other statement failure, with SQLite's message.
        case sql(String)

        public var description: String {
            switch self {
            case .directoryNotWritable(let path): return "the fingerprint folder is not writable: \(path)"
            case .cannotOpen(let path, let reason): return "the fingerprint file could not be opened (\(reason)): \(path)"
            case .notADatabase(let path): return "the fingerprint file is not a database (damaged or replaced): \(path)"
            case .schemaNewer(let found, let supported):
                return "the fingerprint file was written by a newer VideoScan (schema \(found); this build reads up to \(supported))"
            case .sql(let message): return "fingerprint store error: \(message)"
            }
        }
    }

    /// Content identity: the self-describing digest (AudioFingerprintStamp)
    /// plus the byte count.
    public struct Key: Hashable, Sendable {
        public let contentDigest: String
        public let sizeBytes: Int64
        public init(contentDigest: String, sizeBytes: Int64) {
            self.contentDigest = contentDigest
            self.sizeBytes = sizeBytes
        }
    }

    /// What a row says without decoding its blob.
    public struct Summary: Equatable, Sendable {
        public let engineVersion: Int
        /// `AudioFingerprintParameters.recipeID` the blob was made with.
        public let recipeID: UInt32
        public let computedAt: Date
        public let sourcePath: String
        public let analyzedSeconds: Double
        /// `AudioFingerprint.complete`: the whole recording, not a prefix.
        public let complete: Bool
        public let landmarks: Int
        public let bytes: Int

        public init(engineVersion: Int, recipeID: UInt32, computedAt: Date, sourcePath: String,
                    analyzedSeconds: Double, complete: Bool, landmarks: Int, bytes: Int) {
            self.engineVersion = engineVersion
            self.recipeID = recipeID
            self.computedAt = computedAt
            self.sourcePath = sourcePath
            self.analyzedSeconds = analyzedSeconds
            self.complete = complete
            self.landmarks = landmarks
            self.bytes = bytes
        }
    }

    /// One row to write.
    public struct Entry: Sendable {
        public let key: Key
        public let fingerprint: AudioFingerprint
        /// The path it was computed from — informational only.
        public let sourcePath: String
        public let computedAt: Date
        public init(key: Key, fingerprint: AudioFingerprint, sourcePath: String, computedAt: Date = Date()) {
            self.key = key
            self.fingerprint = fingerprint
            self.sourcePath = sourcePath
            self.computedAt = computedAt
        }
    }

    /// App Support/VideoScan in production; the per-process sandbox on a
    /// test host (so a test that forgets to inject can never touch Rick's).
    public static var defaultDirectory: URL {
        if let sandbox = TestHostDetection.sandboxedApplicationSupportRoot(for: "AudioFingerprintStore") {
            return sandbox.appendingPathComponent("VideoScan", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    public let fileURL: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Open (creating when absent) the sidecar in `directory`. Throws a
    /// named `Failure` instead of returning a store that cannot work.
    public init(directory: URL) throws {
        fileURL = directory.appendingPathComponent(Self.fileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw Failure.directoryNotWritable(path: directory.path)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle { sqlite3_close(handle) }
            throw Failure.cannotOpen(path: fileURL.path, reason: reason)
        }
        db = handle
        do {
            try prepareSchema()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Schema

    private func prepareSchema() throws {
        // The first statement against a garbage file is where SQLITE_NOTADB
        // surfaces — mapped to the named refusal.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("CREATE TABLE IF NOT EXISTS schema (version INTEGER NOT NULL)")
        let found = try scalarInt("SELECT version FROM schema LIMIT 1")
        if let found {
            guard found <= Self.schemaVersion else { throw Failure.schemaNewer(found: found, supported: Self.schemaVersion) }
            if found < Self.schemaVersion {
                // Pre-release schema: nothing to carry forward (see schemaVersion).
                try exec("DROP TABLE IF EXISTS fingerprints")
                try exec("UPDATE schema SET version = \(Self.schemaVersion)")
            }
        } else {
            try exec("INSERT INTO schema (version) VALUES (\(Self.schemaVersion))")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS fingerprints (
                content_digest   TEXT    NOT NULL,
                size_bytes       INTEGER NOT NULL,
                engine_version   INTEGER NOT NULL,
                recipe_id        INTEGER NOT NULL,
                computed_at      REAL    NOT NULL,
                source_path      TEXT    NOT NULL,
                analyzed_seconds REAL    NOT NULL,
                complete         INTEGER NOT NULL,
                landmarks        INTEGER NOT NULL,
                blob             BLOB    NOT NULL,
                PRIMARY KEY (content_digest, size_bytes, engine_version)
            )
        """)
    }

    /// The version recorded in the file.
    public func schemaVersionOnDisk() throws -> Int {
        try lock.withLock { try scalarInt("SELECT version FROM schema LIMIT 1") ?? 0 }
    }

    // MARK: Read

    /// The row's facts for `key` at `engineVersion`, or nil.
    public func summary(for key: Key, engineVersion: Int = Int(AudioFingerprint.currentVersion)) throws -> Summary? {
        try lock.withLock {
            let sql = """
                SELECT engine_version, recipe_id, computed_at, source_path, analyzed_seconds, complete, landmarks, length(blob)
                FROM fingerprints WHERE content_digest = ? AND size_bytes = ? AND engine_version = ?
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, key: key, engineVersion: engineVersion)
            guard try step(stmt) else { return nil }
            return Summary(engineVersion: Int(sqlite3_column_int64(stmt, 0)),
                           recipeID: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 1)),
                           computedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                           sourcePath: text(stmt, 3),
                           analyzedSeconds: sqlite3_column_double(stmt, 4),
                           complete: sqlite3_column_int64(stmt, 5) != 0,
                           landmarks: Int(sqlite3_column_int64(stmt, 6)),
                           bytes: Int(sqlite3_column_int64(stmt, 7)))
        }
    }

    public func has(_ key: Key, engineVersion: Int = Int(AudioFingerprint.currentVersion)) throws -> Bool {
        try summary(for: key, engineVersion: engineVersion) != nil
    }

    /// The decoded fingerprint, or nil when absent or the blob is damaged.
    public func fingerprint(for key: Key, engineVersion: Int = Int(AudioFingerprint.currentVersion)) throws -> AudioFingerprint? {
        try lock.withLock {
            let sql = "SELECT blob FROM fingerprints WHERE content_digest = ? AND size_bytes = ? AND engine_version = ?"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, key: key, engineVersion: engineVersion)
            guard try step(stmt) else { return nil }
            guard let base = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            return AudioFingerprint(decoding: Data(bytes: base, count: count))
        }
    }

    public func count() throws -> Int {
        try lock.withLock { try scalarInt("SELECT COUNT(*) FROM fingerprints") ?? 0 }
    }

    // MARK: Write

    /// Write every entry in ONE transaction (INSERT OR REPLACE on the key).
    /// Throws — and rolls back — on any failure, so the caller never has a
    /// half-written batch to reason about.
    public func put(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try lock.withLock {
            try exec("BEGIN IMMEDIATE")
            do {
                let sql = """
                    INSERT OR REPLACE INTO fingerprints
                    (content_digest, size_bytes, engine_version, recipe_id, computed_at, source_path, analyzed_seconds, complete, landmarks, blob)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                for entry in entries {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bind(stmt, key: entry.key, engineVersion: Int(entry.fingerprint.version))
                    sqlite3_bind_int64(stmt, 4, Int64(entry.fingerprint.recipeID))
                    sqlite3_bind_double(stmt, 5, entry.computedAt.timeIntervalSince1970)
                    try bindText(stmt, 6, entry.sourcePath)
                    sqlite3_bind_double(stmt, 7, entry.fingerprint.analyzedSeconds)
                    sqlite3_bind_int64(stmt, 8, entry.fingerprint.complete ? 1 : 0)
                    sqlite3_bind_int64(stmt, 9, Int64(entry.fingerprint.landmarkCount))
                    let blob = entry.fingerprint.encoded()
                    let rc = blob.withUnsafeBytes { raw in
                        sqlite3_bind_blob(stmt, 10, raw.baseAddress, Int32(raw.count), Self.transient)
                    }
                    guard rc == SQLITE_OK else { throw Failure.sql(message()) }
                    _ = try step(stmt)
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: SQLite plumbing (lock held by the caller)

    /// SQLITE_TRANSIENT: SQLite copies the bytes before bind returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func message() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    private func mapped(_ rc: Int32) -> Failure {
        rc == SQLITE_NOTADB ? .notADatabase(path: fileURL.path) : .sql(message())
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw Failure.sql("closed") }
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw mapped(rc) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw Failure.sql("closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw mapped(rc) }
        return stmt
    }

    /// True on a row, false when done; throws on an error.
    private func step(_ stmt: OpaquePointer) throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw mapped(rc)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard try step(stmt) else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bind(_ stmt: OpaquePointer, key: Key, engineVersion: Int) throws {
        try bindText(stmt, 1, key.contentDigest)
        sqlite3_bind_int64(stmt, 2, key.sizeBytes)
        sqlite3_bind_int64(stmt, 3, Int64(engineVersion))
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, Self.transient) == SQLITE_OK else { throw Failure.sql(message()) }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }
}
