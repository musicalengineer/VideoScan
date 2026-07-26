// PreviewFrameRouteTests.swift
// LOGIC + SCALE + ISOLATION dimensions for the catalog-preview routing
// fix (perf/preview-routing, 2026-07-26) — feature-test checklist items
// 1, 2 (pure-function scale pin), and 4.
//
// Two pure surfaces under test, both in PreviewFrameRoute.swift:
//
//   1. PreviewFrameRouter.previewRoute — the AVFoundation-vs-ffmpeg
//      decision made from cataloged ffprobe metadata. If a hostile
//      container/codec ever falls through to .avFoundation, the preview
//      pane regresses to the 30s–1min+ stall this branch fixes — so the
//      hostile table is pinned case by case.
//
//   2. ThumbnailFailureStore — the negative cache. Its (mtime, size)
//      self-invalidation is what lets a repaired file retry; its FIFO
//      cap is what keeps an arbitrarily long session bounded. Both are
//      pinned with temp-dir fixtures only (ISOLATION: never touches real
//      user files, and a sensor asserts the feature added no UserDefaults
//      traffic — the Settings-pollution incident class).
//
// The I/O tiers (AVF deadline, ffmpeg rip) are covered separately in
// PreviewFrameMediaMatrixTests.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Route decision (pure)

@Suite("PreviewFrameRouter")
struct PreviewFrameRouteTests {

    // For Rick: `@Test(arguments:)` ≈ gtest's TEST_P value-parameterized
    // tests — one invocation (and one reported result) per tuple.

    /// Hostile cases — every one of these must route .ffmpegDirect.
    /// Container strings are exact ffprobe `format_long_name` output
    /// (verified against ffmpeg 8.x): an .mkv file arrives as
    /// "Matroska / WebM", NOT "mkv" — which is why the router does
    /// substring matching on container tokens.
    @Test("AVF-hostile container/codec routes ffmpegDirect", arguments: [
        // (container, videoCodec, label)
        ("Matroska / WebM", "ffv1", "the digitized-tape master case"),
        ("Matroska / WebM", "h264", "hostile container wins even with a friendly codec"),
        ("WebM", "vp9", "webm token alone"),
        // Codec-driven routes (friendly QuickTime container):
        ("QuickTime / MOV", "svq3", "Sorenson"),
        ("QuickTime / MOV", "cinepak", "Cinepak"),
        ("AVI (Audio Video Interleaved)", "vp8", "vp8"),
        ("AVI (Audio Video Interleaved)", "vp9", "vp9"),
        ("QuickTime / MOV", "av1", "av1 — no AVF decode on macOS"),
        // Prefix families (ffprobe numbers the variants):
        ("AVI (Audio Video Interleaved)", "indeo2", "Indeo family, low variant"),
        ("AVI (Audio Video Interleaved)", "indeo5", "Indeo family, high variant"),
        ("AVI (Audio Video Interleaved)", "msmpeg4v2", "MS-MPEG4 numbered variant"),
        ("AVI (Audio Video Interleaved)", "msmpeg4", "MS-MPEG4 bare prefix spelling")
    ])
    func hostileRoutesToFFmpeg(container: String, codec: String, label: String) {
        #expect(PreviewFrameRouter.previewRoute(container: container,
                                                videoCodec: codec,
                                                needsReformat: false) == .ffmpegDirect,
                "\(label): \(container) / \(codec) must never instantiate an AVURLAsset")
    }

    /// Friendly cases — the overwhelming catalog majority stays on the
    /// hardware-assisted AVFoundation fast path.
    @Test("Friendly container/codec routes avFoundation", arguments: [
        ("QuickTime / MOV", "h264"),
        ("QuickTime / MOV", "prores"),
        ("QuickTime / MOV", "hevc"),
        ("MPEG-TS (MPEG-2 Transport Stream)", "h264"),   // AVCHD .MTS
        ("MXF (Material eXchange Format)", "mpeg2video"),
        ("", "")                                          // empty metadata → default path
    ])
    func friendlyRoutesToAVFoundation(container: String, codec: String) {
        #expect(PreviewFrameRouter.previewRoute(container: container,
                                                videoCodec: codec,
                                                needsReformat: false) == .avFoundation)
    }

    @Test("Container matching is substring-based and case-insensitive")
    func containerSubstringCaseInsensitive() {
        // ffprobe's exact spelling has capitals; the token table is
        // lowercase — a case-sensitive compare would silently break the
        // entire fix. Also pin that a SUBSTRING anywhere matches.
        for spelling in ["Matroska / WebM", "MATROSKA / WEBM", "matroska,webm",
                         "some Matroska variant"] {
            #expect(PreviewFrameRouter.previewRoute(container: spelling,
                                                    videoCodec: "h264",
                                                    needsReformat: false) == .ffmpegDirect,
                    "container spelling '\(spelling)' must match the matroska token")
        }
    }

    @Test("Codec matching is case-insensitive and whitespace-tolerant")
    func codecCaseInsensitive() {
        #expect(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                videoCodec: "FFV1",
                                                needsReformat: false) == .ffmpegDirect)
        #expect(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                videoCodec: " ffv1 ",
                                                needsReformat: false) == .ffmpegDirect)
        #expect(PreviewFrameRouter.previewRoute(container: "AVI (Audio Video Interleaved)",
                                                videoCodec: "Indeo5",
                                                needsReformat: false) == .ffmpegDirect)
    }

    @Test("needsReformat is a backstop: forces ffmpegDirect even for friendly metadata")
    func needsReformatBackstop() {
        // The analyzer already proved AVFoundation can't decode this file
        // — the static tables not knowing the codec must not matter.
        #expect(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                videoCodec: "h264",
                                                needsReformat: true) == .ffmpegDirect)
        // And it must NOT flip friendly files when false (guards against
        // an inverted flag).
        #expect(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                videoCodec: "h264",
                                                needsReformat: false) == .avFoundation)
    }

    // MARK: - Scale (checklist dimension 2)

    /// SENSOR at scale: previewRoute is documented PURE — no I/O, no
    /// AVFoundation, no logging. This pin exists so nobody "helpfully"
    /// adds a stat()/probe inside it later: 100k routes (a full worst-case
    /// catalog) must stay comfortably under 1s. Any file I/O added to the
    /// route decision would blow this budget instantly on 100k calls.
    @Test("100k route decisions complete in under 1 second (purity pin)")
    func routeDecisionScale() {
        let containers = ["Matroska / WebM", "QuickTime / MOV",
                          "AVI (Audio Video Interleaved)", "MXF (Material eXchange Format)"]
        let codecs = ["h264", "ffv1", "prores", "indeo5", "msmpeg4v2", "hevc"]
        let clock = ContinuousClock()
        var ffmpegCount = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 {
                let route = PreviewFrameRouter.previewRoute(
                    container: containers[i % containers.count],
                    videoCodec: codecs[i % codecs.count],
                    needsReformat: i % 17 == 0)
                if route == .ffmpegDirect { ffmpegCount += 1 }
            }
        }
        #expect(ffmpegCount > 0)  // keep the loop un-optimizable
        #expect(elapsed < .seconds(1),
                "100k pure route decisions took \(elapsed) — did someone add I/O to previewRoute?")
    }
}

// MARK: - Negative cache

/// ISOLATION note (checklist dimension 4): every path used below lives
/// under a per-test temp directory (or is deliberately nonexistent under
/// one) — these tests can never stat, read, or invalidate anything in
/// Rick's real catalog. The store itself persists nothing: no UserDefaults,
/// no files (sensor test at the bottom pins that).
@Suite("ThumbnailFailureStore")
struct ThumbnailFailureStoreTests {

    /// Fresh temp dir per test — hermetic, removed on exit.
    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_failstore_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int) throws -> URL {
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: - Basic contract

    @Test("record → isKnownFailure true while the file is unchanged")
    func recordThenKnown() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile(at: dir.appendingPathComponent("bad.mkv"), bytes: 128)

        let store = ThumbnailFailureStore()
        #expect(!store.isKnownFailure(atPath: file.path), "unrecorded file must not be a known failure")
        store.recordFailure(forPath: file.path)
        #expect(store.isKnownFailure(atPath: file.path))
        #expect(store.isKnownFailure(atPath: file.path), "must stay true across repeated queries")
        #expect(store.count == 1)
    }

    @Test("unknown path is never a known failure")
    func unknownPathFalse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: dir.appendingPathComponent("a.mkv").path)
        #expect(!store.isKnownFailure(atPath: dir.appendingPathComponent("other.mkv").path))
    }

    // MARK: - Self-invalidation (the "repaired file retries" contract)

    @Test("size change invalidates the entry — and it stays forgotten")
    func sizeChangeInvalidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile(at: dir.appendingPathComponent("repaired.mkv"), bytes: 64)

        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: file.path)
        #expect(store.isKnownFailure(atPath: file.path))

        // "Repair" the file: different size.
        try writeFile(at: file, bytes: 256)
        #expect(!store.isKnownFailure(atPath: file.path),
                "a replaced file must retry, not stay blacklisted")
        // The miss must also PURGE the entry (retry-once semantics), so
        // count reflects it and future queries stay false.
        // (`count` is the store's Int diagnostic property — there is no
        // isEmpty on ThumbnailFailureStore, so empty_count doesn't apply.)
        // swiftlint:disable:next empty_count
        #expect(store.count == 0)
        #expect(!store.isKnownFailure(atPath: file.path))
    }

    @Test("mtime-only change (same size) invalidates the entry")
    func mtimeChangeInvalidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile(at: dir.appendingPathComponent("touched.mkv"), bytes: 64)

        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: file.path)
        #expect(store.isKnownFailure(atPath: file.path))

        // Same bytes, new mtime — e.g. an in-place rewrite by a repair
        // tool. Must invalidate: mtime is half of the signature.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: file.path)
        #expect(!store.isKnownFailure(atPath: file.path))
    }

    @Test("file deleted after recording → no longer a known failure")
    func deletionInvalidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile(at: dir.appendingPathComponent("gone.mkv"), bytes: 64)

        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: file.path)
        try FileManager.default.removeItem(at: file)
        // Signature is now (0,0) vs. the recorded real one → mismatch.
        #expect(!store.isKnownFailure(atPath: file.path))
    }

    @Test("file missing at record time: suppressed while missing, retries once it appears")
    func missingAtRecordTimeMatchesOnlyWhileMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("vanished.mkv").path

        // The file vanished mid-generation: recordFailure stats zeros.
        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: path)
        #expect(store.isKnownFailure(atPath: path),
                "while the file KEEPS failing to stat, the failure holds")

        // The file reappears (volume remounts, file restored) → the
        // zero-signature no longer matches → retry.
        try writeFile(at: URL(fileURLWithPath: path), bytes: 64)
        #expect(!store.isKnownFailure(atPath: path))
    }

    // MARK: - Cap enforcement

    @Test("FIFO cap: oldest entries evicted at maxEntries, count never exceeds the cap")
    func capEnforcementDropsOldest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Nonexistent paths under OUR temp dir: signature is (0,0) at
        // record AND at query, so entries match while present — which
        // makes eviction observable without creating 10k real files.
        let store = ThumbnailFailureStore()
        let cap = ThumbnailFailureStore.maxEntries

        func path(_ i: Int) -> String { dir.appendingPathComponent("f\(i).mkv").path }

        for i in 0..<(cap + 5) {
            store.recordFailure(forPath: path(i))
        }
        #expect(store.count == cap, "store must never exceed maxEntries (got \(store.count))")
        // Drop-OLDEST: the first 5 recorded paths are gone…
        for i in 0..<5 {
            #expect(!store.isKnownFailure(atPath: path(i)),
                    "entry \(i) should have been FIFO-evicted")
        }
        // …and the newest (plus a survivor just past the evicted range)
        // are still present.
        #expect(store.isKnownFailure(atPath: path(5)))
        #expect(store.isKnownFailure(atPath: path(cap + 4)))
    }

    @Test("re-recording an existing path does not grow the store")
    func reRecordDoesNotGrow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile(at: dir.appendingPathComponent("again.mkv"), bytes: 64)

        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: file.path)
        store.recordFailure(forPath: file.path)
        store.recordFailure(forPath: file.path)
        #expect(store.count == 1)
        #expect(store.isKnownFailure(atPath: file.path))
    }

    // MARK: - Isolation sensor (checklist dimension 4)

    /// The Settings-pollution incident class: a feature quietly persisting
    /// state into the REAL UserDefaults plist from tests. The preview
    /// routing feature is documented as fully in-memory — this sensor
    /// pins it by asserting that exercising the store + router adds no
    /// preview/thumbnail-related defaults keys. (Substring-filtered so
    /// unrelated suites running in parallel can't flake this test.)
    @Test("feature persists nothing to UserDefaults")
    func noUserDefaultsTraffic() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        func relevantKeys() -> Set<String> {
            Set(UserDefaults.standard.dictionaryRepresentation().keys.filter {
                let k = $0.lowercased()
                return k.contains("preview") || k.contains("thumbnail") || k.contains("failurestore")
            })
        }

        let before = relevantKeys()
        let store = ThumbnailFailureStore()
        let file = try writeFile(at: dir.appendingPathComponent("d.mkv"), bytes: 64)
        store.recordFailure(forPath: file.path)
        _ = store.isKnownFailure(atPath: file.path)
        _ = PreviewFrameRouter.previewRoute(container: "Matroska / WebM",
                                            videoCodec: "ffv1",
                                            needsReformat: false)
        let added = relevantKeys().subtracting(before)
        #expect(added.isEmpty,
                "preview routing wrote UserDefaults keys: \(added)")
    }
}
