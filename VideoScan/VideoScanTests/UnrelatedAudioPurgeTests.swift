import Foundation
import Testing
@testable import VideoScan

// MARK: - Unrelated Audio Purge tests (2026-07-21)
//
// Pins the pure criterion shared by the live count and the removal
// (UnrelatedAudioPurge.isCandidate + isRelatedToVideo). A record is a
// purge candidate iff it is audio-only AND unrelated to any video-bearing
// record, where "related" = same directory, or matching filename stem, or
// matching non-empty materialPackageUMID.
//
// Feature-test dimensions covered here:
//   • Logic / media-matrix — the relationship truth table.
//   • Scale — count over 100k synthetic records with a time budget,
//     proving the precompute-then-O(1) path (not O(N²)).
//   • Isolation — every assertion runs against the PURE criterion on
//     synthetic records; no test constructs a CatalogStore or reads Rick's
//     real catalog. The removal-through-CatalogStore integration path is
//     left to the testing agent's injected-store harness (mirrors the
//     cover-art split).

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

@MainActor
@Suite("UnrelatedAudioPurge criterion")
struct UnrelatedAudioPurgeCriterionTests {

    // A single video-bearing record used to build the relationship sets.
    private func videoSets(_ records: [VideoRecord]) -> UnrelatedAudioPurge.VideoSets {
        UnrelatedAudioPurge.videoSets(in: records)
    }

    @Test("audio in a music-only dir WITH some video anchor elsewhere → candidate")
    func lonelyMusicWithAnchorIsCandidate() {
        // A real video anchor exists (different dir) so the catalog is not
        // anchor-empty; the unrelated sample is a genuine candidate.
        let video = rec(streamType: .videoAndAudio, fullPath: "/Vol/Family/clip.mov")
        let audio = rec(streamType: .audioOnly,
                        fullPath: "/Vol/Logic/Library.bundle/Samples/loop_01.wav")
        let sets = videoSets([video, audio])
        #expect(UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
        #expect(UnrelatedAudioPurge.count(in: [video, audio]) == 1)
    }

    @Test("zero-anchor catalog (only audio) → aggregates refuse: no candidates")
    func zeroAnchorCatalogRefuses() {
        // A catalog scanned before its video volumes were online: only
        // audio. The pure per-record predicate would call each unrelated,
        // but the aggregate entry points MUST nominate nothing (fail-safe),
        // and the summary reports hasVideoAnchors == false.
        let all = [
            rec(streamType: .audioOnly, fullPath: "/Vol/Logic/Samples/a.wav"),
            rec(streamType: .audioOnly, fullPath: "/Vol/AppleLoops/b.caf"),
            rec(streamType: .noStreams, fullPath: "/Vol/Misc/notes.txt"),
        ]
        #expect(UnrelatedAudioPurge.count(in: all) == 0)
        #expect(UnrelatedAudioPurge.candidates(in: all).isEmpty)
        #expect(UnrelatedAudioPurge.candidateIDs(in: all).isEmpty)
        #expect(!UnrelatedAudioPurge.hasVideoAnchors(in: all))
        let summary = UnrelatedAudioPurge.summary(in: all)
        #expect(!summary.hasVideoAnchors)
        let summaryCount = summary.count   // local Int — avoid empty_count misfire
        #expect(summaryCount == 0)
    }

    @Test("paired audio (curated pair) in a different dir/stem, empty UMID → KEEP")
    func pairedAudioIsKept() {
        // The audio half of a hand-correlated pair: matched by tape.clipID,
        // so it can live in a DIFFERENT dir with a DIFFERENT stem and empty
        // UMID — invisible to the relationship check. The pairGroupID guard
        // must keep it even though a video anchor exists elsewhere.
        let video = rec(streamType: .videoOnly, fullPath: "/Vol/A/reel.mxf")
        let pairedAudio = rec(streamType: .audioOnly,
                              fullPath: "/Vol/Zzz/audio_essence/take7.mxf",
                              pairGroupID: UUID())
        let sets = videoSets([video, pairedAudio])
        #expect(!UnrelatedAudioPurge.isCandidate(pairedAudio, videoSets: sets))
        #expect(UnrelatedAudioPurge.candidates(in: [video, pairedAudio]).isEmpty)
    }

    @Test("audio co-located with a recovered-essence (.ffprobeFailed) record → KEEP")
    func audioColocatedWithEssenceIsKept() {
        // Recovered Avid essence: ffprobe failed on the RGBA video half, so
        // it's .ffprobeFailed — but it must still anchor its co-located
        // audio half (same directory).
        let essence = rec(streamType: .ffprobeFailed, fullPath: "/Vol/Avid/OMFI/v_essence.mxf")
        let audio   = rec(streamType: .audioOnly,     fullPath: "/Vol/Avid/OMFI/a_essence.mxf")
        let sets = videoSets([essence, audio])
        #expect(!UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
    }

    @Test("audio with same stem as a recovered-essence record (different dir) → KEEP")
    func audioStemMatchesEssenceIsKept() {
        let essence = rec(streamType: .ffprobeFailed, fullPath: "/Vol/Avid/v/clip42.mxf")
        let audio   = rec(streamType: .audioOnly,     fullPath: "/Vol/Avid/a/clip42.mxf")
        let sets = videoSets([essence, audio])
        #expect(!UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
    }

    @Test("audio co-located with a video in the same dir → KEEP (same directory)")
    func sameDirIsKept() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Vol/Family/1998/party.mov")
        let audio = rec(streamType: .audioOnly,     fullPath: "/Vol/Family/1998/stray.wav")
        let sets = videoSets([video, audio])
        #expect(!UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
        #expect(UnrelatedAudioPurge.isRelatedToVideo(audio, videoSets: sets))
    }

    @Test("audio whose stem matches a video stem in a different dir → KEEP (stem match)")
    func stemMatchIsKept() {
        let video = rec(streamType: .videoOnly, fullPath: "/Vol/A/reel3.mxf")
        let audio = rec(streamType: .audioOnly, fullPath: "/Vol/B/audio/reel3.wav")
        let sets = videoSets([video, audio])
        #expect(!UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
        #expect(UnrelatedAudioPurge.isRelatedToVideo(audio, videoSets: sets))
    }

    @Test("audio sharing a video's UMID → KEEP (UMID match)")
    func umidMatchIsKept() {
        let umid = "060a2b34.0101.0105.01010f20.13000000"
        let video = rec(streamType: .videoOnly, fullPath: "/Vol/A/v.mxf", umid: umid)
        let audio = rec(streamType: .audioOnly, fullPath: "/Vol/B/a.mxf", umid: umid)
        let sets = videoSets([video, audio])
        #expect(!UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
    }

    @Test("empty UMID on both sides is NOT a match (relationship needs non-empty UMID)")
    func emptyUmidIsNotAMatch() {
        // Distinct dirs, distinct stems, both UMIDs empty → unrelated.
        let video = rec(streamType: .videoOnly, fullPath: "/Vol/A/movie.mxf", umid: "")
        let audio = rec(streamType: .audioOnly, fullPath: "/Vol/B/sample.wav", umid: "")
        let sets = videoSets([video, audio])
        #expect(UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
    }

    @Test("a video record is never a candidate")
    func videoNeverCandidate() {
        let video = rec(streamType: .videoAndAudio, fullPath: "/Vol/A/v.mov")
        let sets = videoSets([video])
        #expect(!UnrelatedAudioPurge.isCandidate(video, videoSets: sets))
    }

    @Test("an ffprobeFailed record is never a candidate (recovered Avid essence — keep)")
    func ffprobeFailedNeverCandidate() {
        let recovered = rec(streamType: .ffprobeFailed, fullPath: "/Vol/Avid/OMFI/essence.mxf")
        let sets = videoSets([recovered])
        #expect(!UnrelatedAudioPurge.isCandidate(recovered, videoSets: sets))
    }

    @Test("a noStreams record is never a candidate")
    func noStreamsNeverCandidate() {
        let empty = rec(streamType: .noStreams, fullPath: "/Vol/A/empty.dat")
        let sets = videoSets([empty])
        #expect(!UnrelatedAudioPurge.isCandidate(empty, videoSets: sets))
    }

    @Test("whole-catalog candidates() returns exactly the unrelated audio, keeps related audio")
    func wholeCatalogPartition() {
        let video      = rec(streamType: .videoAndAudio, fullPath: "/Vol/Family/1998/party.mov")
        let relatedDir = rec(streamType: .audioOnly,     fullPath: "/Vol/Family/1998/stray.wav")
        let relatedStem = rec(streamType: .audioOnly,    fullPath: "/Vol/Other/party.wav")
        let junk1      = rec(streamType: .audioOnly,     fullPath: "/Vol/Logic/Samples/a.wav")
        let junk2      = rec(streamType: .audioOnly,     fullPath: "/Vol/AppleLoops/b.caf")
        let all = [video, relatedDir, relatedStem, junk1, junk2]

        let candidates = UnrelatedAudioPurge.candidates(in: all)
        let paths = Set(candidates.map(\.fullPath))
        #expect(paths == [junk1.fullPath, junk2.fullPath])
        #expect(UnrelatedAudioPurge.count(in: all) == 2)
        #expect(UnrelatedAudioPurge.candidateIDs(in: all).count == 2)
    }

    @Test("summary() reports the top directories among candidates")
    func summaryTopTrees() {
        var all: [VideoRecord] = []
        // A video anchor (different dir/stem) so the catalog is not anchor-
        // empty; the sample audio below stays unrelated → candidates.
        all.append(rec(streamType: .videoAndAudio, fullPath: "/Vol/Family/clip.mov"))
        // 5 junk in /Vol/Logic/Samples, 3 in /Vol/AppleLoops, 1 elsewhere.
        for i in 0..<5 { all.append(rec(streamType: .audioOnly, fullPath: "/Vol/Logic/Samples/s\(i).wav")) }
        for i in 0..<3 { all.append(rec(streamType: .audioOnly, fullPath: "/Vol/AppleLoops/l\(i).caf")) }
        all.append(rec(streamType: .audioOnly, fullPath: "/Vol/Misc/one.wav"))

        let summary = UnrelatedAudioPurge.summary(in: all, topN: 6)
        #expect(summary.count == 9)
        #expect(summary.topTrees.first?.path == "/Vol/Logic/Samples")
        #expect(summary.topTrees.first?.count == 5)
        #expect(summary.topTrees.count == 3)
    }
}

@Suite(.serialized) @MainActor
struct UnrelatedAudioPurgeRefusalTests {

    /// The model's empty-anchor guard: purging a catalog with NO video /
    /// essence anchor removes nothing (refuses) and leaves records intact.
    /// Uses an injected temp store per the harness convention, though the
    /// refusal returns before any snapshot/save is attempted.
    @Test func purgeRefusesWhenNoVideoAnchors() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-unrelated-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        model.records = [
            rec(streamType: .audioOnly, fullPath: "/Vol/Logic/Samples/a.wav"),
            rec(streamType: .audioOnly, fullPath: "/Vol/AppleLoops/b.caf"),
        ]
        let before = model.records.count

        let removed = model.purgeUnrelatedAudioRecords()

        #expect(removed == 0, "no video anchors → purge must refuse and remove nothing")
        #expect(model.records.count == before, "records untouched on refusal")
    }
}

@MainActor
@Suite("UnrelatedAudioPurge scale")
struct UnrelatedAudioPurgeScaleTests {

    @Test("count over 100k records is correct AND within budget (O(N), not O(N²))")
    func scale() {
        let total = 100_000
        let videoCount = 16_000            // video-bearing
        let relatedAudio = 4_000           // audio related to a video (KEEP)
        // remainder is unrelated audio junk (PURGE)
        var records: [VideoRecord] = []
        records.reserveCapacity(total)

        // Video-bearing records, each in its own family dir with a stem.
        for i in 0..<videoCount {
            records.append(rec(streamType: (i % 2 == 0) ? .videoAndAudio : .videoOnly,
                               fullPath: "/Vol/Family/reel\(i)/clip\(i).mov"))
        }
        // Related audio: co-located in a video dir (same-directory relation).
        for i in 0..<relatedAudio {
            records.append(rec(streamType: .audioOnly,
                               fullPath: "/Vol/Family/reel\(i)/stray\(i).wav"))
        }
        // Unrelated junk: Logic/Apple Loops sample libraries, no video link.
        let junkCount = total - videoCount - relatedAudio
        for i in 0..<junkCount {
            records.append(rec(streamType: .audioOnly,
                               fullPath: "/Vol/Logic/Library.bundle/Samples/loop\(i).wav"))
        }
        records.shuffle()

        let t0 = Date()
        let count = UnrelatedAudioPurge.count(in: records)
        let elapsed = Date().timeIntervalSince(t0)

        #expect(count == junkCount,
                "expected \(junkCount) unrelated-audio candidates, got \(count)")
        // Precompute-then-O(1) over 100k must be trivial; a 2 s ceiling
        // catches any accidental O(N²) regression.
        #expect(elapsed < 2.0, "count scan took \(elapsed)s over 100k records")

        // candidateIDs agrees with count (same criterion, dedup by id).
        #expect(UnrelatedAudioPurge.candidateIDs(in: records).count == junkCount)
    }
}
