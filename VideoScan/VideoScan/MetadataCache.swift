import Foundation
import SQLite3

/// Persistent SQLite cache of ffprobe metadata.
/// Keyed by (path, fileSize, modDate) — if a file hasn't changed, we skip ffprobe entirely.
/// Stored at ~/Library/Application Support/VideoScan/metadata_cache.sqlite
/// in production; under unit tests the default redirects to a per-process
/// temp sandbox (see `defaultPath`), and tests can inject any path.
/// Thread-safe: NSLock serializes all SQLite access so probeFile can run off the main thread.
final class MetadataCache {
    private var db: OpaquePointer?
    private let lock = NSLock()

    /// Where this instance's database actually lives. Read-only; exposed so
    /// tests can assert isolation and diagnostics can report the location.
    let dbPath: String

    /// True when this process is a unit-test host. Multi-signal because
    /// Swift Testing doesn't necessarily link XCTest, so a single env-var
    /// check isn't reliable. Mirrors `CatalogStore.isRunningTests` /
    /// `ScanJobsStorage.isRunningTests`.
    private static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if env["VS_UI_TEST"] == "1" { return true } // UI-test target — see TestEnvironment.detect
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    /// Default database location. In production this is the user's real
    /// Application Support cache (unchanged behavior). Under a unit-test
    /// host it redirects to a per-process temp sandbox so the ~200 test
    /// call sites that construct `VideoScanModel()` can never read or
    /// write the real probe cache (same failure class as the Settings
    /// pollution incident). Narrow gate: only this DEFAULT is redirected —
    /// `MetadataCache(path:)` with an explicit path gets exactly that path.
    static var defaultPath: String {
        let base: URL
        if isRunningTests {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(
                    "VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        }
        let dir = base.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata_cache.sqlite").path
    }

    init(path: String = MetadataCache.defaultPath) {
        self.dbPath = path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS probe_cache (
                path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                mod_date REAL NOT NULL,
                filename TEXT,
                ext TEXT,
                stream_type TEXT,
                size_display TEXT,
                duration TEXT,
                duration_seconds REAL,
                date_created TEXT,
                date_modified TEXT,
                date_created_raw REAL,
                date_modified_raw REAL,
                container TEXT,
                video_codec TEXT,
                resolution TEXT,
                frame_rate TEXT,
                video_bitrate TEXT,
                total_bitrate TEXT,
                color_space TEXT,
                bit_depth TEXT,
                scan_type TEXT,
                audio_codec TEXT,
                audio_channels TEXT,
                audio_sample_rate TEXT,
                timecode TEXT,
                tape_name TEXT,
                is_playable TEXT,
                partial_md5 TEXT,
                directory TEXT,
                notes TEXT,
                content_hash TEXT,
                content_hash_at REAL,
                PRIMARY KEY (path, file_size, mod_date)
            )
        """)
        migrateAddColumn("content_hash", type: "TEXT")
        migrateAddColumn("content_hash_at", type: "REAL")
    }

    /// Additive migration for databases created before 2026-08-11.
    ///
    /// WHY THIS IS LOAD-BEARING. `probeFile` consults this cache BEFORE it
    /// hashes anything and returns early on a hit. Without the column, a
    /// cache hit would hand back an outcome whose `contentHash` is "" —
    /// so a rescan of an already-catalogued volume would not merely fail
    /// to populate the hash, it would ERASE hashes a backfill had just
    /// spent an hour computing. `partial_md5` has always survived rescans
    /// for exactly this reason: it lives here. The new hash must too.
    ///
    /// `ALTER TABLE ADD COLUMN` appends, so existing rows read the new
    /// column as NULL → "" and simply re-hash on next touch. Additive
    /// only: no data is rewritten, no column is dropped or reordered
    /// (the positional `SELECT *` decoding depends on that).
    /// Additive column migration for databases created before a field
    /// existed. `ALTER TABLE ADD COLUMN` appends, so existing rows read
    /// the new column as NULL and simply refresh on next touch. Additive
    /// only: nothing is rewritten, dropped, or reordered — the
    /// positional `SELECT *` decoding depends on that.
    private func migrateAddColumn(_ name: String, type: String) {
        guard let db = db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(probe_cache)", -1, &stmt, nil) == SQLITE_OK
        else { return }
        var hasColumn = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1),
               String(cString: c) == name { hasColumn = true; break }
        }
        sqlite3_finalize(stmt)
        if !hasColumn { exec("ALTER TABLE probe_cache ADD COLUMN \(name) \(type)") }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Look up a cached probe. Returns nil if not found or file has changed.
    ///
    /// Trafficks in the Sendable `ProbeOutcome` carrier rather than a
    /// `VideoRecord`: building the reference type is deferred to the main-actor
    /// drain points. The `wasCacheHit`/`scanContext` transients stay at their
    /// defaults here (false / empty) — the off-actor probe path stamps them
    /// onto the returned outcome, which is what removed the last off-actor
    /// VideoRecord mutation. (Swift value-struct return ≈ C++ return-by-value.)
    func lookup(path: String, fileSize: Int64, modDate: Date) -> ProbeOutcome? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        let sql = "SELECT * FROM probe_cache WHERE path = ? AND file_size = ? AND mod_date = ? AND stream_type != 'ffprobe failed'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, modDate.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        var o = ProbeOutcome()
        o.fullPath              = path
        o.filename              = col(stmt, 3)
        o.ext                   = col(stmt, 4)
        o.probe.streamTypeRaw   = col(stmt, 5)
        o.size                  = col(stmt, 6)
        o.sizeBytes             = fileSize
        o.probe.duration        = col(stmt, 7)
        o.probe.durationSeconds = sqlite3_column_double(stmt, 8)
        o.dateCreated           = col(stmt, 9)
        o.dateModified          = col(stmt, 10)
        let dcRaw               = sqlite3_column_double(stmt, 11)
        let dmRaw               = sqlite3_column_double(stmt, 12)
        o.dateCreatedRaw        = dcRaw > 0 ? Date(timeIntervalSince1970: dcRaw) : nil
        o.dateModifiedRaw       = dmRaw > 0 ? Date(timeIntervalSince1970: dmRaw) : nil
        o.probe.container       = col(stmt, 13)
        o.probe.videoCodec      = col(stmt, 14)
        o.probe.resolution      = col(stmt, 15)
        o.probe.frameRate       = col(stmt, 16)
        o.probe.videoBitrate    = col(stmt, 17)
        o.probe.totalBitrate    = col(stmt, 18)
        o.probe.colorSpace      = col(stmt, 19)
        o.probe.bitDepth        = col(stmt, 20)
        o.probe.scanType        = col(stmt, 21)
        o.probe.audioCodec      = col(stmt, 22)
        o.probe.audioChannels   = col(stmt, 23)
        o.probe.audioSampleRate = col(stmt, 24)
        o.probe.timecode        = col(stmt, 25)
        o.probe.tapeName        = col(stmt, 26)
        o.probe.isPlayable      = col(stmt, 27)
        o.partialMD5            = col(stmt, 28)
        o.contentHash           = col(stmt, 31)
        let chAt                = sqlite3_column_double(stmt, 32)
        o.contentHashAt         = chAt > 0 ? Date(timeIntervalSince1970: chAt) : nil
        o.directory             = col(stmt, 29)
        o.notes                 = col(stmt, 30)
        return o
    }

    /// Store a probed outcome in the cache. The transient `wasCacheHit` /
    /// `scanContext` carrier fields are intentionally NOT persisted — only the
    /// stable identity + metadata columns are written (schema unchanged).
    func store(outcome o: ProbeOutcome, fileSize: Int64, modDate: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        let sql = """
            INSERT OR REPLACE INTO probe_cache VALUES (
                ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, o.fullPath)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, modDate.timeIntervalSince1970)
        bind(stmt, 4, o.filename)
        bind(stmt, 5, o.ext)
        bind(stmt, 6, o.probe.streamTypeRaw)
        bind(stmt, 7, o.size)
        bind(stmt, 8, o.probe.duration)
        sqlite3_bind_double(stmt, 9, o.probe.durationSeconds)
        bind(stmt, 10, o.dateCreated)
        bind(stmt, 11, o.dateModified)
        sqlite3_bind_double(stmt, 12, o.dateCreatedRaw?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_double(stmt, 13, o.dateModifiedRaw?.timeIntervalSince1970 ?? 0)
        bind(stmt, 14, o.probe.container)
        bind(stmt, 15, o.probe.videoCodec)
        bind(stmt, 16, o.probe.resolution)
        bind(stmt, 17, o.probe.frameRate)
        bind(stmt, 18, o.probe.videoBitrate)
        bind(stmt, 19, o.probe.totalBitrate)
        bind(stmt, 20, o.probe.colorSpace)
        bind(stmt, 21, o.probe.bitDepth)
        bind(stmt, 22, o.probe.scanType)
        bind(stmt, 23, o.probe.audioCodec)
        bind(stmt, 24, o.probe.audioChannels)
        bind(stmt, 25, o.probe.audioSampleRate)
        bind(stmt, 26, o.probe.timecode)
        bind(stmt, 27, o.probe.tapeName)
        bind(stmt, 28, o.probe.isPlayable)
        bind(stmt, 29, o.partialMD5)
        bind(stmt, 30, o.directory)
        bind(stmt, 31, o.notes)
        bind(stmt, 32, o.contentHash)
        sqlite3_bind_double(stmt, 33, o.contentHashAt?.timeIntervalSince1970 ?? 0)

        sqlite3_step(stmt)
    }

    /// Delete all cached records.
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        sqlite3_exec(db, "DELETE FROM probe_cache", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }

    /// Delete cached records whose path begins with `prefix`. Returns the number deleted.
    /// Used when a scan target is reset/removed so a subsequent scan of the same volume
    /// is forced through ffprobe again instead of returning instantly from cache.
    @discardableResult
    func clearForPathPrefix(_ prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return 0 }
        // Normalize prefix so that "/Volumes/Foo" matches "/Volumes/Foo/..." and not "/Volumes/Foobar/...".
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let like = normalized.replacingOccurrences(of: "%", with: #"\%"#)
                             .replacingOccurrences(of: "_", with: #"\_"#) + "%"

        // First count, then delete (so we can report).
        var stmt: OpaquePointer?
        var deleted = 0
        let countSQL = #"SELECT COUNT(*) FROM probe_cache WHERE path = ? OR path LIKE ? ESCAPE '\'"#
        if sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (prefix as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, (like as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                deleted = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)

        let delSQL = #"DELETE FROM probe_cache WHERE path = ? OR path LIKE ? ESCAPE '\'"#
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, delSQL, -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, (prefix as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(del, 2, (like as NSString).utf8String, -1,
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_step(del)
        }
        sqlite3_finalize(del)
        return deleted
    }

    /// Load every cached record whose path starts with `prefix`. Used to
    /// backfill `model.records` for offline volumes that were scanned by an
    /// earlier build (before catalog.json existed) so the user can still
    /// browse / filter / View-Catalog them when the volume is unmounted.
    func allRecordsWithPrefix(_ prefix: String) -> [VideoRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return [] }
        let normalized = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let like = normalized.replacingOccurrences(of: "%", with: #"\%"#)
                             .replacingOccurrences(of: "_", with: #"\_"#) + "%"
        let sql = #"SELECT * FROM probe_cache WHERE path = ? OR path LIKE ? ESCAPE '\'"#
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (prefix as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, (like as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var out: [VideoRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rec = VideoRecord()
            rec.fullPath        = col(stmt, 0)
            rec.sizeBytes       = sqlite3_column_int64(stmt, 1)
            let modRaw          = sqlite3_column_double(stmt, 2)
            rec.filename        = col(stmt, 3)
            rec.ext             = col(stmt, 4)
            rec.streamTypeRaw   = col(stmt, 5)
            rec.size            = col(stmt, 6)
            rec.duration        = col(stmt, 7)
            rec.durationSeconds = sqlite3_column_double(stmt, 8)
            rec.dateCreated     = col(stmt, 9)
            rec.dateModified    = col(stmt, 10)
            let dcRaw           = sqlite3_column_double(stmt, 11)
            let dmRaw           = sqlite3_column_double(stmt, 12)
            rec.dateCreatedRaw  = dcRaw  > 0 ? Date(timeIntervalSince1970: dcRaw)  : nil
            rec.dateModifiedRaw = dmRaw  > 0 ? Date(timeIntervalSince1970: dmRaw)
                                             : (modRaw > 0 ? Date(timeIntervalSince1970: modRaw) : nil)
            rec.container       = col(stmt, 13)
            rec.videoCodec      = col(stmt, 14)
            rec.resolution      = col(stmt, 15)
            rec.frameRate       = col(stmt, 16)
            rec.videoBitrate    = col(stmt, 17)
            rec.totalBitrate    = col(stmt, 18)
            rec.colorSpace      = col(stmt, 19)
            rec.bitDepth        = col(stmt, 20)
            rec.scanType        = col(stmt, 21)
            rec.audioCodec      = col(stmt, 22)
            rec.audioChannels   = col(stmt, 23)
            rec.audioSampleRate = col(stmt, 24)
            rec.timecode        = col(stmt, 25)
            rec.tapeName        = col(stmt, 26)
            rec.isPlayable      = col(stmt, 27)
            rec.partialMD5      = col(stmt, 28)
            rec.contentHash     = col(stmt, 31)
            let chAt2           = sqlite3_column_double(stmt, 32)
            rec.contentHashAt   = chAt2 > 0 ? Date(timeIntervalSince1970: chAt2) : nil
            rec.directory       = col(stmt, 29)
            rec.notes           = col(stmt, 30)
            out.append(rec)
        }
        return out
    }

    /// Number of cached records.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM probe_cache", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Private Helpers

    private func exec(_ sql: String) {
        guard let db = db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func col(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        if let cstr = sqlite3_column_text(stmt, idx) {
            return String(cString: cstr)
        }
        return ""
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ val: String) {
        sqlite3_bind_text(
            stmt, idx, (val as NSString).utf8String, -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }
}
