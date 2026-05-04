import Foundation
import SQLite3

/// Persistent SQLite cache of Person Finder scan results.
/// Keyed by (videoPath, fileSize, modDate, personName, engine, threshold, refPhotosHash).
/// If a video hasn't changed and the scan parameters match, we skip the expensive
/// face-recognition pass entirely and return cached segments.
/// Stored at ~/Library/Application Support/VideoScan/personfinder_cache.sqlite.
final class PersonFinderCache {
    private var db: OpaquePointer?
    private let lock = NSLock()

    static let shared = PersonFinderCache()

    private static var dbPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personfinder_cache.sqlite").path
    }

    init() {
        guard sqlite3_open(Self.dbPath, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS pf_cache (
                video_path TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                mod_date REAL NOT NULL,
                person_name TEXT NOT NULL,
                engine TEXT NOT NULL,
                threshold REAL NOT NULL,
                ref_hash TEXT NOT NULL,
                duration_seconds REAL,
                fps REAL,
                total_hits INTEGER,
                segments_json TEXT,
                cached_at REAL,
                PRIMARY KEY (video_path, file_size, mod_date, person_name, engine, threshold, ref_hash)
            )
        """)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Cache Key

    struct CacheKey {
        let videoPath: String
        let fileSize: Int64
        let modDate: Date
        let personName: String
        let engine: String
        let threshold: Float
        let refHash: String
    }

    static func makeKey(
        videoPath: String,
        personName: String,
        engine: RecognitionEngine,
        threshold: Float,
        refFilenames: [String]
    ) -> CacheKey? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: videoPath, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        guard let attrs = try? fm.attributesOfItem(atPath: videoPath),
              let fileSize = attrs[.size] as? Int64,
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        let refHash = stableHash(refFilenames)
        return CacheKey(
            videoPath: videoPath,
            fileSize: fileSize,
            modDate: modDate,
            personName: personName.lowercased(),
            engine: engine.rawValue,
            threshold: threshold,
            refHash: refHash
        )
    }

    private static func stableHash(_ filenames: [String]) -> String {
        let joined = filenames.sorted().joined(separator: "|")
        var hasher = Hasher()
        hasher.combine(joined)
        return String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    // MARK: - Lookup

    func lookup(key: CacheKey) -> pfVideoResult? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        let sql = """
            SELECT duration_seconds, fps, total_hits, segments_json
            FROM pf_cache
            WHERE video_path = ? AND file_size = ? AND mod_date = ?
              AND person_name = ? AND engine = ? AND threshold = ? AND ref_hash = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, key.videoPath)
        sqlite3_bind_int64(stmt, 2, key.fileSize)
        sqlite3_bind_double(stmt, 3, key.modDate.timeIntervalSince1970)
        bind(stmt, 4, key.personName)
        bind(stmt, 5, key.engine)
        sqlite3_bind_double(stmt, 6, Double(key.threshold))
        bind(stmt, 7, key.refHash)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let duration = sqlite3_column_double(stmt, 0)
        let fps = sqlite3_column_double(stmt, 1)
        let totalHits = Int(sqlite3_column_int(stmt, 2))
        let segJson = col(stmt, 3)

        let segments = decodeSegments(segJson)
        let filename = (key.videoPath as NSString).lastPathComponent
        return pfVideoResult(
            filename: filename,
            filePath: key.videoPath,
            durationSeconds: duration,
            fps: fps,
            totalHits: totalHits,
            segments: segments
        )
    }

    // MARK: - Store

    func store(key: CacheKey, result: pfVideoResult) {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        let sql = """
            INSERT OR REPLACE INTO pf_cache VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bind(stmt, 1, key.videoPath)
        sqlite3_bind_int64(stmt, 2, key.fileSize)
        sqlite3_bind_double(stmt, 3, key.modDate.timeIntervalSince1970)
        bind(stmt, 4, key.personName)
        bind(stmt, 5, key.engine)
        sqlite3_bind_double(stmt, 6, Double(key.threshold))
        bind(stmt, 7, key.refHash)
        sqlite3_bind_double(stmt, 8, result.durationSeconds)
        sqlite3_bind_double(stmt, 9, result.fps)
        sqlite3_bind_int(stmt, 10, Int32(result.totalHits))
        bind(stmt, 11, encodeSegments(result.segments))
        sqlite3_bind_double(stmt, 12, Date().timeIntervalSince1970)

        sqlite3_step(stmt)
    }

    // MARK: - Maintenance

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return }
        sqlite3_exec(db, "DELETE FROM pf_cache", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pf_cache", -1, &stmt, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Segment JSON encoding

    private func encodeSegments(_ segments: [pfSegment]) -> String {
        let arr: [[String: Any]] = segments.map { seg in
            [
                "s": seg.startSecs,
                "e": seg.endSecs,
                "bd": seg.bestDistance,
                "ad": seg.avgDistance
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    private func decodeSegments(_ json: String) -> [pfSegment] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { dict in
            guard let s = dict["s"] as? Double,
                  let e = dict["e"] as? Double,
                  let bd = dict["bd"] as? Double,
                  let ad = dict["ad"] as? Double else { return nil }
            return pfSegment(startSecs: s, endSecs: e, bestDistance: Float(bd), avgDistance: Float(ad))
        }
    }

    // MARK: - SQLite helpers

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
