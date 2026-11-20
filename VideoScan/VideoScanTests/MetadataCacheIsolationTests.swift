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

    /// The guard's ONLY look at the real store: stat the db, its -wal and
    /// its -shm — name → "size@mtime", absent files absent. It never opens
    /// the database: an open writes the -shm and, as the last connection,
    /// checkpoints a pending WAL into the main file (2026-11-20; pinned by
    /// `realStoreProbeOpensNothing`). Any write by a cache that wrongly
    /// opened the real path lands in the -wal (or creates it) or the db, so
    /// comparing db + -wal before/after still catches the leak.
    static func realStoreProbe(dbPath: String) -> [String: String] {
        var out: [String: String] = [:]
        for suffix in ["", "-wal", "-shm"] {
            guard let a = try? FileManager.default.attributesOfItem(atPath: dbPath + suffix) else { continue }
            out["db" + suffix] = "\((a[.size] as? NSNumber)?.int64Value ?? -1)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
        }
        return out
    }

    // Carrier-based (step 4): the cache API now trafficks in the Sendable
    // ProbeOutcome value, not VideoRecord. Identity fields live top-level;
    // the 19 ffprobe fields live under `.probe`.
    private static func makeCanaryOutcome(path: String) -> ProbeOutcome {
        var o = ProbeOutcome()
        o.fullPath = path
        o.filename = (path as NSString).lastPathComponent
        o.ext = "mov"
        o.probe.streamTypeRaw = "Video + Audio"
        o.probe.duration = "00:00:01"
        o.probe.durationSeconds = 1.0
        return o
    }

    // MARK: - (a) Default init must not touch the real database

    @Test("default-init MetadataCache never writes to the real Application Support sqlite")
    func defaultInitDoesNotWriteRealDB() throws {
        let realPath = Self.realDBPath
        // db + -wal only: the -shm moves whenever any reader looks (Rick's
        // app), and holds no data (same rule as AppSupportSnapshot).
        func realWritten() -> [String: String] { Self.realStoreProbe(dbPath: realPath).filter { $0.key != "db-shm" } }
        let realBefore = realWritten()

        let cache = MetadataCache()
        // Refuse BEFORE any write if the gate regressed: this test must
        // never be the thing that writes Rick's real cache.
        try #require(cache.dbPath != realPath,
                     "MetadataCache() default init resolved to the REAL metadata_cache.sqlite — refusing to write a canary")
        let canary = "/tmp/metacache-canary-\(UUID().uuidString).mov"
        defer { cache.clearForPathPrefix(canary) }

        cache.store(outcome: Self.makeCanaryOutcome(path: canary),
                    fileSize: 1234,
                    modDate: Date(timeIntervalSince1970: 1_000_000))

        // Round-trip through the same instance so the failure below can't
        // be a vacuous "store() did nothing at all".
        #expect(cache.lookup(path: canary, fileSize: 1234,
                             modDate: Date(timeIntervalSince1970: 1_000_000)) != nil,
                "Precondition failed: store()/lookup() round-trip broken — isolation assertion would be vacuous")

        #expect(realWritten() == realBefore,
                "the REAL metadata_cache.sqlite (db or -wal) changed under test: \(realBefore) -> \(realWritten())")
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

    // MARK: - (a2) The guard's own look at the real store must open nothing

    /// REGRESSION (2026-11-20, full Release run on the M5 Ultra): the guard
    /// above used to OPEN the user's real metadata_cache.sqlite read-write to
    /// count canary rows. Opening a WAL database writes its -shm (seen: real
    /// -shm mtime 13:01:55, the second this suite ran) and, as the last
    /// connection, CHECKPOINTS a pending WAL into the main file on close — a
    /// test writing Rick's real cache in order to prove tests don't. The
    /// guard's look at the real store (`realStoreProbe`) must leave every
    /// byte and mtime of db / -wal / -shm as it found them. Proved here on a
    /// scratch WAL store with a pending WAL, so the real one is never at risk.
    @Test("the guard's probe of the real store leaves a WAL database's db, -wal and -shm untouched")
    func realStoreProbeOpensNothing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metacache-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("metadata_cache.sqlite").path

        // A store shaped like the real one when the app stopped without a
        // final checkpoint: WAL mode, a committed frame still in the -wal,
        // -shm present. Made by copying a live writer's three files while
        // its connection is still open (the writer's own close would
        // checkpoint), then closing the writer on the original.
        let live = dir.appendingPathComponent("live.sqlite").path
        var db: OpaquePointer?
        try #require(sqlite3_open(live, &db) == SQLITE_OK)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE probe_cache (path TEXT)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO probe_cache VALUES ('/x.mov')", nil, nil, nil)
        for suffix in ["", "-wal", "-shm"] {
            try FileManager.default.copyItem(atPath: live + suffix, toPath: path + suffix)
        }
        sqlite3_close(db)
        let before = Self.realStoreProbe(dbPath: path)
        try #require(before["db-wal"] != nil && before["db"] != nil,
                     "precondition: a pending WAL must exist, else the test proves nothing: \(before)")

        Thread.sleep(forTimeInterval: 0.05)   // mtime resolution: a touch must read differently
        _ = Self.realStoreProbe(dbPath: path)   // the guard's look, exactly as it is run against the real store

        #expect(Self.realStoreProbe(dbPath: path) == before,
                "the guard's probe changed the store on disk: \(before) -> \(Self.realStoreProbe(dbPath: path))")
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
        writer.store(outcome: Self.makeCanaryOutcome(path: canary),
                     fileSize: 5678, modDate: modDate)
        #expect(FileManager.default.fileExists(atPath: path),
                "Injected db file was not created at the explicit path")

        // Fresh instance against the same file proves the write hit disk,
        // not just an in-memory connection.
        let reader = MetadataCache(path: path)
        let outcome = try #require(reader.lookup(path: canary, fileSize: 5678, modDate: modDate),
                                   "Record stored via injected path not found by a second connection")
        #expect(outcome.fullPath == canary)
        #expect(outcome.probe.streamTypeRaw == "Video + Audio")
        #expect(outcome.probe.durationSeconds == 1.0)
        // Carrier transients are NOT persisted — a fresh lookup defaults them.
        #expect(outcome.wasCacheHit == false)

        // Negative: a changed file size must miss (cache key contract).
        #expect(reader.lookup(path: canary, fileSize: 9999, modDate: modDate) == nil,
                "lookup() matched despite different fileSize — cache key is broken")
    }

    // MARK: - (c) Cache-hit path sets wasCacheHit through the carrier

    /// REGRESSION (step 4 carrier): the off-actor probe path used to do
    /// `cached.wasCacheHit = true; cached.scanContext = …` directly on a
    /// VideoRecord returned by `MetadataCache.lookup`. The cache now returns the
    /// Sendable `ProbeOutcome`, and `probeFileOutcome` stamps the transients
    /// onto the carrier before the VideoRecord is built on the main actor. This
    /// pins that a pre-seeded file comes back as a cache hit with its cached
    /// metadata intact and WITHOUT invoking ffprobe.
    @MainActor
    @Test("cache hit returns wasCacheHit=true with cached metadata, no ffprobe")
    func cacheHitSetsWasCacheHitThroughCarrier() async throws {
        let model = VideoScanModel()

        // A real, tiny file so probeFile's existence check passes and we reach
        // the cache lookup. Contents are irrelevant — we pre-seed the cache so
        // ffprobe is never consulted (and the bytes aren't valid media anyway).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metacache-hit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("clip.mov")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: fileURL)

        // Cache key = (path, size, modDate). Read them back exactly as
        // probeFileOutcome will so the lookup hits.
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? .distantPast

        var seed = Self.makeCanaryOutcome(path: fileURL.path)
        seed.probe.resolution = "1920x1080"
        model.metadataCache.store(outcome: seed, fileSize: size, modDate: modDate)

        let rec = await model.probeFile(url: fileURL)

        #expect(rec.wasCacheHit == true,
                "Cache-hit path did not set wasCacheHit on the carrier")
        #expect(rec.streamTypeRaw == "Video + Audio",
                "Cache-hit record lost cached metadata — ffprobe may have overwritten it")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.durationSeconds == 1.0)
        // Negative control: a never-cached file must NOT report a cache hit.
        let missURL = dir.appendingPathComponent("uncached.mov")
        try Data([0x09]).write(to: missURL)
        let missRec = await model.probeFile(url: missURL)
        #expect(missRec.wasCacheHit == false,
                "Uncached file falsely reported wasCacheHit")
    }
}
