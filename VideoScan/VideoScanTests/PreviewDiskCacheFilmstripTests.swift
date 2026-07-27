// PreviewDiskCacheFilmstripTests.swift
// LOGIC + SCALE + ISOLATION dimensions for PreviewDiskCache's filmstrip
// payloads (feature/filmstrip-preview commit 098e100, 2026-07-27).
// Companion to PreviewDiskCacheTests (single-frame tiers).
//
// The load-bearing contract under test: lookupFilmstrip returns
// non-nil ONLY for a COMPLETE, CONSISTENT set — all indices 0..<count
// present, one count value, no duplicates, nothing unparseable under
// the key's prefix. Partial/mismatched leftovers (crashed store, prune
// took some frames) must be a miss, never a short or scrambled strip.
//
// Every test uses an injected per-test temp root; the production
// App Support directory is never touched (snapshot-asserted below,
// same technique as PreviewDiskCacheTests).

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScan

@Suite("PreviewDiskCache filmstrip payloads", .serialized)
struct PreviewDiskCacheFilmstripTests {

    // MARK: - Per-test root

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_filmstripcache_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Distinct solid colors per index so a lookup can prove ORDER, not
    /// just presence: index i → red channel ramps, blue falls.
    private func indexColoredFrame(_ i: Int, of n: Int) -> CGImage {
        PreviewTestImages.solid(red: CGFloat(i + 1) / CGFloat(n + 1),
                                green: 0,
                                blue: 1.0 - CGFloat(i + 1) / CGFloat(n + 1))
    }

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

    /// All on-disk names for `key`'s strip set.
    private func stripNames(in root: URL, key: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("\(key)-strip-") }
            .sorted()
    }

    // MARK: - Filename round trip (LOGIC, pure)

    @Test("stripFilename → parseStripFilename round-trips every field")
    func filenameRoundTrip() {
        let key = String(repeating: "ab12", count: 16)   // 64-hex shaped
        let name = PreviewDiskCache.stripFilename(key: key, index: 3, count: 16,
                                                  offsetMillis: 4250)
        #expect(name == "\(key)-strip-3-of-16-4250.jpg")
        let parsed = parseOrNil(name)
        #expect(parsed?.key == key)
        #expect(parsed?.index == 3)
        #expect(parsed?.count == 16)
        #expect(parsed?.offsetMillis == 4250)
        // Offset 0 (a t=0 frame) is legal.
        #expect(parseOrNil(PreviewDiskCache.stripFilename(key: key, index: 0, count: 1,
                                                          offsetMillis: 0)) != nil)
    }

    @Test("parseStripFilename rejects everything that isn't a well-formed strip name",
          arguments: [
        "abc-fast.jpg",                    // tier payload
        "abc-best.jpg",                    // tier payload
        "tmp-0B9F-strip-0-of-4-500",       // crashed-write temp (no .jpg)
        "abc-strip-0-of-4-500.png",        // wrong extension
        "abc-strip-0-of-4-500",            // no extension
        "-strip-0-of-4-500.jpg",           // empty key
        "abc-strip-0-off-4-500.jpg",       // marker word wrong
        "abc-strip-0-of-4.jpg",            // missing offset field
        "abc-strip-0-of-4-500-9.jpg",      // extra field
        "abc-strip--1-of-4-500.jpg",       // negative index (breaks 4-part shape)
        "abc-strip-0-of--4-500.jpg",       // negative count
        "abc-strip-0-of-4--500.jpg",       // negative offset
        "abc-strip-4-of-4-500.jpg",        // index == count (out of range)
        "abc-strip-5-of-4-500.jpg",        // index > count
        "abc-strip-0-of-0-500.jpg",        // zero count
        "abc-strip-x-of-4-500.jpg",        // non-numeric index
        "abc-strip-0-of-4-5x0.jpg",        // non-numeric offset
        "abc-strip-.jpg",                  // nothing after marker
        "plain.jpg"                        // no marker at all
    ])
    func parseRejectsMalformed(name: String) {
        #expect(parseOrNil(name) == nil, "'\(name)' must not parse as a strip payload")
    }

    /// Tuple-returning statics can't be compared inline in #expect
    /// against nil cleanly — tiny adapter.
    private func parseOrNil(_ name: String)
        -> (key: String, index: Int, count: Int, offsetMillis: Int)? {
        PreviewDiskCache.parseStripFilename(name)
    }

    // MARK: - Store → lookup round trip (LOGIC)

    @Test("storeFilmstrip → lookupFilmstrip returns all frames in offset order")
    func storeLookupRoundTrip() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let frames: [(offsetSeconds: Double, image: CGImage)] = (0..<5).map {
            (Double($0) * 1.5 + 0.25, indexColoredFrame($0, of: 5))
        }

        cache.storeFilmstrip(frames, path: "/v/tape.mkv", mtime: 100, size: 5000)

        #expect(cache.hasCompleteFilmstrip(path: "/v/tape.mkv", mtime: 100, size: 5000))
        let hit = try #require(cache.lookupFilmstrip(path: "/v/tape.mkv", mtime: 100, size: 5000))
        #expect(hit.count == 5)
        // Offsets survive the millisecond round trip and stay ordered.
        #expect(hit.map(\.offsetSeconds) == frames.map(\.offsetSeconds))
        // ORDER proof: the red ramp must come back ascending.
        let reds = hit.map { PreviewTestImages.meanRGB($0.image).r }
        #expect(zip(reds, reds.dropFirst()).allSatisfy { $0 < $1 },
                "frames came back out of index order (red ramp: \(reds))")

        // Changed signature (modified file) misses — automatic invalidation.
        #expect(cache.lookupFilmstrip(path: "/v/tape.mkv", mtime: 101, size: 5000) == nil)
        #expect(!cache.hasCompleteFilmstrip(path: "/v/tape.mkv", mtime: 100, size: 5001))
    }

    @Test("storeFilmstrip refuses non-finite or negative offsets and empty strips")
    func storeRefusesHostileOffsets() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let img = PreviewTestImages.twoTone()

        // The millisecond conversion would SIGTRAP on non-finite input —
        // the guard must refuse the whole strip, writing nothing.
        cache.storeFilmstrip([(0.5, img), (Double.nan, img)],
                             path: "/v/a.mkv", mtime: 1, size: 1)
        cache.storeFilmstrip([(Double.infinity, img)],
                             path: "/v/a.mkv", mtime: 1, size: 1)
        cache.storeFilmstrip([(-2.0, img), (0.5, img)],
                             path: "/v/a.mkv", mtime: 1, size: 1)
        cache.storeFilmstrip([], path: "/v/a.mkv", mtime: 1, size: 1)

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty, "hostile stores must write nothing, found: \(contents)")
    }

    /// Codex adversarial finding #40 (2026-07-27), our equivalent of
    /// their RED oversizedOffsetDoesNotTrapOrPublishCacheFiles: a HUGE
    /// but FINITE offset passed the old isFinite guard and the
    /// `Int((offset * 1000).rounded())` conversion SIGTRAPs past
    /// ~9.2e18. Store must bound offsets to the plan's sane-duration
    /// ceiling — no trap, no cache files published — and the parser
    /// must reject the same range on READ so a hand-crafted filename
    /// can't push an insane timestamp downstream either.
    @Test("oversized finite offsets: store aborts without trap or files; parse rejects hand-crafted huge offsetMillis")
    func oversizedOffsetDoesNotTrapOrPublishCacheFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let img = PreviewTestImages.twoTone()
        let ceiling = PreviewBestFramePlan.maxSaneDurationSeconds

        // WRITE side — the trap inputs. Reaching the #expect at all is
        // the no-SIGTRAP proof.
        cache.storeFilmstrip([(Double.greatestFiniteMagnitude, img)],
                             path: "/v/huge.mkv", mtime: 1, size: 1)
        cache.storeFilmstrip([(1e18, img)],
                             path: "/v/huge.mkv", mtime: 1, size: 1)
        // One insane frame poisons the WHOLE store (consistent with the
        // non-finite behavior above — corrupt strip, not shorter strip).
        cache.storeFilmstrip([(0.5, img), (ceiling + 1, img)],
                             path: "/v/huge.mkv", mtime: 1, size: 1)
        var contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.isEmpty, "oversized-offset stores must publish nothing, found: \(contents)")

        // Boundary: exactly the ceiling is sane — plan and cache agree.
        cache.storeFilmstrip([(0.5, img), (ceiling, img)],
                             path: "/v/edge.mkv", mtime: 1, size: 1)
        #expect(cache.lookupFilmstrip(path: "/v/edge.mkv", mtime: 1, size: 1)?.count == 2,
                "an offset exactly at maxSaneDurationSeconds must store and serve")
        contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.count == 2)

        // READ side — hand-crafted filenames. Int.init(String) already
        // nils on overflow; the ceiling closes the in-range-but-insane
        // window (Int.max millis is within one ulp of overflowing
        // TrimTimecode.format's Int64 math downstream).
        #expect(PreviewDiskCache.parseStripFilename(
            "k-strip-0-of-1-\(Int.max).jpg") == nil)
        #expect(PreviewDiskCache.parseStripFilename(
            "k-strip-0-of-1-\(PreviewDiskCache.maxStripOffsetMillis + 1).jpg") == nil)
        #expect(PreviewDiskCache.parseStripFilename(
            "k-strip-0-of-1-99999999999999999999999999.jpg") == nil,
            "overflowing offsetMillis literal must be unparseable")
        // Boundary accepts.
        #expect(PreviewDiskCache.parseStripFilename(
            "k-strip-0-of-1-\(PreviewDiskCache.maxStripOffsetMillis).jpg")?
            .offsetMillis == PreviewDiskCache.maxStripOffsetMillis)

        // And end to end: an otherwise-complete set whose one filename
        // carries an insane offset is a MISS, not a trap (the
        // unparseable name makes the set inconsistent).
        let key = PreviewDiskCache.cacheKey(path: "/v/crafted.mkv", mtime: 1, size: 1)
        for i in 0..<2 {
            let millis = i == 0 ? 500 : Int.max
            try Data("x".utf8).write(to: root.appendingPathComponent(
                "\(key)-strip-\(i)-of-2-\(millis).jpg"))
        }
        #expect(cache.lookupFilmstrip(path: "/v/crafted.mkv", mtime: 1, size: 1) == nil)
        #expect(!cache.hasCompleteFilmstrip(path: "/v/crafted.mkv", mtime: 1, size: 1))
    }

    // MARK: - Completeness matrix (LOGIC — the load-bearing contract)

    @Test("incomplete/inconsistent strip sets are a miss",
          arguments: ["missing-index", "mixed-counts", "duplicate-index",
                      "unparseable-under-prefix", "empty"])
    func completenessMatrix(scenario: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 7, size: 7)
        let img = PreviewTestImages.twoTone()

        func write(_ name: String) throws {
            try writeJPEG(img, to: root.appendingPathComponent(name))
        }

        switch scenario {
        case "missing-index":
            // indices 0 and 2 of a 3-set — the prune-took-frame-1 case.
            try write(PreviewDiskCache.stripFilename(key: key, index: 0, count: 3, offsetMillis: 100))
            try write(PreviewDiskCache.stripFilename(key: key, index: 2, count: 3, offsetMillis: 300))
        case "mixed-counts":
            // Two generations' files mixed under one key.
            try write(PreviewDiskCache.stripFilename(key: key, index: 0, count: 3, offsetMillis: 100))
            try write(PreviewDiskCache.stripFilename(key: key, index: 1, count: 3, offsetMillis: 200))
            try write(PreviewDiskCache.stripFilename(key: key, index: 2, count: 4, offsetMillis: 300))
        case "duplicate-index":
            // Same index twice with different offsets — ambiguous.
            try write(PreviewDiskCache.stripFilename(key: key, index: 0, count: 2, offsetMillis: 100))
            try write(PreviewDiskCache.stripFilename(key: key, index: 0, count: 2, offsetMillis: 150))
            try write(PreviewDiskCache.stripFilename(key: key, index: 1, count: 2, offsetMillis: 200))
        case "unparseable-under-prefix":
            // A complete 2-set PLUS one garbage name under our prefix —
            // strict-by-design: anything ambiguous is a miss.
            try write(PreviewDiskCache.stripFilename(key: key, index: 0, count: 2, offsetMillis: 100))
            try write(PreviewDiskCache.stripFilename(key: key, index: 1, count: 2, offsetMillis: 200))
            try write("\(key)-strip-garbage.jpg")
        case "empty":
            break   // nothing on disk at all
        default:
            Issue.record("unknown scenario \(scenario)")
        }

        #expect(cache.lookupFilmstrip(path: "/v/t.mkv", mtime: 7, size: 7) == nil,
                "[\(scenario)] must be a miss")
        #expect(!cache.hasCompleteFilmstrip(path: "/v/t.mkv", mtime: 7, size: 7),
                "[\(scenario)] hasCompleteFilmstrip must agree with lookupFilmstrip")
    }

    @Test("corrupt JPEG payload in a complete set fails the WHOLE lookup — degrade to regeneration, no crash")
    func corruptPayloadDegradesToMiss() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 7, size: 7)

        try writeJPEG(PreviewTestImages.twoTone(),
                      to: root.appendingPathComponent(
                        PreviewDiskCache.stripFilename(key: key, index: 0, count: 2, offsetMillis: 100)))
        // Index 1 is a "complete" name whose bytes are not a JPEG.
        try Data("definitely not a jpeg".utf8).write(
            to: root.appendingPathComponent(
                PreviewDiskCache.stripFilename(key: key, index: 1, count: 2, offsetMillis: 200)))

        // hasComplete is listing-only, so it says true — but the DECODING
        // lookup must return nil (caller regenerates), never a short strip.
        #expect(cache.hasCompleteFilmstrip(path: "/v/t.mkv", mtime: 7, size: 7))
        #expect(cache.lookupFilmstrip(path: "/v/t.mkv", mtime: 7, size: 7) == nil,
                "corrupt payload must fail the whole lookup, not truncate the strip")
    }

    // MARK: - Replacement (LOGIC)

    @Test("re-store replaces a differently-sized old set completely — no orphans for that key")
    func restoreReplacesOldSetCompletely() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let key = PreviewDiskCache.cacheKey(path: "/v/t.mkv", mtime: 9, size: 9)

        let eight: [(offsetSeconds: Double, image: CGImage)] = (0..<8).map {
            (Double($0) + 0.5, indexColoredFrame($0, of: 8))
        }
        cache.storeFilmstrip(eight, path: "/v/t.mkv", mtime: 9, size: 9)
        #expect(try stripNames(in: root, key: key).count == 8)

        // Second generation is SMALLER — the dangerous direction: stale
        // high-index files from the 8-set would make the 4-set's
        // completeness check ambiguous forever.
        let four: [(offsetSeconds: Double, image: CGImage)] = (0..<4).map {
            (Double($0) * 2 + 1.0, indexColoredFrame($0, of: 4))
        }
        cache.storeFilmstrip(four, path: "/v/t.mkv", mtime: 9, size: 9)

        let names = try stripNames(in: root, key: key)
        #expect(names.count == 4, "old 8-set not fully removed: \(names)")
        let hit = try #require(cache.lookupFilmstrip(path: "/v/t.mkv", mtime: 9, size: 9))
        #expect(hit.map(\.offsetSeconds) == [1.0, 3.0, 5.0, 7.0])
    }

    // MARK: - Coexistence with single-frame tiers (LOGIC)

    @Test("strip payloads and single-frame tiers share the directory without cross-talk")
    func stripAndTierPayloadsCoexist() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        let sig: (path: String, mtime: TimeInterval, size: Int64) = ("/v/t.mkv", 5, 9)

        // Strip alone must not satisfy a tier lookup…
        cache.storeFilmstrip([(0.5, PreviewTestImages.solid(red: 0, green: 0, blue: 1)),
                              (1.5, PreviewTestImages.twoTone())],
                             path: sig.path, mtime: sig.mtime, size: sig.size)
        #expect(cache.lookup(path: sig.path, mtime: sig.mtime, size: sig.size) == nil,
                "a strip must not masquerade as a single-frame payload")
        #expect(cache.storedTier(path: sig.path, mtime: sig.mtime, size: sig.size) == nil)

        // …and adding both tiers must not disturb the strip.
        cache.store(PreviewTestImages.solid(red: 1, green: 0, blue: 0),
                    path: sig.path, mtime: sig.mtime, size: sig.size, tier: .fast)
        cache.store(PreviewTestImages.gradient(),
                    path: sig.path, mtime: sig.mtime, size: sig.size, tier: .best)
        #expect(cache.storedTier(path: sig.path, mtime: sig.mtime, size: sig.size) == .best)
        let strip = try #require(cache.lookupFilmstrip(path: sig.path,
                                                       mtime: sig.mtime, size: sig.size))
        #expect(strip.count == 2)
        // And the tier payload comes back as the tier image, not a strip frame.
        let single = try #require(cache.lookup(path: sig.path, mtime: sig.mtime, size: sig.size))
        #expect(single.width > 0)
    }

    // MARK: - Prune coverage (LOGIC/SCALE — name-shape agnosticism)

    @Test("over-cap prune reaps strip files too; a partially reaped strip becomes a miss")
    func pruneCoversStripFiles() throws {
        // Sparse-file technique from PreviewDiskCacheTests: 5 strip
        // frames × 512 MB logical = 2.5 GB seen by the prune, a few
        // blocks physically. Oldest frame (index 0) must be reaped —
        // and the now-partial set must read as a MISS.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let key = PreviewDiskCache.cacheKey(path: "/v/big.mkv", mtime: 1, size: 1)
        let logicalSize: UInt64 = 512 * 1024 * 1024
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            let name = PreviewDiskCache.stripFilename(key: key, index: i, count: 5,
                                                      offsetMillis: i * 1000)
            let url = root.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: logicalSize - 1)
            try handle.write(contentsOf: Data([0x00]))
            try handle.close()
            try fm.setAttributes([.modificationDate: epoch.addingTimeInterval(Double(i) * 3600)],
                                 ofItemAtPath: url.path)
        }

        let cache = PreviewDiskCache(rootURL: root)
        cache.pruneNow()

        let remaining = try stripNames(in: root, key: key)
        #expect(remaining.count == 4, "prune must cover strip files by name shape: \(remaining)")
        #expect(!remaining.contains { $0.contains("-strip-0-of-") },
                "prune must reap oldest-first")
        #expect(cache.lookupFilmstrip(path: "/v/big.mkv", mtime: 1, size: 1) == nil,
                "a partially pruned strip must be a miss")
    }

    // MARK: - Probe cost at directory scale (SCALE)

    /// SCALE pin with an explicit budget: every filmstrip probe pays one
    /// directory listing, and the header documents ~20k names ≈ a few
    /// ms. 60 hit-probes + 60 miss-probes over a 20k-file directory must
    /// finish in < 5 s (~40 ms/probe). A regression to per-entry stat(2)
    /// or eager decoding of unrelated files blows this budget by an
    /// order of magnitude; honest listings pass with wide margin.
    @Test("filmstrip probes stay within budget with 20k unrelated cache files present",
          .timeLimit(.minutes(2)))
    func probeCostAtTwentyThousandFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // 20k unrelated tier payloads (1 byte each — the probe never
        // opens them, so content is irrelevant).
        let byte = Data([0xAB])
        for i in 0..<20_000 {
            fm.createFile(atPath: root.appendingPathComponent("unrelated\(i)-fast.jpg").path,
                          contents: byte)
        }

        let cache = PreviewDiskCache(rootURL: root)
        // One real 4-frame strip buried among them.
        cache.storeFilmstrip((0..<4).map { (Double($0) + 0.5, PreviewTestImages.twoTone()) },
                             path: "/v/needle.mkv", mtime: 42, size: 42)

        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for _ in 0..<60 {
                if cache.lookupFilmstrip(path: "/v/needle.mkv", mtime: 42, size: 42) != nil {
                    hits += 1
                }
                _ = cache.hasCompleteFilmstrip(path: "/v/absent.mkv", mtime: 1, size: 1)
            }
        }
        #expect(hits == 60, "the buried strip must hit every probe")
        #expect(elapsed < .seconds(5),
                "120 filmstrip probes over 20k files took \(elapsed) — directory probe cost regressed")
    }

    /// SCALE pin #2 — STRIP-SHAPED population (codex test-gap d,
    /// 2026-07-27): the sensor above models 20k single-tier payloads,
    /// but a filmstrip-heavy cache is 16-files-per-record — and every
    /// one of those names carries the "-strip-" marker, so a probe's
    /// per-name work (prefix filter, and parseStripFilename for its own
    /// key's matches) is exercised at realistic fan-out. 1250 records ×
    /// 16 frames = 20k valid strip names from OTHER keys + one needle.
    /// Same 120-probe / 5 s budget: a regression that parses or stats
    /// every name in the directory (instead of prefix-filtering first)
    /// shows up here, not in the tier-shaped sensor.
    @Test("filmstrip probes stay within budget when the 20k population is strip-shaped (16 files/record)",
          .timeLimit(.minutes(2)))
    func probeCostAtStripShapedTwentyThousandFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // 1250 foreign records' complete 16-frame strips (1 byte each —
        // probes for OTHER keys must never open them). Keys are real
        // cacheKey hashes so name shape and length match production.
        let byte = Data([0xAB])
        for rec in 0..<1250 {
            let key = PreviewDiskCache.cacheKey(path: "/v/other\(rec).mkv", mtime: 7, size: 7)
            for i in 0..<16 {
                let name = PreviewDiskCache.stripFilename(key: key, index: i, count: 16,
                                                          offsetMillis: i * 500)
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: byte)
            }
        }

        let cache = PreviewDiskCache(rootURL: root)
        // One real 16-frame strip buried among them — production shape.
        cache.storeFilmstrip((0..<16).map { (Double($0) + 0.5, PreviewTestImages.twoTone()) },
                             path: "/v/needle.mkv", mtime: 42, size: 42)

        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for _ in 0..<60 {
                if cache.lookupFilmstrip(path: "/v/needle.mkv", mtime: 42, size: 42) != nil {
                    hits += 1
                }
                _ = cache.hasCompleteFilmstrip(path: "/v/absent.mkv", mtime: 1, size: 1)
            }
        }
        #expect(hits == 60, "the buried 16-frame strip must hit every probe")
        #expect(elapsed < .seconds(5),
                "120 probes over a strip-shaped 20k directory took \(elapsed) — probe cost regressed at realistic fan-out")
    }

    // MARK: - Isolation (ISOLATION)

    @Test("filmstrip stores/lookups confine all writes to the injected root — real App Support untouched")
    func filmstripWritesConfinedToInjectedRoot() throws {
        let realDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("preview-cache", isDirectory: true)
        func snapshot() -> (exists: Bool, count: Int) {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: realDir.path)) ?? []
            return (FileManager.default.fileExists(atPath: realDir.path), entries.count)
        }
        let before = snapshot()

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)
        cache.storeFilmstrip((0..<3).map { (Double($0) + 0.5, PreviewTestImages.gradient()) },
                             path: "/v/iso.mkv", mtime: 1, size: 1)
        _ = cache.lookupFilmstrip(path: "/v/iso.mkv", mtime: 1, size: 1)

        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(written.count == 3, "3 strip frames expected under the injected root: \(written)")
        let after = snapshot()
        #expect(after == before,
                "real App Support preview-cache changed during a filmstrip test: \(before) → \(after)")
    }
}
