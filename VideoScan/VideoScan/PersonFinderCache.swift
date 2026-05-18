import Foundation
import SQLite3
import os

private let cacheLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "cache")

/// Persistent SQLite cache of Person Finder scan results.
/// Keyed by (videoPath, fileSize, modDate, personName, engine, threshold, refPhotosHash).
/// If a video hasn't changed and the scan parameters match, we skip the expensive
/// face-recognition pass entirely and return cached segments.
/// Stored at ~/Library/Application Support/VideoScan/personfinder_cache.sqlite.
final class PersonFinderCache {
    private var db: OpaquePointer?
    private let lock = NSLock()

    static let shared = PersonFinderCache()

    private var hitCount = 0
    private var missCount = 0

    func resetStats() {
        lock.lock(); defer { lock.unlock() }
        hitCount = 0
        missCount = 0
    }

    func logSummary() {
        lock.lock()
        let h = hitCount, m = missCount
        lock.unlock()
        let total = h + m
        guard total > 0 else { return }
        let pct = String(format: "%.1f", Double(h) / Double(total) * 100)
        cacheLog.notice("Cache summary: \(h) hits, \(m) misses (\(pct)% hit rate)")
    }

    private static var dbPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("personfinder_cache.sqlite").path
    }

    init(path: String? = nil) {
        let dbPath = path ?? Self.dbPath
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            cacheLog.error("Failed to open cache DB at \(dbPath, privacy: .public)")
            db = nil
            return
        }
        cacheLog.info("Cache opened: \(dbPath, privacy: .public)")
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
        let refHash = cachedRefHash(refFilenames)
        cacheLog.debug("makeKey: refHash=\(refHash, privacy: .public) refs=\(refFilenames.count) person=\(personName, privacy: .public) engine=\(engine.rawValue, privacy: .public)")
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

    private static var refHashCache: [String: String] = [:]
    private static let refHashLock = NSLock()

    static func cachedRefHash(_ refFilenames: [String]) -> String {
        let fm = FileManager.default
        let cacheKey = refFilenames.sorted().map { path -> String in
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let sz = attrs[.size] as? Int64,
               let mod = attrs[.modificationDate] as? Date {
                return "\(path)\t\(sz)\t\(mod.timeIntervalSince1970)"
            }
            return path
        }.joined(separator: "\n")

        refHashLock.lock()
        if let cached = refHashCache[cacheKey] {
            refHashLock.unlock()
            return cached
        }
        refHashLock.unlock()
        let result = stableHash(refFilenames)
        refHashLock.lock()
        refHashCache[cacheKey] = result
        refHashLock.unlock()
        return result
    }

    private static func stableHash(_ refs: [String]) -> String {
        let tokens = refs.map(referenceHashToken).sorted()
        let joined = tokens.joined(separator: "|")
        return fnv1a(Array(joined.utf8))
    }

    private static func referenceHashToken(_ ref: String) -> String {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: ref, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: URL(fileURLWithPath: ref)) else {
            return "name:\(ref)"
        }

        let h = data.withUnsafeBytes { buf -> UInt64 in
            var h: UInt64 = 0xcbf29ce484222325
            for byte in buf {
                h ^= UInt64(byte)
                h &*= 0x100000001b3
            }
            return h
        }
        let filename = (ref as NSString).lastPathComponent
        return "file:\(filename):\(data.count):\(String(format: "%016llx", h))"
    }

    private static func fnv1a(_ bytes: [UInt8]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return String(format: "%016llx", h)
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

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            missCount += 1
            cacheLog.debug("MISS: \((key.videoPath as NSString).lastPathComponent, privacy: .public) refHash=\(key.refHash, privacy: .public)")
            return nil
        }

        let duration = sqlite3_column_double(stmt, 0)
        let fps = sqlite3_column_double(stmt, 1)
        let totalHits = Int(sqlite3_column_int(stmt, 2))
        let segJson = col(stmt, 3)

        let segments = decodeSegments(segJson)
        hitCount += 1
        let filename = (key.videoPath as NSString).lastPathComponent
        cacheLog.debug("HIT: \(filename, privacy: .public) hits=\(totalHits)")
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

    // MARK: - Cache-miss diagnostics

    /// Summary of a cached row, excluding the heavy result payload. Used to
    /// answer "why did the cache miss for this video on the current search?"
    /// by surfacing the keys that DO exist.
    struct CachedRowSummary: Equatable {
        let personName: String
        let engine: String
        let threshold: Float
        let refHash: String
        let cachedAt: Date
    }

    /// Returns all cached rows for the given video file (matched on path +
    /// size + modDate), regardless of search parameters. If the array is
    /// empty, the file has never been cached. If non-empty, each entry shows
    /// the search params under which the file WAS cached — letting us
    /// diff against the current search to explain a miss.
    func cachedRowsForVideo(videoPath: String, fileSize: Int64, modDate: Date) -> [CachedRowSummary] {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return [] }
        let sql = """
            SELECT person_name, engine, threshold, ref_hash, cached_at
            FROM pf_cache
            WHERE video_path = ? AND file_size = ? AND mod_date = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, videoPath)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, modDate.timeIntervalSince1970)

        var rows: [CachedRowSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(CachedRowSummary(
                personName: col(stmt, 0),
                engine: col(stmt, 1),
                threshold: Float(sqlite3_column_double(stmt, 2)),
                refHash: col(stmt, 3),
                cachedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return rows
    }

    /// Builds a human-readable explanation of why the cache missed for the
    /// current search params, given any rows that exist for the sample
    /// video. Pure function — no I/O — so it's the unit-testable surface.
    static func cacheMissDiagnostic(
        currentPersonName: String,
        currentEngine: String,
        currentThreshold: Float,
        currentRefHash: String,
        cachedRows: [CachedRowSummary]
    ) -> String {
        guard !cachedRows.isEmpty else {
            return "no prior cache rows for these files — first scan of this volume"
        }
        let lcPerson = currentPersonName.lowercased()
        // Look for any row that matches everything EXCEPT one field — that
        // field is the most likely cause of the miss.
        for row in cachedRows {
            let personMatches = row.personName == lcPerson
            let engineMatches = row.engine == currentEngine
            let thresholdMatches = abs(row.threshold - currentThreshold) < 1e-6
            let refMatches = row.refHash == currentRefHash
            switch (personMatches, engineMatches, thresholdMatches, refMatches) {
            case (true, true, true, false):
                return "reference photos changed (cached refHash=\(row.refHash), current=\(currentRefHash))"
            case (true, true, false, true):
                return "threshold differs (cached=\(row.threshold), current=\(currentThreshold))"
            case (true, false, true, true):
                return "engine differs (cached=\(row.engine), current=\(currentEngine))"
            case (false, true, true, true):
                return "person name differs (cached=\(row.personName), current=\(lcPerson))"
            default:
                continue
            }
        }
        // No single-field mismatch found — multiple fields differ. Summarize
        // what's stored so the user can see what was last scanned.
        let firstRow = cachedRows[0]
        let extra = cachedRows.count > 1 ? " (+\(cachedRows.count - 1) other row(s))" : ""
        return "multiple key fields differ; latest cached row had person=\(firstRow.personName), engine=\(firstRow.engine), threshold=\(firstRow.threshold), refHash=\(firstRow.refHash)\(extra)"
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
