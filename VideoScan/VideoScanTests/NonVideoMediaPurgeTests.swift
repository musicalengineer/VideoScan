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

    // MARK: Regression sensor — cover-art record acts as a video anchor
    //
    // A cover-art music file is streamType .videoAndAudio, so it counts as a
    // relationship ANCHOR for the unrelated-audio predicate (isEssenceBearing).
    // Real music co-located in the SAME directory is therefore "related" and is
    // KEPT on a single classification pass — the conservative, keep-erring
    // direction. This pins that behavior: if the shared predicates are ever
    // changed so cover-art no longer anchors, THIS test flips and forces a
    // deliberate review (it is a design decision, not a silent refactor).
    @Test func coverArtAnchorProtectsCoLocatedMusicOnSinglePass() {
        // A real video anchor must exist so unrelated-audio classification is
        // active at all; otherwise the empty-anchor fail-safe would spare the
        // music for a different reason and the sensor would be meaningless.
        let farVideo = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let cover    = rec(streamType: .videoAndAudio,
                           fullPath: "/Volumes/Music/iTunes/art.mp3",
                           videoCodec: "mjpeg", ext: "mp3")
        let coLocated = rec(streamType: .audioOnly,
                            fullPath: "/Volumes/Music/iTunes/track.mp3")
        let c = NonVideoMediaPurge.classify(records: [farVideo, cover, coLocated])
        // The cover-art record itself IS a candidate (category .coverArt).
        #expect(c.categoryCount(.coverArt, volumeKeys: ["Music"]) == 1)
        // The co-located real music is protected by the cover-art anchor: it is
        // NOT an unrelated-audio candidate on this single pass.
        #expect(c.categoryCount(.unrelatedAudio, volumeKeys: ["Music"]) == 0)
        // Sanity: the same music in a dir with NO anchor WOULD be a candidate.
        let elsewhere = rec(streamType: .audioOnly,
                            fullPath: "/Volumes/Music/samples/track.mp3")
        let c2 = NonVideoMediaPurge.classify(records: [farVideo, cover, elsewhere])
        #expect(c2.categoryCount(.unrelatedAudio, volumeKeys: ["Music"]) == 1)
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

    // MARK: Scale — 100k records, SINGLE-DOMINANT-VOLUME distribution
    //
    // The real worst case (and the O(N²) trap QA caught) is ~77k unrelated-
    // audio records collapsing into ONE volume bucket — a samples drive, or an
    // internal tree where every path maps to key "rickb". An even N-way split
    // spreads the accumulation across cells and can pass at ~5s while the real
    // catalog is far slower, so we deliberately funnel almost all candidates
    // into a single cell here: if the amortized-O(1) append ever regresses to
    // COW-per-append, this cell alone is O(k²) with k≈90k and the strict budget
    // blows out immediately.
    @Test func classifyOneHundredKWithinBudget() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        // 10k video anchors so unrelated-audio classification is active. All on
        // the SAME dominant volume so their co-located audio can't be "related"
        // via a spread of anchor dirs — the samples live in their own dir.
        for i in 0..<10_000 {
            records.append(rec(streamType: .videoAndAudio,
                               fullPath: "/Volumes/Dominant/video/clip\(i).mov"))
        }
        // 90k unrelated audio ALL in one volume bucket, one directory → one
        // matrix cell accumulating ~90k ids. This is the O(N²) tripwire.
        for i in 0..<90_000 {
            records.append(rec(streamType: .audioOnly,
                               fullPath: "/Volumes/Dominant/loops/s\(i).wav"))
        }
        #expect(records.count == 100_000)

        let start = Date()
        let c = NonVideoMediaPurge.classify(records: records)
        let elapsed = Date().timeIntervalSince(start)
        // Strict budget — the single O(N) pass with amortized-O(1) appends is
        // well under a second; a COW-per-append regression pushes ONE 90k cell
        // into multi-second territory and trips this.
        #expect(elapsed < 2.0, "classify(100k, single-volume) took \(elapsed)s")

        // Everything funnels into the one volume bucket.
        #expect(c.volumeKeys == ["Dominant"])
        let all = Set(NonVideoCategory.allCases)
        #expect(c.totalCount(categories: all, volumeKeys: ["Dominant"]) == 90_000)
        #expect(c.candidateIDs(categories: all, volumeKeys: ["Dominant"]).count == 90_000)

        // Toggling is O(cells), not O(records): a batch of re-sums is instant.
        let toggleStart = Date()
        for _ in 0..<1_000 {
            _ = c.totalCount(categories: all, volumeKeys: ["Dominant"])
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
        // NOTE (testing agent, 2026-07-21): the unrelated-audio music must live
        // in a directory with NO video anchor, or the composed predicate keeps
        // it. A cover-art mp3 is streamType .videoAndAudio, so UnrelatedAudio-
        // Purge.isEssenceBearing counts it as a video anchor; audio co-located
        // in the SAME dir as such an anchor is "related" and is KEPT (the
        // conservative, keep-erring direction). The original fixture placed
        // one/two.mp3 in the same /Volumes/Music/iTunes dir as `cover`, so they
        // were spared and only `cover` was removed (removed == 1). Put the
        // sample-library music in its own /Volumes/Music/samples dir — anchored
        // by `video` on /Volumes/Fam elsewhere — so all three genuinely purge.
        // The cover-art-anchor interaction itself is pinned as a regression
        // sensor below (coverArtAnchorProtectsCoLocatedMusicOnSinglePass).
        let music1  = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/samples/one.mp3")
        let music2  = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/samples/two.mp3")
        let cover   = rec(streamType: .videoAndAudio,
                          fullPath: "/Volumes/Music/iTunes/art.mp3",
                          videoCodec: "mjpeg", ext: "mp3")

        let survivors = [video, paired, essence, coAudio]
        let doomed    = [music1, music2, cover]
        model.records = survivors + doomed
        model.searchIndex.rebuild(records: model.records)

        let outcome = model.purgeNonVideoMedia(
            categories: Set(NonVideoCategory.allCases),
            volumeKeys: ["Music"])
        let removed = outcome.removed

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
                                               volumeKeys: ["Music"]).removed
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
                                               volumeKeys: ["VolA"]).removed
        #expect(removed == 1)
        let paths = Set(model.records.map(\.fullPath))
        #expect(!paths.contains(a1.fullPath))
        #expect(paths.contains(b1.fullPath))
        #expect(paths.contains(video.fullPath))

        // The store on disk must agree — the removal persisted through the
        // injected store, and VolB's record survived there too.
        let reloaded = CatalogStore(directory: tmp).load()
        let reloadedPaths = Set(reloaded.map(\.fullPath))
        #expect(reloadedPaths.count == 2)
        #expect(reloadedPaths.contains(b1.fullPath))
        #expect(!reloadedPaths.contains(a1.fullPath))
    }

    // MARK: Isolation — a candidate whose volume key is empty/unexpected is
    // NOT removed when its volume isn't in the selection.
    //
    // VolumeReachability.volumeName(forPath:) returns "" for a bare filename
    // (no /Volumes or /Users prefix, < 3 path components) and a non-"Music"
    // token for other rooted paths (e.g. "/loose/x.wav" → "loose"). Such a
    // record can still be a genuine unrelated-audio CANDIDATE, but the removal
    // is volume-scoped: selecting only ["Music"] must spare it. This guards the
    // scoping boundary against a "default/empty bucket leaks into every purge"
    // regression — the worst-case would silently delete off-volume records.
    @Test func purgeVolumeScopedSparesEmptyOrUnexpectedVolumeKey() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-emptykey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()

        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        // Genuine unrelated-audio candidate on the "Music" volume — will be
        // removed when Music is selected.
        let onMusic = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/samples/m.wav")
        // Same kind of candidate but with an EMPTY volume key (bare filename)…
        let emptyKey = rec(streamType: .audioOnly, fullPath: "orphan.wav")
        // …and one with an UNEXPECTED, non-Music volume key ("loose").
        let oddKey = rec(streamType: .audioOnly, fullPath: "/loose/stray.wav")

        // Precondition: both odd-key records really ARE candidates (so the only
        // thing sparing them is volume scoping, not being non-candidates).
        let c = NonVideoMediaPurge.classify(records: [video, onMusic, emptyKey, oddKey])
        let all = Set(NonVideoCategory.allCases)
        #expect(c.candidateIDs(categories: all, volumeKeys: [""]).contains(emptyKey.id))
        #expect(c.candidateIDs(categories: all, volumeKeys: ["loose"]).contains(oddKey.id))

        model.records = [video, onMusic, emptyKey, oddKey]

        let removed = model.purgeNonVideoMedia(categories: [.unrelatedAudio],
                                               volumeKeys: ["Music"]).removed
        #expect(removed == 1, "only the Music-volume candidate should be removed")
        let paths = Set(model.records.map(\.fullPath))
        #expect(!paths.contains(onMusic.fullPath))     // removed
        #expect(paths.contains(emptyKey.fullPath))     // spared — empty key
        #expect(paths.contains(oddKey.fullPath))       // spared — unexpected key
        #expect(paths.contains(video.fullPath))        // never a candidate

        let reloaded = Set(CatalogStore(directory: tmp).load().map(\.fullPath))
        #expect(reloaded.contains(emptyKey.fullPath))
        #expect(reloaded.contains(oddKey.fullPath))
        #expect(!reloaded.contains(onMusic.fullPath))
    }

    // MARK: Outcome threading — count + recovery-snapshot path
    //
    // The completion dialog (NonVideoMediaPurgeSheet) needs BOTH the removed
    // count and the recovery-snapshot path to tell Rick "it's done, N removed,
    // saved here." This pins that purgeNonVideoMedia surfaces both through
    // PurgeOutcome. With an INJECTED temp store (not CatalogStore.shared) the
    // snapshot is genuinely written to the temp dir even under XCTest, so we can
    // assert a real, existing path — and that removed == 0 paths report a nil
    // snapshot (nothing destroyed ⇒ nothing to recover).
    @Test func purgeOutcomeReportsCountAndSnapshotPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // injected, not shared
        model.scanTargets.removeAll()

        let video = rec(streamType: .videoAndAudio, fullPath: "/Volumes/Fam/clip.mov")
        let m1 = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/samples/one.wav")
        let m2 = rec(streamType: .audioOnly, fullPath: "/Volumes/Music/samples/two.wav")
        model.records = [video, m1, m2]
        model.searchIndex.rebuild(records: model.records)

        // Non-empty purge → correct count AND a non-nil, on-disk snapshot path.
        let outcome = model.purgeNonVideoMedia(categories: [.unrelatedAudio],
                                               volumeKeys: ["Music"])
        #expect(outcome.removed == 2, "expected 2 removed, got \(outcome.removed)")
        let snapshot = try #require(outcome.snapshotPath,
                                    "non-empty purge must report a recovery snapshot path")
        #expect(FileManager.default.fileExists(atPath: snapshot),
                "reported snapshot must actually exist on disk: \(snapshot)")

        // Zero/refusal path → removed == 0 and NO snapshot (nothing destroyed).
        let noop = model.purgeNonVideoMedia(categories: [.unrelatedAudio],
                                            volumeKeys: ["Music"])   // already purged
        #expect(noop.removed == 0)
        #expect(noop.snapshotPath == nil,
                "a no-op purge must not write a recovery snapshot")
        #expect(noop == PurgeOutcome.none)
    }
}
