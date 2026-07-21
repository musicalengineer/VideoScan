import Foundation
import Testing
@testable import VideoScan

// MARK: - Unrelated Audio Purge — integration tests (2026-07-21)
//
// The pure predicate is pinned in UnrelatedAudioPurgeTests.swift (16 cases).
// THIS file exercises the REMOVAL end-to-end through a real (but ISOLATED)
// CatalogStore: seed a mixed catalog → purgeUnrelatedAudioRecords() → assert
// that ONLY the unrelated-music audio leaves `records`, and that EVERY
// must-keep row survives:
//   • video-bearing records,
//   • the curated-pair audio half (pairGroupID set, different dir/stem,
//     empty UMID — invisible to the relationship check, kept only by the
//     pairGroupID guard),
//   • the recovered-essence (.ffprobeFailed) record,
//   • audio co-located with that essence (same directory), and
//   • audio whose stem matches the essence (different directory).
// The removal is then confirmed persisted to the ISOLATED catalog.json —
// never Rick's real ~/Library/Application Support catalog.
//
// Isolation seam — the same "injected-store harness" the cover-art
// integration test uses (CoverArtMusicPurgeIntegrationTests):
//   `VideoScanModel.catalogStore` defaults to `CatalogStore.shared`. Tests
//   reassign it to `CatalogStore(directory:)` pointed at a per-test temp dir.
//   The shared store short-circuits all load/save under the test host
//   (`isRunningTests && self === .shared`), but an INJECTED store is not
//   `.shared`, so its real load/save/snapshot paths run — writing only
//   inside our temp dir.
//
//   // In C++ terms: dependency-inject a stub persistence backend instead of
//   // letting the singleton reach the real filesystem.
//
// Gating note (why the snapshot is pinned separately, below):
//   `purgeUnrelatedAudioRecords()` wraps its pre-purge snapshot + fail-safe
//   degrade in `if !Self.isRunningTests { ... }`, so under ANY xctest host
//   that whole block is bypassed and the removal proceeds without writing a
//   `pre-unrelated-audio-purge` file. The snapshot therefore cannot be
//   observed from INSIDE a test-host purge call. We instead pin the snapshot
//   PRIMITIVE the purge relies on (`snapshotCatalog(prefix:)`) directly —
//   both its success (a recovery copy lands in the isolated dir, prefixed
//   `catalog.pre-unrelated-audio-purge.`) and its nil-return-on-failure,
//   which is the exact condition that trips the purge's "destroy nothing"
//   degrade in production. This mirrors the cover-art split exactly.

@MainActor
private func rec(streamType: StreamType,
                 fullPath: String,
                 umid: String = "",
                 ext: String = "",
                 pairGroupID: UUID? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.streamTypeRaw = streamType.rawValue
    r.fullPath = fullPath
    r.materialPackageUMID = umid
    r.filename = (fullPath as NSString).lastPathComponent
    r.directory = (fullPath as NSString).deletingLastPathComponent
    r.ext = ext.isEmpty ? (fullPath as NSString).pathExtension : ext
    r.pairGroupID = pairGroupID
    return r
}

@Suite(.serialized) @MainActor
struct UnrelatedAudioPurgeIntegrationTests {

    /// Full removal path through the isolated store: ONLY the unrelated-music
    /// audio leaves the catalog; every video, the curated-pair audio, the
    /// recovered essence, and both essence-related audio rows SURVIVE; the
    /// count drops by exactly the unrelated-music count; the search index
    /// stops resolving a removed path but still resolves survivors; and the
    /// survivors persist to the isolated catalog.json on reload.
    @Test func purgeRemovesOnlyUnrelatedAudioAndKeepsPairsAndEssence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-unrelated-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // isolated store
        model.scanTargets.removeAll()

        // --- The mixed catalog --------------------------------------------
        // Two real home videos — video anchors, must be KEPT.
        let video1 = rec(streamType: .videoAndAudio,
                         fullPath: "/Vol/Family/1998/party.mov")
        let video2 = rec(streamType: .videoOnly,
                         fullPath: "/Vol/Family/2001/reel.mov")

        // Curated pair, audio half: pairGroupID set, a DIFFERENT dir with a
        // NON-matching stem and empty UMID — invisible to the relationship
        // check, kept ONLY by the pairGroupID guard. MUST SURVIVE.
        let pairedAudio = rec(streamType: .audioOnly,
                              fullPath: "/Vol/Pairs/audio_essence/take7.mxf",
                              umid: "",
                              pairGroupID: UUID())

        // Recovered Avid essence (ffprobe failed on the RGBA video half) —
        // still a real video anchor. MUST SURVIVE (never a candidate anyway).
        let essence = rec(streamType: .ffprobeFailed,
                          fullPath: "/Vol/Avid/OMFI/v_essence.mxf")
        // Audio co-located with the essence (same directory). MUST SURVIVE.
        let essenceAudioSameDir = rec(streamType: .audioOnly,
                                      fullPath: "/Vol/Avid/OMFI/a_essence.mxf")
        // Audio whose stem matches the essence, in a DIFFERENT dir. MUST SURVIVE.
        let essenceAudioSameStem = rec(streamType: .audioOnly,
                                       fullPath: "/Vol/Avid/audio/v_essence.wav")

        // Unrelated music in a music-only dir — the ONLY records that should
        // be removed. Distinct dir, distinct stems, empty UMID → unrelated.
        let music1 = rec(streamType: .audioOnly,
                         fullPath: "/Vol/Music/iTunes/song_one.mp3")
        let music2 = rec(streamType: .audioOnly,
                         fullPath: "/Vol/Music/iTunes/song_two.mp3")

        let doomed    = [music1, music2]
        let survivors = [video1, video2, pairedAudio,
                         essence, essenceAudioSameDir, essenceAudioSameStem]
        model.records = survivors + doomed
        model.searchIndex.rebuild(records: model.records)

        let countBefore = model.records.count

        // Sanity: doomed + a survivor resolve BEFORE the purge, so the
        // post-purge "no longer resolves / still resolves" checks mean something.
        #expect(model.searchIndex.hasHaystack(for: music1.fullPath))
        #expect(model.searchIndex.hasHaystack(for: video1.fullPath))
        #expect(model.searchIndex.hasHaystack(for: pairedAudio.fullPath))

        // --- The purge -----------------------------------------------------
        let removed = model.purgeUnrelatedAudioRecords()

        // Exactly the two unrelated-music records were removed.
        #expect(removed == doomed.count,
                "purge should remove exactly the \(doomed.count) unrelated-music records, got \(removed)")
        #expect(model.records.count == countBefore - doomed.count,
                "records.count must drop by exactly the unrelated-music count")

        let survivingPaths = Set(model.records.map(\.fullPath))
        for d in doomed {
            #expect(!survivingPaths.contains(d.fullPath),
                    "unrelated music \(d.fullPath) must be removed")
        }
        for s in survivors {
            #expect(survivingPaths.contains(s.fullPath),
                    "\(s.fullPath) is a must-keep record and must SURVIVE the purge")
        }

        // Search index: no longer resolves a removed path, still resolves the
        // must-keep rows (pair + essence-related audio especially).
        #expect(!model.searchIndex.hasHaystack(for: music1.fullPath),
                "search index must not resolve a purged path after rebuild")
        #expect(!model.searchIndex.hasHaystack(for: music2.fullPath))
        #expect(model.searchIndex.hasHaystack(for: video1.fullPath))
        #expect(model.searchIndex.hasHaystack(for: pairedAudio.fullPath))
        #expect(model.searchIndex.hasHaystack(for: essence.fullPath))
        #expect(model.searchIndex.hasHaystack(for: essenceAudioSameDir.fullPath))
        #expect(model.searchIndex.hasHaystack(for: essenceAudioSameStem.fullPath))

        // The removal was persisted through the isolated store: reload from
        // disk and confirm only the survivors are present.
        let reloaded = CatalogStore(directory: tmp).load()
        let reloadedPaths = Set(reloaded.map(\.fullPath))
        #expect(reloaded.count == survivors.count,
                "reload must contain exactly the \(survivors.count) survivors")
        for d in doomed {
            #expect(!reloadedPaths.contains(d.fullPath),
                    "purged \(d.fullPath) must not reappear on reload")
        }
        for s in survivors {
            #expect(reloadedPaths.contains(s.fullPath),
                    "survivor \(s.fullPath) must persist across reload")
        }

        // The isolated catalog.json exists; the real App Support catalog is
        // never named/touched here (this store points only at `tmp`).
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("catalog.json").path))
    }

    // MARK: - Snapshot primitive (the purge's safety net, pinned directly)

    /// `snapshotCatalog(prefix: "pre-unrelated-audio-purge")` — the exact
    /// recovery-copy call the purge makes in production — writes a
    /// `catalog.pre-unrelated-audio-purge.<stamp>.json` into the ISOLATED
    /// store dir (never App Support), and it round-trips.
    ///
    /// (The purge's own snapshot call is bypassed under the xctest host — see
    /// the file header — so this pins the mechanism it depends on.)
    @Test func snapshotPrimitiveWritesUnrelatedAudioRecoveryCopy() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-unrelated-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.records = [
            rec(streamType: .videoAndAudio, fullPath: "/Vol/Family/clip.mov"),
            rec(streamType: .audioOnly,     fullPath: "/Vol/Music/iTunes/song.mp3"),
        ]

        let path = model.snapshotCatalog(prefix: "pre-unrelated-audio-purge")

        let snap = try #require(path, "snapshot must be written to the isolated store dir")
        #expect(snap.hasPrefix(tmp.path),
                "snapshot must live in the isolated temp dir, NOT App Support: \(snap)")
        let name = (snap as NSString).lastPathComponent
        #expect(name.hasPrefix("catalog.pre-unrelated-audio-purge."))
        #expect(name.hasSuffix(".json"))
        #expect(FileManager.default.fileExists(atPath: snap))

        // The recovery copy must round-trip — it is the only pre-purge undo.
        let restored = try #require(model.catalogStore.loadRecords(fromSnapshotAtPath: snap))
        #expect(restored.count == 2)
        #expect(Set(restored.map(\.fullPath))
                    == ["/Vol/Family/clip.mov", "/Vol/Music/iTunes/song.mp3"])
    }

    /// FAIL-SAFE trigger: when the snapshot cannot be written (unwritable
    /// catalog directory), `snapshotCatalog` returns nil. In production this
    /// nil is exactly what makes `purgeUnrelatedAudioRecords()` DEGRADE and
    /// remove nothing. (The degrade branch itself is gated off under the
    /// xctest host, so we pin its trigger here rather than fake the gate.)
    @Test func snapshotReturnsNilWhenDirectoryUnwritable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-unrelated-snap-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Read+execute only (no write) so encodeAndWrite fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.records = [
            rec(streamType: .audioOnly, fullPath: "/Vol/Music/iTunes/y.mp3"),
        ]

        let path = model.snapshotCatalog(prefix: "pre-unrelated-audio-purge")
        #expect(path == nil,
                "an unwritable catalog dir must yield a nil snapshot — the purge's degrade trigger")
    }
}
