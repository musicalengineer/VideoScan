import Foundation
import Testing
@testable import VideoScan

// MARK: - Non-Video Media Purge — unified classification tests (2026-07-21)
//
// Authored by feature-dev as the initial pin for the unified purge dialog's
// composition layer (NonVideoMediaPurge + purgeNonVideoMedia). The testing
// agent owns the suite from here. These reuse the SAME synthetic-record
// harness the cover-art / unrelated-audio tests use — no real catalog, and
// the one store-touching test injects a temp CatalogStore.
//
// Dimensions covered:
//   • Logic — record → {coverArt, unrelatedAudio, none} classification.
//   • Volume-scoping — a candidate on volume A is counted for A and excluded
//     when A is deselected.
//   • Matrix sums — category / volume / total counts are consistent unions.
//   • Keep-guards — curated pairs + essence audio are never candidates under
//     the unified path.
//   • Empty-anchor — no video anchors ⇒ zero unrelated-audio candidates and
//     the model purge refuses that category.
//   • Scale — 100k records classify within a budget; toggling is O(cells).
//   • Isolation — the removal runs through an injected temp CatalogStore.

@MainActor
private func rec(streamType: StreamType,
                 fullPath: String,
                 videoCodec: String = "",
                 umid: String = "",
                 ext: String = "",
                 pairGroupID: UUID? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.streamTypeRaw = streamType.rawValue
    r.fullPath = fullPath
    r.videoCodec = videoCodec
    r.materialPackageUMID = umid
    r.filename = (fullPath as NSString).lastPathComponent
    r.directory = (fullPath as NSString).deletingLastPathComponent
    r.ext = ext.isEmpty ? (fullPath as NSString).pathExtension : ext
    r.pairGroupID = pairGroupID
    return r
}

@Suite(.serialized) @MainActor
struct NonVideoMediaPurgeClassificationTests {

    // MARK: Logic — 3-way category

    @Test func coverArtRecordClassifiesAsCoverArt() {
        // mp3 with a cover-art (mjpeg) video stream, video-tagged.
        let r = rec(streamType: .videoAndAudio,
                    fullPath: "/Volumes/Music/iTunes/song.mp3",
                    videoCodec: "mjpeg", ext: "mp3")
        let c = NonVideoMediaPurge.classify(records: [r,
            rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")])
        #expect(c.categoryCount(.coverArt, volumeKeys: ["Music"]) == 1)
        #expect(c.categoryCount(.unrelatedAudio, volumeKeys: ["Music"]) == 0)
    }

    @Test func unrelatedAudioClassifiesAsUnrelatedAudio() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let music = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/loop.wav")
        let c = NonVideoMediaPurge.classify(records: [video, music])
        #expect(c.categoryCount(.unrelatedAudio, volumeKeys: ["Music"]) == 1)
        #expect(c.categoryCount(.coverArt, volumeKeys: ["Music"]) == 0)
    }

    @Test func plainVideoIsNotAnyCandidate() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let c = NonVideoMediaPurge.classify(records: [video])
        #expect(c.volumeKeys.isEmpty)
        #expect(c.totalCount(categories: Set(NonVideoCategory.allCases),
                             volumeKeys: ["Fam"]) == 0)
    }

    // MARK: Keep-guards — pairs + essence survive

    @Test func curatedPairAndEssenceAudioAreNeverCandidates() {
        let video   = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let paired  = rec(streamType: .audioOnly,
                          fullPath: "/Volumes/Pairs/audio/take7.mxf",
                          pairGroupID: UUID())
        let essence = rec(streamType: .ffprobeFailed, fullPath: "/Volumes/Avid/OMFI/v.mxf")
        let coAudio = rec(streamType: .audioOnly, fullPath: "/Volumes/Avid/OMFI/a.mxf")
        let c = NonVideoMediaPurge.classify(records: [video, paired, essence, coAudio])
        // None of these must appear as candidates on any volume.
        let all = Set(NonVideoCategory.allCases)
        #expect(c.totalCount(categories: all, volumeKeys: Set(c.volumeKeys)) == 0)
        #expect(c.volumeKeys.isEmpty)
    }

    // MARK: Empty-anchor fail-safe

    @Test func noVideoAnchorsYieldsZeroUnrelatedAudioCandidates() {
        // Catalog with ONLY audio — every audio would look "unrelated", but
        // the fail-safe must nominate none.
        let a = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/a.wav")
        let b = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/b.wav")
        let c = NonVideoMediaPurge.classify(records: [a, b])
        #expect(!c.hasVideoAnchors)
        #expect(c.categoryCount(.unrelatedAudio, volumeKeys: ["Music"]) == 0)
        #expect(c.volumeKeys.isEmpty)
    }

    // MARK: Volume-scoping + matrix sums

    @Test func volumeScopingAndMatrixSums() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let mA1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolA/loops/a1.wav")
        let mA2 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolA/loops/a2.wav")
        let mB1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolB/samples/b1.wav")
        let coverB = rec(streamType: .videoOnly,
                         fullPath: "/Volumes/VolB/music/x.m4a",
                         videoCodec: "png", ext: "m4a")
        let c = NonVideoMediaPurge.classify(records: [video, mA1, mA2, mB1, coverB])

        let all = Set(NonVideoCategory.allCases)
        // VolA has 2 unrelated-audio; VolB has 1 unrelated + 1 cover-art.
        #expect(c.volumeCount("VolA", categories: all) == 2)
        #expect(c.volumeCount("VolB", categories: all) == 2)
        // Category counts across BOTH volumes.
        #expect(c.categoryCount(.unrelatedAudio, volumeKeys: ["VolA", "VolB"]) == 3)
        #expect(c.categoryCount(.coverArt, volumeKeys: ["VolA", "VolB"]) == 1)
        // Grand total across both = 4; sum of per-volume totals matches.
        #expect(c.totalCount(categories: all, volumeKeys: ["VolA", "VolB"]) == 4)
        // Deselect VolA → its 2 candidates drop out of the total.
        #expect(c.totalCount(categories: all, volumeKeys: ["VolB"]) == 2)
        // candidateIDs union scoping: only VolB rows when VolA deselected.
        let idsB = c.candidateIDs(categories: all, volumeKeys: ["VolB"])
        #expect(idsB.count == 2)
        #expect(idsB.contains(mB1.id))
        #expect(idsB.contains(coverB.id))
        #expect(!idsB.contains(mA1.id))
        // Deselect cover-art category → only unrelated-audio remains on VolB.
        #expect(c.totalCount(categories: [.unrelatedAudio], volumeKeys: ["VolB"]) == 1)
    }

    @Test func topLocationsRecomputeWithSelection() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let a1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolA/loops/a1.wav")
        let a2 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolA/loops/a2.wav")
        let b1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolB/samples/b1.wav")
        let c = NonVideoMediaPurge.classify(records: [video, a1, a2, b1])
        let all = Set(NonVideoCategory.allCases)
        let both = c.topLocations(categories: all, volumeKeys: ["VolA", "VolB"])
        #expect(both.total == 3)
        // /Volumes/VolA/loops (2) must sort ahead of /Volumes/VolB/samples (1).
        #expect(both.trees.first?.path == "/Volumes/VolA/loops")
        #expect(both.trees.first?.count == 2)
        // Scope to VolB only → just the one directory, total 1.
        let onlyB = c.topLocations(categories: all, volumeKeys: ["VolB"])
        #expect(onlyB.total == 1)
        #expect(onlyB.trees.count == 1)
        #expect(onlyB.trees.first?.path == "/Volumes/VolB/samples")
    }

    // MARK: Scale — 100k records

    @Test func classifyOneHundredKWithinBudget() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        // Anchors so unrelated-audio classification is active.
        for v in 0..<4 {
            for i in 0..<2_500 {
                records.append(rec(streamType: .videoAndAudio,
                                   fullPath: "/Volumes/Vol\(v)/video/clip\(i).mov"))
            }
        }
        // ~90k unrelated audio spread across the 4 volumes.
        for v in 0..<4 {
            for i in 0..<22_500 {
                records.append(rec(streamType: .audioOnly,
                                   fullPath: "/Volumes/Vol\(v)/loops/s\(i).wav"))
            }
        }
        #expect(records.count == 100_000)

        let start = Date()
        let c = NonVideoMediaPurge.classify(records: records)
        let elapsed = Date().timeIntervalSince(start)
        // Generous budget — the single O(N) pass should be well under this.
        #expect(elapsed < 5.0, "classify(100k) took \(elapsed)s")

        #expect(c.volumeKeys.count == 4)
        let all = Set(NonVideoCategory.allCases)
        #expect(c.totalCount(categories: all, volumeKeys: Set(c.volumeKeys)) == 90_000)

        // Toggling is O(cells), not O(records): a batch of re-sums is instant.
        let toggleStart = Date()
        for _ in 0..<1_000 {
            _ = c.totalCount(categories: all, volumeKeys: ["Vol0", "Vol2"])
        }
        let toggleElapsed = Date().timeIntervalSince(toggleStart)
        #expect(toggleElapsed < 0.5, "1000 re-sums took \(toggleElapsed)s")
    }
}

// MARK: - Isolation — removal through an injected temp CatalogStore

@Suite(.serialized) @MainActor
struct NonVideoMediaPurgeRemovalTests {

    @Test func purgeRemovesSelectedCategoriesAndKeepsPairsAndEssence() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // isolated store
        model.scanTargets.removeAll()

        let video   = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let paired  = rec(streamType: .audioOnly,
                          fullPath: "/Volumes/Pairs/audio/take7.mxf",
                          pairGroupID: UUID())
        let essence = rec(streamType: .ffprobeFailed, fullPath: "/Volumes/Avid/OMFI/v.mxf")
        let coAudio = rec(streamType: .audioOnly, fullPath: "/Volumes/Avid/OMFI/a.mxf")
        let music1  = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/iTunes/one.mp3")
        let music2  = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/iTunes/two.mp3")
        let cover   = rec(streamType: .videoAndAudio,
                          fullPath: "/Volumes/Music/iTunes/art.mp3",
                          videoCodec: "mjpeg", ext: "mp3")

        let survivors = [video, paired, essence, coAudio]
        let doomed    = [music1, music2, cover]
        model.records = survivors + doomed
        model.searchIndex.rebuild(records: model.records)

        let removed = model.purgeNonVideoMedia(
            categories: Set(NonVideoCategory.allCases),
            volumeKeys: ["Music"])

        #expect(removed == doomed.count,
                "expected \(doomed.count) removed on Music, got \(removed)")
        let paths = Set(model.records.map(\.fullPath))
        for d in doomed { #expect(!paths.contains(d.fullPath)) }
        for s in survivors { #expect(paths.contains(s.fullPath)) }

        // Persisted through the isolated store.
        let reloaded = CatalogStore(directory: tmp).load()
        #expect(reloaded.count == survivors.count)
    }

    @Test func purgeRefusesUnrelatedAudioWithoutAnchors() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-noanchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        // Audio-only catalog, no anchors.
        model.records = [
            rec(streamType: .audioOnly, fullPath: "/Volumes/Music/a.wav"),
            rec(streamType: .audioOnly, fullPath: "/Volumes/Music/b.wav"),
        ]
        let before = model.records.count
        let removed = model.purgeNonVideoMedia(categories: [.unrelatedAudio],
                                               volumeKeys: ["Music"])
        #expect(removed == 0, "empty-anchor purge must remove nothing")
        #expect(model.records.count == before)
    }

    @Test func purgeVolumeScopedLeavesOtherVolumes() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let a1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolA/loops/a1.wav")
        let b1 = rec(streamType: .audioOnly, fullPath: "/Volumes/VolB/loops/b1.wav")
        model.records = [video, a1, b1]

        // Purge only VolA — VolB's unrelated audio must remain.
        let removed = model.purgeNonVideoMedia(categories: [.unrelatedAudio],
                                               volumeKeys: ["VolA"])
        #expect(removed == 1)
        let paths = Set(model.records.map(\.fullPath))
        #expect(!paths.contains(a1.fullPath))
        #expect(paths.contains(b1.fullPath))
        #expect(paths.contains(video.fullPath))
    }
}
