// ModelLabStore.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the lab notebook — the SQLite sidecar `model-lab.sqlite`
// where EVERY run of EVERY approach lands its raw output before anyone
// decides whether it was any good (docs/design/video_llm_lab_2026_10_30.md
// §3.4). Append-only; keyed by content digest; never a path as identity.
//
// File: `model-lab.sqlite` beside `audio-fingerprints.sqlite` in
// ~/Library/Application Support/VideoScan (the per-process sandbox on a
// test host). Never beside media; never in git; the nightly `.backup`
// copies it with the catalog (design §3.4).
//
// Shape: the AudioFingerprintStore pattern, exactly — one connection behind
// an NSLock, WAL, synchronous=NORMAL, busy_timeout so two jobs' connections
// wait rather than fail, a `schema(version)` table, every return code
// checked and thrown as a named `Failure`, a batch is ONE transaction. Open
// REFUSES, in words, before any media is read: folder not writable, not a
// database, schema newer than this build. The read-only door
// (`init(readingOnly:)`) restores a missing `-wal` create-only through
// `SQLiteWALSidecar` (DECISIONS 2026-10-26 #386) and never checkpoints or
// deletes a journal (#387). Sidecar rules 1–6 of provenance_retroactive
// §sidecars.
//
// Tables (§3.4): `runs` (one per START; the run record names approach,
// revision, prompt hash, host, model digest, git SHA, sampler, time),
// `outputs` (one per window per family: raw JSON + the schema_valid verdict
// + elapsed), `segments` (timed transcript lines until a catalog column is
// approved), `vectors` (§5 A4 embeddings). Every table has `BEFORE DELETE`
// and `BEFORE UPDATE … RAISE(ABORT)` triggers: a notebook is never erased or
// rewritten; a wrong run gets a new run.
//
// Paging (rule 5): `forEachOutput` walks a run in KEYSET pages of 256 rows
// ordered by (run_id, rowid) — the lock is held per page, released before
// the body runs, so a long summary never blocks another job's `putOutputs`
// for more than one page. (For Rick: a cursor that re-seeks with
// `WHERE rowid > last` per page — a B-tree range scan resumed by key, never
// OFFSET.)
//
// Preflight: `preflight(_:host:)` is the pure START check — weights
// missing, RAM short, approach disabled, remote slot — and `beginRun`
// refuses with that typed verdict BEFORE a row is written, so a run with no
// weights fails in one line, not after decoding 400 files.
//
// MEMORY: one page of raw JSON (≤ 256 rows × ≤ 64 KB, capped at 16 MB per
// page like the audio store) plus one decoded value during a summary; a
// batch put holds the batch's rows while bound (the job caps the batch).
// (For Rick: `OpaquePointer` is `sqlite3*` / `sqlite3_stmt*`; `lock.withLock`
// ≈ std::lock_guard around every public method.)

import Foundation
import SQLite3

public final class ModelLabStore: @unchecked Sendable {

    public static let fileName = "model-lab.sqlite"
    /// 1 = runs, outputs, segments, vectors (2026-10-30, Phase 0).
    public static let schemaVersion = 1

    // MARK: Failure and refusal

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case directoryNotWritable(path: String)
        case cannotOpen(path: String, reason: String)
        case notADatabase(path: String)
        case schemaNewer(found: Int, supported: Int)
        case sql(String)
        case readOnlyNeedsWAL(path: String)
        case noLabTables(path: String)
        case readOnly(path: String)
        /// START refused by `preflight`; nothing was written.
        case refused(Refusal)

        public var description: String {
            switch self {
            case .directoryNotWritable(let path): return "the model-lab folder is not writable: \(path)"
            case .cannotOpen(let path, let reason): return "the model-lab file could not be opened (\(reason)): \(path)"
            case .notADatabase(let path): return "the model-lab file is not a database (damaged or replaced): \(path)"
            case .schemaNewer(let found, let supported):
                return "the model-lab file was written by a newer VideoScan (schema \(found); this build reads up to \(supported)) — it was not opened"
            case .sql(let message): return "model-lab store error: \(message)"
            case .readOnlyNeedsWAL(let path):
                return "the model-lab file can't be read without changing it: its write-ahead log (\((path as NSString).lastPathComponent)-wal) is missing, and this reader never writes. Nothing was read or changed: \(path)"
            case .noLabTables(let path): return "the model-lab file holds no lab tables (never written by a model run): \(path)"
            case .readOnly(let path): return "the model-lab file is open read-only; nothing is written: \(path)"
            case .refused(let refusal): return refusal.description
            }
        }
    }

    /// Why a run may not START. Typed so the job's one log line says which.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case weightsMissing(approach: ApproachID, location: String?)
        case insufficientRAM(approach: ApproachID, neededGB: Double, availableGB: Double)
        case approachDisabled(approach: ApproachID)
        /// Phase 0: the cloud slot exists in the registry and never runs.
        case remoteHostNotEnabled(approach: ApproachID)

        public var description: String {
            switch self {
            case .weightsMissing(let approach, let location):
                return "refused at START: the weights for \(approach) are not on this machine\(location.map { " (\($0))" } ?? ""); nothing was run"
            case .insufficientRAM(let approach, let needed, let available):
                return "refused at START: \(approach) needs \(needed) GB and this machine has \(available) GB free; nothing was run"
            case .approachDisabled(let approach):
                return "refused at START: \(approach) is disabled in this build; nothing was run"
            case .remoteHostNotEnabled(let approach):
                return "refused at START: \(approach) runs on a remote host, which is not enabled (DECISIONS 2026-10-10; BACKLOG cloud-on-derived-text); nothing was run"
            }
        }
    }

    /// What the caller measured about this machine before START.
    public struct HostFacts: Sendable, Equatable {
        public let availableRAMGB: Double
        public let weightsPresent: Bool
        public init(availableRAMGB: Double, weightsPresent: Bool) {
            self.availableRAMGB = availableRAMGB
            self.weightsPresent = weightsPresent
        }
    }

    /// The pure START check. nil = may start.
    public static func preflight(_ approach: ApproachDescriptor, host: HostFacts) -> Refusal? {
        if !approach.enabled { return .approachDisabled(approach: approach.id) }
        if !approach.host.isLocal { return .remoteHostNotEnabled(approach: approach.id) }
        if !host.weightsPresent { return .weightsMissing(approach: approach.id, location: approach.resources.weightsLocation) }
        if approach.resources.peakRAMGB > host.availableRAMGB {
            return .insufficientRAM(approach: approach.id, neededGB: approach.resources.peakRAMGB, availableGB: host.availableRAMGB)
        }
        return nil
    }

    // MARK: Rows

    /// What the job knows at START.
    public struct RunStart: Sendable, Equatable {
        public let runID: String
        public let approach: ApproachDescriptor
        public let modelDigest: String
        public let gitSHA: String
        public let samplerID: String
        public let startedAt: Date
        public init(runID: String, approach: ApproachDescriptor, modelDigest: String, gitSHA: String, samplerID: String, startedAt: Date = Date()) {
            self.runID = runID
            self.approach = approach
            self.modelDigest = modelDigest
            self.gitSHA = gitSHA
            self.samplerID = samplerID
            self.startedAt = startedAt
        }
    }

    /// One `runs` row as read back.
    public struct RunRecord: Sendable, Equatable {
        public let runID: String
        public let approachID: ApproachID
        public let revision: Int
        public let promptHash: String
        public let host: String
        public let modelDigest: String
        public let gitSHA: String
        public let samplerID: String
        public let startedAt: Date
    }

    /// One `outputs` row: one window, one family, the raw answer.
    public struct OutputRow: Sendable, Equatable {
        public let runID: String
        public let contentDigest: String
        public let sizeBytes: Int64
        public let windowStartS: Double
        public let windowEndS: Double
        /// The family word exactly as stored. A row written by a newer build
        /// may carry a word this build does not know; it is kept, never
        /// relabelled.
        public let familyWord: String
        public let rawJSON: Data
        public let schemaValid: Bool
        public let elapsedS: Double

        /// nil when `familyWord` is not a family this build knows.
        public var family: FieldFamily? { FieldFamily(rawValue: familyWord) }

        public init(runID: String, contentDigest: String, sizeBytes: Int64, windowStartS: Double, windowEndS: Double,
                    family: FieldFamily, rawJSON: Data, schemaValid: Bool, elapsedS: Double) {
            self.init(runID: runID, contentDigest: contentDigest, sizeBytes: sizeBytes, windowStartS: windowStartS, windowEndS: windowEndS,
                      familyWord: family.rawValue, rawJSON: rawJSON, schemaValid: schemaValid, elapsedS: elapsedS)
        }

        init(runID: String, contentDigest: String, sizeBytes: Int64, windowStartS: Double, windowEndS: Double,
             familyWord: String, rawJSON: Data, schemaValid: Bool, elapsedS: Double) {
            self.runID = runID
            self.contentDigest = contentDigest
            self.sizeBytes = sizeBytes
            self.windowStartS = windowStartS
            self.windowEndS = windowEndS
            self.familyWord = familyWord
            self.rawJSON = rawJSON
            self.schemaValid = schemaValid
            self.elapsedS = elapsedS
        }
    }

    /// One timed transcript line.
    public struct SegmentRow: Sendable, Equatable {
        public let contentDigest: String
        public let engine: String
        public let startS: Double
        public let endS: Double
        public let text: String
        public init(contentDigest: String, engine: String, startS: Double, endS: Double, text: String) {
            self.contentDigest = contentDigest
            self.engine = engine
            self.startS = startS
            self.endS = endS
            self.text = text
        }
    }

    /// One embedding for one window (§5 A4).
    public struct VectorRow: Sendable, Equatable {
        public let contentDigest: String
        public let model: String
        public let windowStartS: Double
        public let windowEndS: Double
        public let dims: Int
        public let blob: Data
        public init(contentDigest: String, model: String, windowStartS: Double, windowEndS: Double, dims: Int, blob: Data) {
            self.contentDigest = contentDigest
            self.model = model
            self.windowStartS = windowStartS
            self.windowEndS = windowEndS
            self.dims = dims
            self.blob = blob
        }
    }

    /// What a run's outputs say, counted without trusting any one row.
    public struct RunSummary: Sendable, Equatable {
        public let rows: Int
        /// The verdict stored at write time.
        public let schemaValid: Int
        public let schemaInvalid: Int
        /// Re-decoded now through ContractDecoder: a corrupt or truncated
        /// raw_json counts here, never throws.
        public let replayDecoded: Int
        public let replayUndecodable: Int
        /// Rows whose `family` word this build does not know.
        public let unknownFamilyRows: Int
        public let byFamily: [FieldFamily: Int]
    }

    // MARK: Open

    public static var defaultDirectory: URL {
        if let sandbox = TestHostDetection.sandboxedApplicationSupportRoot(for: "ModelLabStore") {
            return sandbox.appendingPathComponent("VideoScan", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    public let fileURL: URL
    public let isReadOnly: Bool
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Open (creating when absent) the sidecar in `directory`.
    public init(directory: URL) throws {
        fileURL = directory.appendingPathComponent(Self.fileName)
        isReadOnly = false
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

    /// Open an EXISTING sidecar READ-ONLY: no PRAGMA, no CREATE, no
    /// checkpoint, no `-wal` deletion on close. A WAL-mode file with no
    /// `-wal` first gets an EMPTY one, create-only (#386).
    public init(readingOnly directory: URL) throws {
        fileURL = directory.appendingPathComponent(Self.fileName)
        isReadOnly = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw Failure.cannotOpen(path: fileURL.path, reason: "no such file")
        }
        if case .refused = SQLiteWALSidecar.prepareForReadOnlyOpen(fileURL) {
            throw Failure.readOnlyNeedsWAL(path: fileURL.path)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle { sqlite3_close_v2(handle) }
            throw Failure.cannotOpen(path: fileURL.path, reason: reason)
        }
        db = handle
        sqlite3_busy_timeout(handle, Self.busyTimeoutMS)
        do {
            try checkReadableSchema()
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Two jobs' connections (or a reader and a writer across a
    /// checkpoint) wait this long before SQLITE_BUSY surfaces.
    static let busyTimeoutMS: Int32 = 5_000

    // MARK: Schema

    private func prepareSchema() throws {
        guard let db else { throw Failure.sql("closed") }
        sqlite3_busy_timeout(db, Self.busyTimeoutMS)
        // The first statement against a garbage file is where SQLITE_NOTADB surfaces.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("CREATE TABLE IF NOT EXISTS schema (version INTEGER NOT NULL)")
        let found = try scalarInt("SELECT version FROM schema LIMIT 1")
        if let found {
            guard found <= Self.schemaVersion else { throw Failure.schemaNewer(found: found, supported: Self.schemaVersion) }
        } else {
            try exec("INSERT INTO schema (version) VALUES (\(Self.schemaVersion))")
        }
        for statement in ModelLabSchema.ddl { try exec(statement) }
    }


    private func checkReadableSchema() throws {
        let walMissing = !FileManager.default.fileExists(atPath: fileURL.path + "-wal")
        do {
            guard let found = try scalarInt("SELECT version FROM schema LIMIT 1") else {
                throw Failure.noLabTables(path: fileURL.path)
            }
            guard found <= Self.schemaVersion else { throw Failure.schemaNewer(found: found, supported: Self.schemaVersion) }
            guard try scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('runs', 'outputs', 'segments', 'vectors')") == 4 else {
                throw Failure.noLabTables(path: fileURL.path)
            }
        } catch Failure.sql where walMissing && sqlite3_errcode(db) == SQLITE_CANTOPEN {
            throw Failure.readOnlyNeedsWAL(path: fileURL.path)
        } catch Failure.sql(let message) where message.contains("no such table") {
            throw Failure.noLabTables(path: fileURL.path)
        }
    }

    public func schemaVersionOnDisk() throws -> Int {
        try lock.withLock { try scalarInt("SELECT version FROM schema LIMIT 1") ?? 0 }
    }

    /// End of job (sidecar rule 6): fold the WAL into the file without
    /// blocking anyone; never TRUNCATE while another job may hold the store.
    public func checkpointPassive() throws {
        guard !isReadOnly else { return }
        try lock.withLock { try exec("PRAGMA wal_checkpoint(PASSIVE)") }
    }

    // MARK: Runs

    /// Preflight, then write the run row — or refuse with the typed verdict
    /// and write nothing.
    public func beginRun(_ start: RunStart, host: HostFacts) throws {
        if let refusal = Self.preflight(start.approach, host: host) { throw Failure.refused(refusal) }
        try requireWritable()
        try lock.withLock {
            let stmt = try prepare("""
                INSERT INTO runs (run_id, approach_id, revision, prompt_hash, host, model_digest, git_sha, sampler_id, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, start.runID)
            try bindText(stmt, 2, start.approach.id.rawValue)
            sqlite3_bind_int64(stmt, 3, Int64(start.approach.revision))
            try bindText(stmt, 4, start.approach.promptHash)
            try bindText(stmt, 5, start.approach.host.label)
            try bindText(stmt, 6, start.modelDigest)
            try bindText(stmt, 7, start.gitSHA)
            try bindText(stmt, 8, start.samplerID)
            sqlite3_bind_double(stmt, 9, start.startedAt.timeIntervalSince1970)
            _ = try step(stmt)
        }
    }

    public func run(_ runID: String) throws -> RunRecord? {
        try lock.withLock {
            let stmt = try prepare("SELECT run_id, approach_id, revision, prompt_hash, host, model_digest, git_sha, sampler_id, started_at FROM runs WHERE run_id = ?")
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, runID)
            guard try step(stmt) else { return nil }
            guard let id = ApproachID(rawValue: text(stmt, 1)) else {
                throw Failure.sql("run \(runID) names an approach id this build cannot read: \(text(stmt, 1))")
            }
            return RunRecord(runID: text(stmt, 0), approachID: id, revision: Int(sqlite3_column_int64(stmt, 2)),
                             promptHash: text(stmt, 3), host: text(stmt, 4), modelDigest: text(stmt, 5), gitSHA: text(stmt, 6),
                             samplerID: text(stmt, 7), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)))
        }
    }

    public func runCount() throws -> Int {
        try lock.withLock { try scalarInt("SELECT COUNT(*) FROM runs") ?? 0 }
    }

    // MARK: Outputs

    /// Write every row in ONE transaction; any failure rolls the batch back.
    public func putOutputs(_ rows: [OutputRow]) throws {
        guard !rows.isEmpty else { return }
        try requireWritable()
        try lock.withLock {
            try exec("BEGIN IMMEDIATE")
            do {
                let stmt = try prepare("""
                    INSERT INTO outputs (run_id, content_digest, size_bytes, window_start_s, window_end_s, family, raw_json, schema_valid, elapsed_s)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(stmt) }
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindText(stmt, 1, row.runID)
                    try bindText(stmt, 2, row.contentDigest)
                    sqlite3_bind_int64(stmt, 3, row.sizeBytes)
                    sqlite3_bind_double(stmt, 4, row.windowStartS)
                    sqlite3_bind_double(stmt, 5, row.windowEndS)
                    try bindText(stmt, 6, row.familyWord)
                    try bindBytesAsTextOrBlob(stmt, 7, row.rawJSON)
                    sqlite3_bind_int64(stmt, 8, row.schemaValid ? 1 : 0)
                    sqlite3_bind_double(stmt, 9, row.elapsedS)
                    _ = try step(stmt)
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func outputCount(runID: String) throws -> Int {
        try lock.withLock {
            let stmt = try prepare("SELECT COUNT(*) FROM outputs WHERE run_id = ?")
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, runID)
            guard try step(stmt) else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public static let defaultPageSize = 256
    public static let maxPageBytes = 16 << 20

    /// Every output of `runID` in rowid order, keyset-paged: the lock is
    /// taken once per page (≤ `pageSize` rows or ≤ `maxPageBytes` of
    /// raw JSON), released before `body` runs. `body` returns false to stop.
    /// Rows a concurrent writer appends after the current key are seen.
    public func forEachOutput(runID: String, pageSize: Int = ModelLabStore.defaultPageSize,
                              _ body: (Int64, OutputRow) throws -> Bool) throws {
        precondition(pageSize > 0, "forEachOutput: pageSize must be positive")
        var after: Int64 = -1
        while true {
            let page = try readOutputPage(runID: runID, afterRowID: after, limit: pageSize)
            for (rowid, row) in page.rows {
                guard try body(rowid, row) else { return }
            }
            guard page.rows.count == pageSize || page.reachedByteCap, let last = page.rows.last else { return }
            after = last.rowid
        }
    }

    private struct OutputPage {
        var rows: [(rowid: Int64, row: OutputRow)] = []
        var reachedByteCap = false
    }

    private func readOutputPage(runID: String, afterRowID: Int64, limit: Int) throws -> OutputPage {
        try lock.withLock {
            let stmt = try prepare("""
                SELECT rowid, run_id, content_digest, size_bytes, window_start_s, window_end_s, family, raw_json, schema_valid, elapsed_s
                FROM outputs WHERE run_id = ? AND rowid > ? ORDER BY rowid LIMIT ?
            """)
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, runID)
            sqlite3_bind_int64(stmt, 2, afterRowID)
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            var page = OutputPage()
            var pageBytes = 0
            while try step(stmt) {
                let raw = bytes(stmt, 7)
                let row = OutputRow(runID: text(stmt, 1), contentDigest: text(stmt, 2), sizeBytes: sqlite3_column_int64(stmt, 3),
                                    windowStartS: sqlite3_column_double(stmt, 4), windowEndS: sqlite3_column_double(stmt, 5),
                                    familyWord: text(stmt, 6), rawJSON: raw,
                                    schemaValid: sqlite3_column_int64(stmt, 8) != 0, elapsedS: sqlite3_column_double(stmt, 9))
                page.rows.append((sqlite3_column_int64(stmt, 0), row))
                pageBytes += raw.count
                if pageBytes >= Self.maxPageBytes { page.reachedByteCap = true; break }
            }
            return page
        }
    }

    /// Counts for a run; re-decodes every raw_json through ContractDecoder
    /// and never throws on a corrupt row or an unknown family word.
    public func summarize(runID: String) throws -> RunSummary {
        var rows = 0, valid = 0, invalid = 0, decoded = 0, undecodable = 0, unknownFamily = 0
        var byFamily: [FieldFamily: Int] = [:]
        try forEachOutput(runID: runID) { _, row in
            rows += 1
            if row.schemaValid { valid += 1 } else { invalid += 1 }
            guard let family = row.family else {
                unknownFamily += 1
                undecodable += 1
                return true
            }
            byFamily[family, default: 0] += 1
            let window = SampleWindow(startS: row.windowStartS, endS: row.windowEndS, frameTimesS: [], audioRange: nil)
            switch ContractDecoder.decode(family: family, json: row.rawJSON, window: window) {
            case .output: decoded += 1
            case .schemaInvalid: undecodable += 1
            }
            return true
        }
        return RunSummary(rows: rows, schemaValid: valid, schemaInvalid: invalid, replayDecoded: decoded,
                          replayUndecodable: undecodable, unknownFamilyRows: unknownFamily, byFamily: byFamily)
    }

    // MARK: Segments

    public func putSegments(_ rows: [SegmentRow]) throws {
        guard !rows.isEmpty else { return }
        try requireWritable()
        try lock.withLock {
            try exec("BEGIN IMMEDIATE")
            do {
                let stmt = try prepare("INSERT INTO segments (content_digest, engine, start_s, end_s, text) VALUES (?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(stmt) }
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindText(stmt, 1, row.contentDigest)
                    try bindText(stmt, 2, row.engine)
                    sqlite3_bind_double(stmt, 3, row.startS)
                    sqlite3_bind_double(stmt, 4, row.endS)
                    try bindText(stmt, 5, row.text)
                    _ = try step(stmt)
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// In time order. MEMORY: one file's transcript (a 4-hour tape ≈ a few
    /// thousand lines, under 1 MB).
    public func segments(for contentDigest: String) throws -> [SegmentRow] {
        try lock.withLock {
            let stmt = try prepare("SELECT content_digest, engine, start_s, end_s, text FROM segments WHERE content_digest = ? ORDER BY start_s, rowid")
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, contentDigest)
            var rows: [SegmentRow] = []
            while try step(stmt) {
                rows.append(SegmentRow(contentDigest: text(stmt, 0), engine: text(stmt, 1), startS: sqlite3_column_double(stmt, 2),
                                       endS: sqlite3_column_double(stmt, 3), text: text(stmt, 4)))
            }
            return rows
        }
    }

    // MARK: Vectors

    public func putVectors(_ rows: [VectorRow]) throws {
        guard !rows.isEmpty else { return }
        try requireWritable()
        try lock.withLock {
            try exec("BEGIN IMMEDIATE")
            do {
                let stmt = try prepare("INSERT INTO vectors (content_digest, model, window_start_s, window_end_s, dims, blob) VALUES (?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(stmt) }
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    try bindText(stmt, 1, row.contentDigest)
                    try bindText(stmt, 2, row.model)
                    sqlite3_bind_double(stmt, 3, row.windowStartS)
                    sqlite3_bind_double(stmt, 4, row.windowEndS)
                    sqlite3_bind_int64(stmt, 5, Int64(row.dims))
                    try bindBlob(stmt, 6, row.blob)
                    _ = try step(stmt)
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// MEMORY: one file's vectors (a 4-hour tape at one per 60 s window with
    /// 1,152 float32 dims ≈ 240 × 4.6 KB ≈ 1.1 MB).
    public func vectors(for contentDigest: String) throws -> [VectorRow] {
        try lock.withLock {
            let stmt = try prepare("SELECT content_digest, model, window_start_s, window_end_s, dims, blob FROM vectors WHERE content_digest = ? ORDER BY model, window_start_s, rowid")
            defer { sqlite3_finalize(stmt) }
            try bindText(stmt, 1, contentDigest)
            var rows: [VectorRow] = []
            while try step(stmt) {
                rows.append(VectorRow(contentDigest: text(stmt, 0), model: text(stmt, 1), windowStartS: sqlite3_column_double(stmt, 2),
                                      windowEndS: sqlite3_column_double(stmt, 3), dims: Int(sqlite3_column_int64(stmt, 4)), blob: bytes(stmt, 5)))
            }
            return rows
        }
    }

    // MARK: SQLite plumbing (lock held by the caller)

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func requireWritable() throws {
        if isReadOnly { throw Failure.readOnly(path: fileURL.path) }
    }

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

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(stmt, index, value, -1, Self.transient) == SQLITE_OK else { throw Failure.sql(message()) }
    }

    private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) throws {
        let rc = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), Self.transient)
        }
        guard rc == SQLITE_OK else { throw Failure.sql(message()) }
    }

    /// raw_json is TEXT when the bytes are UTF-8 (readable in a sqlite3
    /// shell); bytes that are not valid UTF-8 are kept as a BLOB rather than
    /// mangled. Either reads back through `bytes(_:_:)`.
    private func bindBytesAsTextOrBlob(_ stmt: OpaquePointer, _ index: Int32, _ data: Data) throws {
        if let string = String(data: data, encoding: .utf8) {
            try bindText(stmt, index, string)
        } else {
            try bindBlob(stmt, index, data)
        }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    /// The column's bytes whether stored as TEXT or BLOB; empty for NULL.
    private func bytes(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let base = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: base, count: count)
    }
}

/// The DDL, outside the class so the store body stays within the lint budget.
enum ModelLabSchema {
    /// Additive only; a change is a new version and a migration.
    static let ddl: [String] = [
        """
        CREATE TABLE IF NOT EXISTS runs (
            run_id        TEXT    PRIMARY KEY NOT NULL,
            approach_id   TEXT    NOT NULL,
            revision      INTEGER NOT NULL,
            prompt_hash   TEXT    NOT NULL,
            host          TEXT    NOT NULL,
            model_digest  TEXT    NOT NULL,
            git_sha       TEXT    NOT NULL,
            sampler_id    TEXT    NOT NULL,
            started_at    REAL    NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS outputs (
            run_id         TEXT    NOT NULL REFERENCES runs(run_id),
            content_digest TEXT    NOT NULL,
            size_bytes     INTEGER NOT NULL,
            window_start_s REAL    NOT NULL,
            window_end_s   REAL    NOT NULL,
            family         TEXT    NOT NULL,
            raw_json       TEXT    NOT NULL,
            schema_valid   INTEGER NOT NULL,
            elapsed_s      REAL    NOT NULL
        )
        """,
        // (run_id) carries rowid implicitly: `WHERE run_id = ? AND rowid > ? ORDER BY rowid` is one index range.
        "CREATE INDEX IF NOT EXISTS outputs_by_run ON outputs(run_id)",
        "CREATE INDEX IF NOT EXISTS outputs_by_digest ON outputs(content_digest, size_bytes)",
        """
        CREATE TABLE IF NOT EXISTS segments (
            content_digest TEXT NOT NULL,
            engine         TEXT NOT NULL,
            start_s        REAL NOT NULL,
            end_s          REAL NOT NULL,
            text           TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS segments_by_digest ON segments(content_digest, start_s)",
        """
        CREATE TABLE IF NOT EXISTS vectors (
            content_digest TEXT    NOT NULL,
            model          TEXT    NOT NULL,
            window_start_s REAL    NOT NULL,
            window_end_s   REAL    NOT NULL,
            dims           INTEGER NOT NULL,
            blob           BLOB    NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS vectors_by_digest ON vectors(content_digest, model)",
        // Append-only: the notebook is never erased or rewritten.
        "CREATE TRIGGER IF NOT EXISTS runs_never_deleted BEFORE DELETE ON runs BEGIN SELECT RAISE(ABORT, 'model-lab runs are append-only; a wrong run gets a new run'); END",
        "CREATE TRIGGER IF NOT EXISTS runs_never_updated BEFORE UPDATE ON runs BEGIN SELECT RAISE(ABORT, 'model-lab runs are append-only; a wrong run gets a new run'); END",
        "CREATE TRIGGER IF NOT EXISTS outputs_never_deleted BEFORE DELETE ON outputs BEGIN SELECT RAISE(ABORT, 'model-lab outputs are append-only'); END",
        "CREATE TRIGGER IF NOT EXISTS outputs_never_updated BEFORE UPDATE ON outputs BEGIN SELECT RAISE(ABORT, 'model-lab outputs are append-only'); END",
        "CREATE TRIGGER IF NOT EXISTS segments_never_deleted BEFORE DELETE ON segments BEGIN SELECT RAISE(ABORT, 'model-lab segments are append-only'); END",
        "CREATE TRIGGER IF NOT EXISTS segments_never_updated BEFORE UPDATE ON segments BEGIN SELECT RAISE(ABORT, 'model-lab segments are append-only'); END",
        "CREATE TRIGGER IF NOT EXISTS vectors_never_deleted BEFORE DELETE ON vectors BEGIN SELECT RAISE(ABORT, 'model-lab vectors are append-only'); END",
        "CREATE TRIGGER IF NOT EXISTS vectors_never_updated BEFORE UPDATE ON vectors BEGIN SELECT RAISE(ABORT, 'model-lab vectors are append-only'); END",
    ]
}
