import Foundation
import SQLite3

/// Persistent SQLite cache of ffprobe metadata.
/// Keyed by (path, fileSize, modDate) — if a file hasn't changed, we skip ffprobe entirely.
/// Stored at ~/Library/Application Support/VideoScan/metadata_cache.sqlite.
/// Thread-safe: NSLock serializes all SQLite access so probeFile can run off the main thread.
final class MetadataCache {
    private var db: OpaquePointer?
    private let lock = NSLock()

    private static var dbPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata_cache.sqlite").path
    }

    init() {
        guard sqlite3_open(Self.dbPath, &db) == SQLITE_OK else {
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
                PRIMARY KEY (path, file_size, mod_date)
            )
        """)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Look up a cached record. Returns nil if not found or file has changed.
    func lookup(path: String, fileSize: Int64, modDate: Date) -> VideoRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        let sql = "SELECT * FROM probe_cache WHERE path = ? AND file_size = ? AND mod_date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, modDate.timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let rec = VideoRecord()
        rec.fullPath        = path
        rec.filename        = col(stmt, 3)
        rec.ext             = col(stmt, 4)
        rec.streamTypeRaw   = col(stmt, 5)
        rec.size            = col(stmt, 6)
        rec.sizeBytes       = fileSize
        rec.duration        = col(stmt, 7)
        rec.durationSeconds = sqlite3_column_double(stmt, 8)
        rec.dateCreated     = col(stmt, 9)
        rec.dateModified    = col(stmt, 10)
        let dcRaw           = sqlite3_column_double(stmt, 11)
        let dmRaw           = sqlite3_column_double(stmt, 12)
        rec.dateCreatedRaw  = dcRaw > 0 ? Date(timeIntervalSince1970: dcRaw) : nil
        rec.dateModifiedRaw = dmRaw > 0 ? Date(timeIntervalSince1970: dmRaw) : nil
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
        rec.directory       = col(stmt, 29)
        rec.notes           = col(stmt, 30)
        return rec
    }

    /// Store a probed record in the cache.
    func store(record rec: VideoRecord, fileSize: Int64, modDate: Date) {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        let sql = """
            INSERT OR REPLACE INTO probe_cache VALUES (
                ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1,  rec.fullPath)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, modDate.timeIntervalSince1970)
        bind(stmt, 4,  rec.filename)
        bind(stmt, 5,  rec.ext)
        bind(stmt, 6,  rec.streamTypeRaw)
        bind(stmt, 7,  rec.size)
        bind(stmt, 8,  rec.duration)
        sqlite3_bind_double(stmt, 9, rec.durationSeconds)
        bind(stmt, 10, rec.dateCreated)
        bind(stmt, 11, rec.dateModified)
        sqlite3_bind_double(stmt, 12, rec.dateCreatedRaw?.timeIntervalSince1970 ?? 0)
        sqlite3_bind_double(stmt, 13, rec.dateModifiedRaw?.timeIntervalSince1970 ?? 0)
        bind(stmt, 14, rec.container)
        bind(stmt, 15, rec.videoCodec)
        bind(stmt, 16, rec.resolution)
        bind(stmt, 17, rec.frameRate)
        bind(stmt, 18, rec.videoBitrate)
        bind(stmt, 19, rec.totalBitrate)
        bind(stmt, 20, rec.colorSpace)
        bind(stmt, 21, rec.bitDepth)
        bind(stmt, 22, rec.scanType)
        bind(stmt, 23, rec.audioCodec)
        bind(stmt, 24, rec.audioChannels)
        bind(stmt, 25, rec.audioSampleRate)
        bind(stmt, 26, rec.timecode)
        bind(stmt, 27, rec.tapeName)
        bind(stmt, 28, rec.isPlayable)
        bind(stmt, 29, rec.partialMD5)
        bind(stmt, 30, rec.directory)
        bind(stmt, 31, rec.notes)

        sqlite3_step(stmt)
    }

    /// Delete all cached records.
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        sqlite3_exec(db, "DELETE FROM probe_cache", nil, nil, nil)
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
