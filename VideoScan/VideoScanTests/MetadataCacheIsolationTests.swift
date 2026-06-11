import Testing
import Foundation
import SQLite3
@testable import VideoScan

// Validates the test-isolation seam in MetadataCache: constructing the
// cache (directly or via VideoScanModel) under a unit-test host must NEVER
// open Rick's real ~/Library/Application Support/VideoScan/metadata_cache.sqlite.
//
// Same failure class as the Settings-pollution incident and the
// ScanJobsStorage leak covered by TestIsolationTests — ~205 test call sites
// construct VideoScanModel(), each of which builds a MetadataCache.
@Suite("MetadataCache test isolation")
struct MetadataCacheIsolationTests {

    // MARK: - Helpers

    /// The user's REAL production probe-cache path.
    private static var realDBPath: String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("metadata_cache.sqlite").path
    }

    /// Count rows in the REAL sqlite file matching `path`, via an
    /// independent connection (so we see what's actually on disk, WAL
    /// included). Returns 0 if the file doesn't exist or has no
    /// probe_cache table.
    private static func realDBRowCount(forPath path: String) -> Int {
        guard FileManager.default.fileExists(atPath: realDBPath) else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open(realDBPath, &db) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM probe_cache WHERE path = ?", -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private static func makeCanaryRecord(path: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.fullPath = path
        rec.filename = (path as NSString).lastPathComponent
        rec.ext = "mov"
        rec.streamTypeRaw = "Video + Audio"
        rec.duration = "00:00:01"
        rec.durationSeconds = 1.0
        return rec
    }

    // MARK: - (a) Default init must not touch the real database

    @Test("default-init MetadataCache never writes to the real Application Support sqlite")
    func defaultInitDoesNotWriteRealDB() throws {
        let realPath = Self.realDBPath
        let mtimeBefore = (try? FileManager.default
            .attributesOfItem(atPath: realPath)[.modificationDate]) as? Date

        let canary = "/tmp/metacache-canary-\(UUID().uuidString).mov"
        let cache = MetadataCache()
        // Self-cleaning: removes the canary from whichever db the cache
        // actually opened (real one pre-fix, sandbox post-fix).
        defer { cache.clearForPathPrefix(canary) }

        cache.store(record: Self.makeCanaryRecord(path: canary),
                    fileSize: 1234,
                    modDate: Date(timeIntervalSince1970: 1_000_000))

        // Round-trip through the same instance so the failure below can't
        // be a vacuous "store() did nothing at all".
        #expect(cache.lookup(path: canary, fileSize: 1234,
                             modDate: Date(timeIntervalSince1970: 1_000_000)) != nil,
                "Precondition failed: store()/lookup() round-trip broken — isolation assertion would be vacuous")

        #expect(Self.realDBRowCount(forPath: canary) == 0,
                "MetadataCache() default init wrote a row into the user's REAL metadata_cache.sqlite")

        if let mtimeBefore {
            let mtimeAfter = (try? FileManager.default
                .attributesOfItem(atPath: realPath)[.modificationDate]) as? Date
            #expect(mtimeAfter == mtimeBefore,
                    "Real metadata_cache.sqlite mtime changed under test (\(String(describing: mtimeBefore)) -> \(String(describing: mtimeAfter)))")
        }
    }

    @Test("default path under test resolves to the per-PID sandbox, not Application Support")
    func defaultPathUnderTestIsSandboxed() throws {
        let cache = MetadataCache()
        let appSupportURL = try #require(
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            "Application Support URL unavailable — macOS API contract violated"
        )
        #expect(cache.dbPath != Self.realDBPath,
                "Default MetadataCache opened the real production path")
        #expect(!cache.dbPath.hasPrefix(appSupportURL.path),
                "Default MetadataCache path leaked into Application Support: \(cache.dbPath)")

        let pidMarker = "VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)"
        #expect(cache.dbPath.contains(pidMarker),
                "Default MetadataCache path missing per-PID sandbox marker '\(pidMarker)': \(cache.dbPath)")
    }

    @MainActor
    @Test("VideoScanModel's metadataCache is sandboxed under test")
    func videoScanModelCacheIsSandboxed() throws {
        let model = VideoScanModel()
        let appSupportURL = try #require(
            FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first,
            "Application Support URL unavailable — macOS API contract violated"
        )
        #expect(!model.metadataCache.dbPath.hasPrefix(appSupportURL.path),
                "VideoScanModel's metadataCache opened a db inside Application Support: \(model.metadataCache.dbPath)")
    }

    // MARK: - (b) Explicit injection bypasses the gate and round-trips

    @Test("explicit path injection gets exactly that path and round-trips a record")
    func explicitPathInjectionRoundTrips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metacache-inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("explicit.sqlite").path

        let canary = "/tmp/metacache-inject-canary-\(UUID().uuidString).mov"
        let modDate = Date(timeIntervalSince1970: 2_000_000)

        let writer = MetadataCache(path: path)
        #expect(writer.dbPath == path,
                "Explicit injection was redirected — gate must apply to the default only")
        writer.store(record: Self.makeCanaryRecord(path: canary),
                     fileSize: 5678, modDate: modDate)
        #expect(FileManager.default.fileExists(atPath: path),
                "Injected db file was not created at the explicit path")

        // Fresh instance against the same file proves the write hit disk,
        // not just an in-memory connection.
        let reader = MetadataCache(path: path)
        let rec = try #require(reader.lookup(path: canary, fileSize: 5678, modDate: modDate),
                               "Record stored via injected path not found by a second connection")
        #expect(rec.fullPath == canary)
        #expect(rec.streamTypeRaw == "Video + Audio")
        #expect(rec.durationSeconds == 1.0)

        // Negative: a changed file size must miss (cache key contract).
        #expect(reader.lookup(path: canary, fileSize: 9999, modDate: modDate) == nil,
                "lookup() matched despite different fileSize — cache key is broken")
    }
}
