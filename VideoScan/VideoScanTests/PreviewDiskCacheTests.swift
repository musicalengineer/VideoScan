// PreviewDiskCacheTests.swift
// LOGIC + SCALE + ISOLATION + SENSOR dimensions for the persistent
// preview disk cache (perf/preview-disk-cache commit 1, 2026-07-26).
//
// Every test uses an injected per-test temp root — the production
// App Support directory is never touched (and the isolation tests
// assert exactly that, both for the injected-root path and for the
// productionRootURL test-host redirect that guards the ~200 test sites
// constructing VideoScanModel()).
//
// SCALE note — the over-cap prune: sizeCapBytes is a static let of
// 2 GB, not injectable, and honestly writing 2 GB in a unit test is
// off the table. The over-cap test instead builds APFS SPARSE files
// (seek + one byte → logical size 512 MB, physical size ~one block;
// for Rick: lseek(2) past EOF + write(2), the classic sparse-file
// idiom) — the prune reads LOGICAL sizes via .fileSizeKey, so it sees
// 2.5 GB and must reap exactly the oldest file to get back under cap.
// Real disk usage: a few KB.

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScan

@Suite("PreviewDiskCache", .serialized)
struct PreviewDiskCacheTests {

    // MARK: - Per-test root

    /// Fresh injected root per call — under NSTemporaryDirectory, never
    /// App Support. Caller removes it via defer.
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_previewcache_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The REAL production preview-cache directory (what a non-test
    /// process would use) — snapshotted around tests to prove isolation.
    private var realAppSupportCacheDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("preview-cache", isDirectory: true)
    }

    private struct DirSnapshot: Equatable {
        let exists: Bool
        let entryCount: Int
        let mtime: Date?
    }

    private func snapshot(_ dir: URL) -> DirSnapshot {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: dir.path)
        let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let mtime = (try? fm.attributesOfItem(atPath: dir.path))?[.modificationDate] as? Date
        return DirSnapshot(exists: exists, entryCount: entries.count, mtime: mtime)
    }

    // MARK: - cacheKey (LOGIC, pure)

    @Test("cacheKey is deterministic 64-char SHA256 hex")
    func cacheKeyDeterministic() {
        let a = PreviewDiskCache.cacheKey(path: "/Volumes/V/tape.mkv", mtime: 1_700_000_000, size: 42_000)
        let b = PreviewDiskCache.cacheKey(path: "/Volumes/V/tape.mkv", mtime: 1_700_000_000, size: 42_000)
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test("cacheKey truncates mtime to whole seconds; path/size/second changes rekey")
    func cacheKeyMtimeTruncation() {
        let base = PreviewDiskCache.cacheKey(path: "/v/f.mkv", mtime: 12.0, size: 100)
        // Sub-second jitter (SMB vs APFS timestamp precision) must NOT
        // change the key…
        #expect(PreviewDiskCache.cacheKey(path: "/v/f.mkv", mtime: 12.3, size: 100) == base)
        #expect(PreviewDiskCache.cacheKey(path: "/v/f.mkv", mtime: 12.999, size: 100) == base)
        // …but a whole-second change, a size change, or a path change must.
        #expect(PreviewDiskCache.cacheKey(path: "/v/f.mkv", mtime: 13.0, size: 100) != base)
        #expect(PreviewDiskCache.cacheKey(path: "/v/f.mkv", mtime: 12.0, size: 101) != base)
        #expect(PreviewDiskCache.cacheKey(path: "/v/g.mkv", mtime: 12.0, size: 100) != base)
    }

    @Test("fileSignature stats real files and returns nil for vanished paths")
    func fileSignatureBasics() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("media.bin")
        try Data(count: 1234).write(to: file)

        let sig = try #require(PreviewDiskCache.fileSignature(atPath: file.path))
        #expect(sig.size == 1234)
        #expect(abs(sig.mtime - Date().timeIntervalSince1970) < 60)

        #expect(PreviewDiskCache.fileSignature(atPath: root.appendingPathComponent("gone").path) == nil)
    }

    // MARK: - Store / lookup round trip (LOGIC)

    @Test("store→lookup round trip returns the payload; changed signature misses")
    func roundTripAndSignatureMiss() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let blue = PreviewTestImages.solid(red: 0, green: 0, blue: 1)

        cache.store(blue, path: "/v/tape.mkv", mtime: 100, size: 5000, tier: .fast)

        let hit = try #require(cache.lookup(path: "/v/tape.mkv", mtime: 100, size: 5000))
        #expect(hit.width == blue.width && hit.height == blue.height)
        // Payload survives the JPEG round trip recognizably.
        let mean = PreviewTestImages.meanRGB(hit)
        #expect(mean.b > 200 && mean.r < 60 && mean.g < 60,
                "round-tripped payload should still be blue, got \(mean)")
        #expect(cache.storedTier(path: "/v/tape.mkv", mtime: 100, size: 5000) == .fast)

        // A modified file (mtime or size moved) misses — the automatic
        // invalidation the whole design leans on.
        #expect(cache.lookup(path: "/v/tape.mkv", mtime: 101, size: 5000) == nil)
        #expect(cache.lookup(path: "/v/tape.mkv", mtime: 100, size: 5001) == nil)
        #expect(cache.storedTier(path: "/v/tape.mkv", mtime: 101, size: 5000) == nil)
    }

    @Test("oversized frames are re-encoded to ≤480 on the longest edge")
    func payloadCappedAt480() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        // Defensive-path check: both generators already cap at 480, so
        // feed the cache something bigger on purpose.
        let big = PreviewTestImages.gradient(width: 1920, height: 1080)

        cache.store(big, path: "/v/big.mov", mtime: 1, size: 1, tier: .fast)

        let hit = try #require(cache.lookup(path: "/v/big.mov", mtime: 1, size: 1))
        #expect(max(hit.width, hit.height) <= PreviewDiskCache.maxPayloadDimension,
                "payload is \(hit.width)x\(hit.height) — 480 cap not enforced")
        // Aspect preserved (16:9 → 480x270).
        #expect(hit.width == 480 && hit.height == 270)
    }

    // MARK: - Tier contract (LOGIC)

    @Test("store(.fast) is a no-op when a best payload exists — best never downgrades")
    func fastNeverOverwritesBest() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let blue = PreviewTestImages.solid(red: 0, green: 0, blue: 1)
        let red = PreviewTestImages.solid(red: 1, green: 0, blue: 0)

        cache.store(blue, path: "/v/t.mkv", mtime: 5, size: 9, tier: .best)
        // Interactive fast frame arriving AFTER the background upgrade:
        cache.store(red, path: "/v/t.mkv", mtime: 5, size: 9, tier: .fast)

        #expect(cache.storedTier(path: "/v/t.mkv", mtime: 5, size: 9) == .best)
        let hit = try #require(cache.lookup(path: "/v/t.mkv", mtime: 5, size: 9))
        let mean = PreviewTestImages.meanRGB(hit)
        #expect(mean.b > 200 && mean.r < 60, "best (blue) was downgraded to fast (red): \(mean)")
        // And the dropped fast store must not have left a payload file.
        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 5, size: 9)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(key)-fast.jpg").path))
    }

    @Test("store(.best) reaps the superseded fast payload")
    func bestReapsFast() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let red = PreviewTestImages.solid(red: 1, green: 0, blue: 0)
        let blue = PreviewTestImages.solid(red: 0, green: 0, blue: 1)
        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 5, size: 9)
        let fm = FileManager.default

        cache.store(red, path: "/v/t.mkv", mtime: 5, size: 9, tier: .fast)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("\(key)-fast.jpg").path))

        cache.store(blue, path: "/v/t.mkv", mtime: 5, size: 9, tier: .best)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("\(key)-best.jpg").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("\(key)-fast.jpg").path),
                "superseded fast payload not reaped — same frame stored twice")
        #expect(cache.storedTier(path: "/v/t.mkv", mtime: 5, size: 9) == .best)
    }

    @Test("lookup prefers best when both tiers exist on disk")
    func lookupPrefersBest() throws {
        // store() can't produce this state (best reaps fast) — but a
        // crash between the rename and the reap can, so hand-build it:
        // fast=red via store, best=blue written directly.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let red = PreviewTestImages.solid(red: 1, green: 0, blue: 0)
        cache.store(red, path: "/v/t.mkv", mtime: 5, size: 9, tier: .fast)

        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 5, size: 9)
        let bestURL = root.appendingPathComponent("\(key)-best.jpg")
        try writeJPEG(PreviewTestImages.solid(red: 0, green: 0, blue: 1), to: bestURL)

        let hit = try #require(cache.lookup(path: "/v/t.mkv", mtime: 5, size: 9))
        let mean = PreviewTestImages.meanRGB(hit)
        #expect(mean.b > 200 && mean.r < 60,
                "lookup returned the fast payload while a best payload existed: \(mean)")
        #expect(cache.storedTier(path: "/v/t.mkv", mtime: 5, size: 9) == .best)
    }

    // MARK: - Atomic publish (LOGIC)

    @Test("stores leave no tmp- files behind")
    func atomicPublishLeavesNoTempFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        for i in 0..<10 {
            cache.store(PreviewTestImages.twoTone(),
                        path: "/v/f\(i).mov", mtime: Double(i), size: Int64(i),
                        tier: i.isMultiple(of: 2) ? .fast : .best)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("tmp-") }
        #expect(leftovers.isEmpty,
                "temp files survived store — atomic publish broken: \(leftovers)")
    }

    // MARK: - Prune (SCALE)

    @Test("pruneNow under cap removes no payloads but sweeps tmp- orphans")
    func pruneUnderCapSweepsOrphansOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // ~200 small dummy payloads (prune counts bytes; it never
        // decodes, so plain data files are honest stand-ins) + a
        // handful of crashed-write orphans.
        for i in 0..<200 {
            try Data(repeating: 0xAB, count: 100)
                .write(to: root.appendingPathComponent("payload\(i)-fast.jpg"))
        }
        for i in 0..<5 {
            try Data(repeating: 0xCD, count: 100)
                .write(to: root.appendingPathComponent("tmp-orphan\(i)"))
        }

        let cache = PreviewDiskCache(rootURL: root)
        cache.pruneNow()

        let remaining = try fm.contentsOfDirectory(atPath: root.path)
        #expect(remaining.filter { $0.hasSuffix(".jpg") }.count == 200,
                "under-cap prune reaped live payloads")
        #expect(remaining.allSatisfy { !$0.hasPrefix("tmp-") },
                "crashed-write tmp orphans not swept")
    }

    @Test("pruneNow over cap reaps oldest-first until back under sizeCapBytes")
    func pruneOverCapReapsOldestFirst() throws {
        // Sparse-file technique — see the file header. 5 × 512 MB
        // logical = 2.5 GB seen by the prune, ~5 blocks physically.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let logicalSize: UInt64 = 512 * 1024 * 1024
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            let url = root.appendingPathComponent("sparse\(i)-fast.jpg")
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: logicalSize - 1)
            try handle.write(contentsOf: Data([0x00]))
            try handle.close()
            // Distinct, ordered mtimes: sparse0 oldest … sparse4 newest.
            try fm.setAttributes([.modificationDate: epoch.addingTimeInterval(Double(i) * 3600)],
                                 ofItemAtPath: url.path)
        }
        // Sanity: the resource key the prune reads reports LOGICAL size.
        let reported = try root.appendingPathComponent("sparse0-fast.jpg")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize
        try #require(Int64(reported ?? 0) == Int64(logicalSize),
                     "sparse-file premise broken — fileSizeKey no longer reports logical size")

        let cache = PreviewDiskCache(rootURL: root)
        cache.pruneNow()

        let remaining = try fm.contentsOfDirectory(atPath: root.path).sorted()
        // 2.5 GB − oldest 512 MB = 2.0 GB = exactly the cap (loop guard
        // is strict >) — exactly ONE file reaped, and it's the oldest.
        #expect(remaining == ["sparse1-fast.jpg", "sparse2-fast.jpg",
                              "sparse3-fast.jpg", "sparse4-fast.jpg"],
                "expected only the oldest payload reaped, got \(remaining)")
    }

    // MARK: - Isolation (ISOLATION)

    @Test("injected root confines all writes — real App Support cache untouched")
    func injectedRootNeverTouchesAppSupport() throws {
        let before = snapshot(realAppSupportCacheDir)

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        cache.store(PreviewTestImages.twoTone(), path: "/v/a.mov", mtime: 1, size: 1, tier: .fast)
        cache.store(PreviewTestImages.gradient(), path: "/v/b.mov", mtime: 2, size: 2, tier: .best)
        _ = cache.lookup(path: "/v/a.mov", mtime: 1, size: 1)
        cache.pruneNow()

        // Everything landed under the injected root…
        #expect(cache.rootURL == root)
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(written.count == 2)
        // …and the REAL production cache dir is bit-for-bit undisturbed
        // (absent, or same entry count and mtime as before the test).
        let after = snapshot(realAppSupportCacheDir)
        #expect(after == before,
                "real App Support preview-cache changed during an injected-root test: \(before) → \(after)")
    }

    @Test("productionRootURL redirects into the temp sandbox under a test host")
    func productionRootRedirectsForTests() {
        // Guards the ~200 VideoScanModel() construction sites across
        // the suite: the model's `previewDiskCache` uses this DEFAULT,
        // so if the redirect breaks, every one of those tests starts
        // writing JPEGs into Rick's real App Support cache (the
        // Settings-pollution incident class, disk edition).
        let url = PreviewDiskCache.productionRootURL
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        #expect(url.standardizedFileURL.path.hasPrefix(tmp),
                "test-host productionRootURL escaped the temp sandbox: \(url.path)")
        #expect(!url.path.contains("Application Support"),
                "test-host productionRootURL points at real App Support: \(url.path)")
        // And it stays per-process (relaunch of the test runner can't
        // inherit a sibling's leftovers).
        #expect(url.path.contains("\(ProcessInfo.processInfo.processIdentifier)"))
    }

    // MARK: - Relaunch persistence (SENSOR)

    /// REGRESSION SENSOR — pins the entire reason this cache exists:
    /// previews must survive a relaunch. Instance A is "the session
    /// that generated"; instance B on the same root is "the app after
    /// restart". If B misses, the L2 has silently become session-local
    /// (e.g. someone keys on an in-memory salt, or moves payloads to a
    /// per-process dir) and every launch goes back to re-ripping the
    /// whole catalog — the 237 GB FFV1 problem returns.
    @Test("payloads stored by one instance are found by a fresh instance on the same root")
    func relaunchPersistenceSensor() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionA = PreviewDiskCache(rootURL: root)
        sessionA.store(PreviewTestImages.solid(red: 0, green: 0, blue: 1),
                       path: "/Volumes/LaCie/1987/christmas.mkv",
                       mtime: 555_555_555, size: 987_654_321, tier: .best)

        // "Relaunch": a brand-new instance, same root, no shared state.
        let sessionB = PreviewDiskCache(rootURL: root)
        let hit = try #require(sessionB.lookup(path: "/Volumes/LaCie/1987/christmas.mkv",
                                               mtime: 555_555_555, size: 987_654_321),
                               "previews did not survive the relaunch — L2 has become session-local")
        let mean = PreviewTestImages.meanRGB(hit)
        #expect(mean.b > 200)
        #expect(sessionB.storedTier(path: "/Volumes/LaCie/1987/christmas.mkv",
                                    mtime: 555_555_555, size: 987_654_321) == .best)
    }

    // MARK: - Helpers

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
