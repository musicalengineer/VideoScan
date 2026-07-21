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
                 ext: String = "") -> VideoRecord {
    let r = VideoRecord()
    r.streamTypeRaw = streamType.rawValue
    r.fullPath = fullPath
    r.materialPackageUMID = umid
    r.filename = (fullPath as NSString).lastPathComponent
    r.directory = (fullPath as NSString).deletingLastPathComponent
    r.ext = ext.isEmpty ? (fullPath as NSString).pathExtension : ext
    return r
}

@MainActor
@Suite("UnrelatedAudioPurge criterion")
struct UnrelatedAudioPurgeCriterionTests {

    // A single video-bearing record used to build the relationship sets.
    private func videoSets(_ records: [VideoRecord]) -> UnrelatedAudioPurge.VideoSets {
        UnrelatedAudioPurge.videoSets(in: records)
    }

    @Test("audio in a music-only dir, no video anywhere → candidate")
    func lonelyMusicIsCandidate() {
        let audio = rec(streamType: .audioOnly,
                        fullPath: "/Vol/Logic/Library.bundle/Samples/loop_01.wav")
        let sets = videoSets([audio])   // no video-bearing records at all
        #expect(UnrelatedAudioPurge.isCandidate(audio, videoSets: sets))
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
