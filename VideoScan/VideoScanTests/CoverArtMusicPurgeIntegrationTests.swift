import Foundation
import Testing
@testable import VideoScan

// MARK: - Cover-Art Music Purge — integration tests (2026-07-20)
//
// The pure predicate is pinned in CoverArtMusicPurgeTests.swift. THIS file
// exercises the removal END-TO-END through a real (but ISOLATED)
// CatalogStore: seed a mixed catalog → purgeCoverArtMusicRecords() →
// assert exactly the cover-art strays leave `records`, the search index no
// longer resolves them, and the removal is persisted to the isolated
// catalog.json (never Rick's real ~/Library/Application Support catalog).
//
// Isolation seam (the one QA called the "injected-store harness"):
//   `VideoScanModel.catalogStore` is an `internal var` defaulting to
//   `CatalogStore.shared`. Tests reassign it to `CatalogStore(directory:)`
//   pointed at a per-test temp dir. The shared store short-circuits all
//   load/save under the test host (`isRunningTests && self === .shared`),
//   but an INJECTED store is not `.shared`, so its real load/save/snapshot
//   paths run — writing only inside our temp dir. This is the exact
//   convention TargetRemovalSafetyTests uses.
//
//   `// In C++ terms: dependency-inject a stub persistence backend instead
//   of letting the singleton reach the real filesystem.`
//
// Gating note (why the snapshot is pinned separately, below):
//   `purgeCoverArtMusicRecords()` wraps its pre-purge snapshot + fail-safe
//   degrade in `if !Self.isRunningTests { ... }`, so under ANY xctest host
//   that whole block is bypassed and the removal proceeds without writing a
//   `pre-coverart-purge` file. The snapshot cannot therefore be observed
//   from INSIDE a test-host purge call. We instead pin the snapshot
//   PRIMITIVE the purge relies on (`snapshotCatalog(prefix:)`) directly —
//   both its success (a recovery copy is written to the isolated dir) and
//   its nil-return-on-failure, which is the exact condition that trips the
//   purge's "destroy nothing" degrade in production.

@MainActor
private func rec(ext: String,
                 videoCodec: String,
                 streamType: StreamType,
                 fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.ext = ext
    r.videoCodec = videoCodec
    r.streamTypeRaw = streamType.rawValue
    r.fullPath = fullPath
    r.filename = (fullPath as NSString).lastPathComponent
    r.directory = (fullPath as NSString).deletingLastPathComponent
    return r
}

@Suite(.serialized) @MainActor
struct CoverArtMusicPurgeIntegrationTests {

    /// Full removal path: only the cover-art strays leave the catalog, real
    /// media + already-audio rows survive, the count drops by exactly the
    /// candidate count, the search index stops resolving the purged paths,
    /// and the survivors persist to the isolated catalog.json.
    @Test func purgeRemovesOnlyCandidatesAndPersists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-coverart-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // isolated store
        model.scanTargets.removeAll()

        // --- The mixed catalog --------------------------------------------
        // Three genuine cover-art strays (audio ext + mjpeg/png + video stream):
        let strayA = rec(ext: "mp3", videoCodec: "mjpeg", streamType: .videoAndAudio,
                         fullPath: "/Volumes/Music/iTunes/song_a.mp3")
        let strayB = rec(ext: "m4p", videoCodec: "png",   streamType: .videoOnly,
                         fullPath: "/Volumes/Music/iTunes/song_b.m4p")
        let strayC = rec(ext: "m4a", videoCodec: "mjpeg", streamType: .videoAndAudio,
                         fullPath: "/Volumes/Music/iTunes/song_c.m4a")
        // A real home video (mov + h264) — must be KEPT:
        let realVideo = rec(ext: "mov", videoCodec: "h264", streamType: .videoAndAudio,
                            fullPath: "/Volumes/Family/1998/donna_birthday.mov")
        // A real motion-JPEG clip under a NON-audio ext — must be KEPT:
        let realMotionJpeg = rec(ext: "mov", videoCodec: "mjpeg", streamType: .videoOnly,
                                fullPath: "/Volumes/Family/2001/camcorder_mjpeg.mov")
        // An already-correct audio-only row — must be KEPT:
        let audioOnly = rec(ext: "mp3", videoCodec: "mjpeg", streamType: .audioOnly,
                           fullPath: "/Volumes/Music/podcasts/ep12.mp3")

        let candidates = [strayA, strayB, strayC]
        let survivors  = [realVideo, realMotionJpeg, audioOnly]
        model.records = candidates + survivors
        model.searchIndex.rebuild(records: model.records)

        let countBefore = model.records.count

        // Sanity: the purged paths ARE resolvable before the purge, so the
        // post-purge "no longer resolves" assertion is meaningful.
        #expect(model.searchIndex.hasHaystack(for: strayA.fullPath))
        #expect(model.searchIndex.hasHaystack(for: realVideo.fullPath))

        // --- The purge -----------------------------------------------------
        let removed = model.purgeCoverArtMusicRecords()

        // Exactly the three candidates were removed.
        #expect(removed == candidates.count,
                "purge should report removing exactly the \(candidates.count) cover-art candidates, got \(removed)")
        #expect(model.records.count == countBefore - candidates.count,
                "records.count must drop by exactly the candidate count")

        let survivingPaths = Set(model.records.map(\.fullPath))
        for c in candidates {
            #expect(!survivingPaths.contains(c.fullPath),
                    "cover-art stray \(c.fullPath) must be removed")
        }
        for s in survivors {
            #expect(survivingPaths.contains(s.fullPath),
                    "\(s.fullPath) is not a cover-art stray and must SURVIVE")
        }

        // Search index no longer resolves a purged path, still resolves kept ones.
        #expect(!model.searchIndex.hasHaystack(for: strayA.fullPath),
                "search index must not resolve a purged path after rebuild")
        #expect(!model.searchIndex.hasHaystack(for: strayB.fullPath))
        #expect(!model.searchIndex.hasHaystack(for: strayC.fullPath))
        #expect(model.searchIndex.hasHaystack(for: realVideo.fullPath))
        #expect(model.searchIndex.hasHaystack(for: realMotionJpeg.fullPath))

        // The removal was persisted through the isolated store: reload from
        // disk and confirm only the survivors are present.
        let reloaded = CatalogStore(directory: tmp).load()
        let reloadedPaths = Set(reloaded.map(\.fullPath))
        #expect(reloaded.count == survivors.count)
        for c in candidates {
            #expect(!reloadedPaths.contains(c.fullPath),
                    "purged \(c.fullPath) must not reappear on reload")
        }
        for s in survivors {
            #expect(reloadedPaths.contains(s.fullPath),
                    "survivor \(s.fullPath) must persist across reload")
        }

        // The isolated catalog.json exists; the real App Support catalog is
        // never named/touched here (this store points only at `tmp`).
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("catalog.json").path))
    }

    /// Re-running the purge on an already-clean catalog is a safe no-op:
    /// nothing removed, survivors untouched. (Idempotence — the purge is
    /// documented as re-runnable.)
    @Test func purgeOnCleanCatalogIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-coverart-purge-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        model.records = [
            rec(ext: "mov", videoCodec: "h264",  streamType: .videoAndAudio,
                fullPath: "/Volumes/Family/a.mov"),
            rec(ext: "mov", videoCodec: "mjpeg", streamType: .videoOnly,
                fullPath: "/Volumes/Family/b.mov"),
            rec(ext: "mp3", videoCodec: "mjpeg", streamType: .audioOnly,
                fullPath: "/Volumes/Music/c.mp3"),
        ]
        let before = model.records.count

        let removed = model.purgeCoverArtMusicRecords()

        #expect(removed == 0, "no cover-art strays present → nothing removed")
        #expect(model.records.count == before, "clean catalog is untouched")
    }

    // MARK: - Snapshot primitive (the purge's safety net, pinned directly)

    /// `snapshotCatalog(prefix:)` — the exact recovery-copy call the purge
    /// makes in production — writes a `catalog.pre-coverart-purge.<stamp>.json`
    /// into the ISOLATED store dir (never App Support), and it round-trips.
    ///
    /// (The purge's own snapshot call is bypassed under the xctest host — see
    /// the file header — so this pins the mechanism it depends on.)
    @Test func snapshotPrimitiveWritesRecoveryCopy() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-coverart-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.records = [
            rec(ext: "mp3", videoCodec: "mjpeg", streamType: .videoAndAudio,
                fullPath: "/Volumes/Music/x.mp3"),
        ]

        let path = model.snapshotCatalog(prefix: "pre-coverart-purge")

        let snap = try #require(path, "snapshot must be written to the isolated store dir")
        #expect(snap.hasPrefix(tmp.path),
                "snapshot must live in the isolated temp dir, NOT App Support: \(snap)")
        let name = (snap as NSString).lastPathComponent
        #expect(name.hasPrefix("catalog.pre-coverart-purge."))
        #expect(name.hasSuffix(".json"))
        #expect(FileManager.default.fileExists(atPath: snap))

        // The recovery copy must round-trip — it is the only pre-purge undo.
        let restored = try #require(model.catalogStore.loadRecords(fromSnapshotAtPath: snap))
        #expect(restored.count == 1)
        #expect(restored.first?.fullPath == "/Volumes/Music/x.mp3")
    }

    /// FAIL-SAFE trigger: when the snapshot cannot be written (unwritable
    /// catalog directory), `snapshotCatalog` returns nil. In production this
    /// nil is exactly what makes `purgeCoverArtMusicRecords()` DEGRADE and
    /// remove nothing. (The degrade branch itself is gated off under the
    /// xctest host, so we pin its trigger here rather than fake the gate.)
    @Test func snapshotReturnsNilWhenDirectoryUnwritable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-coverart-snap-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Make the catalog dir read+execute only (no write) so encodeAndWrite fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.records = [
            rec(ext: "mp3", videoCodec: "mjpeg", streamType: .videoAndAudio,
                fullPath: "/Volumes/Music/y.mp3"),
        ]

        let path = model.snapshotCatalog(prefix: "pre-coverart-purge")
        #expect(path == nil,
                "an unwritable catalog dir must yield a nil snapshot — the purge's degrade trigger")
    }
}
