import Foundation
import Testing
@testable import VideoScan

// MARK: - Cover-Art Music Purge tests (2026-07-20)
//
// Pins the pure identification predicate that both the live count and the
// removal share (CoverArtMusicPurge.isCandidate). A read-only dry-run of
// the live catalog found exactly 2,231 mis-cataloged music records, all
// with a fake video codec of mjpeg (2,146) or png (85). The predicate
// must catch those WITHOUT catching real motion-JPEG footage or records
// already correctly classified as audio-only.
//
// Feature-test dimensions covered here:
//   • Logic / media-matrix — the truth table across ext × codec × stream.
//   • Scale — isCandidate over 100k synthetic records with a time budget.
// Isolation is N/A: every assertion runs against the PURE predicate, so
// no test constructs a CatalogStore or reads Rick's real catalog. The
// removal-through-CatalogStore integration path (backup rotation + index
// rebuild) is left to the testing agent's injected-store harness.

@MainActor
private func rec(ext: String, videoCodec: String, streamType: StreamType) -> VideoRecord {
    let r = VideoRecord()
    r.ext = ext
    r.videoCodec = videoCodec
    r.streamTypeRaw = streamType.rawValue
    return r
}

@MainActor
@Suite("CoverArtMusicPurge.isCandidate")
struct CoverArtMusicPurgePredicateTests {

    @Test("mp3 + mjpeg + Video+Audio → candidate")
    func mp3MjpegAV() {
        #expect(CoverArtMusicPurge.isCandidate(
            rec(ext: "mp3", videoCodec: "mjpeg", streamType: .videoAndAudio)))
    }

    @Test("m4p + mjpeg + Video only → candidate")
    func m4pMjpegVideoOnly() {
        #expect(CoverArtMusicPurge.isCandidate(
            rec(ext: "m4p", videoCodec: "mjpeg", streamType: .videoOnly)))
    }

    @Test("m4a + png + Video+Audio → candidate")
    func m4aPngAV() {
        #expect(CoverArtMusicPurge.isCandidate(
            rec(ext: "m4a", videoCodec: "png", streamType: .videoAndAudio)))
    }

    @Test("mov + h264 + Video+Audio → NOT a candidate (real video)")
    func realVideoNotCandidate() {
        #expect(!CoverArtMusicPurge.isCandidate(
            rec(ext: "mov", videoCodec: "h264", streamType: .videoAndAudio)))
    }

    @Test("mov + mjpeg + Video only → NOT a candidate (real motion-JPEG, non-audio ext)")
    func realMotionJpegNotCandidate() {
        #expect(!CoverArtMusicPurge.isCandidate(
            rec(ext: "mov", videoCodec: "mjpeg", streamType: .videoOnly)))
    }

    @Test("mp3 + mjpeg + Audio only → NOT a candidate (already audio)")
    func alreadyAudioNotCandidate() {
        #expect(!CoverArtMusicPurge.isCandidate(
            rec(ext: "mp3", videoCodec: "mjpeg", streamType: .audioOnly)))
    }

    @Test("mp4 + hevc + Video+Audio → NOT a candidate")
    func mp4HevcNotCandidate() {
        #expect(!CoverArtMusicPurge.isCandidate(
            rec(ext: "mp4", videoCodec: "hevc", streamType: .videoAndAudio)))
    }

    @Test("case-insensitive: MP3 + MJPEG + Video+Audio → candidate")
    func caseInsensitive() {
        #expect(CoverArtMusicPurge.isCandidate(
            rec(ext: "MP3", videoCodec: "MJPEG", streamType: .videoAndAudio)))
    }

    @Test("audio ext + no video codec → NOT a candidate")
    func audioExtNoCodec() {
        #expect(!CoverArtMusicPurge.isCandidate(
            rec(ext: "m4a", videoCodec: "", streamType: .videoAndAudio)))
    }
}

@MainActor
@Suite("CoverArtMusicPurge scale")
struct CoverArtMusicPurgeScaleTests {

    @Test("isCandidate over 100k records finds exactly the planted count within budget")
    func scale() {
        let plantedCandidates = 2_231   // mirrors the live-catalog dry-run
        let total = 100_000
        var records: [VideoRecord] = []
        records.reserveCapacity(total)

        // Plant the known candidates: split mjpeg/png like the real catalog.
        for i in 0..<plantedCandidates {
            let codec = i < 2_146 ? "mjpeg" : "png"
            let stream: StreamType = (i % 2 == 0) ? .videoAndAudio : .videoOnly
            records.append(rec(ext: "mp3", videoCodec: codec, streamType: stream))
        }
        // Fill the rest with non-candidates that stress every near-miss:
        // real video, real motion-JPEG (.mov), already-audio, plain audio.
        for i in plantedCandidates..<total {
            switch i % 4 {
            case 0: records.append(rec(ext: "mov", videoCodec: "h264",  streamType: .videoAndAudio))
            case 1: records.append(rec(ext: "mov", videoCodec: "mjpeg", streamType: .videoOnly))
            case 2: records.append(rec(ext: "mp3", videoCodec: "mjpeg", streamType: .audioOnly))
            default: records.append(rec(ext: "wav", videoCodec: "",     streamType: .audioOnly))
            }
        }
        records.shuffle()

        let t0 = Date()
        let count = CoverArtMusicPurge.count(in: records)
        let elapsed = Date().timeIntervalSince(t0)

        #expect(count == plantedCandidates)
        // A single metadata-only pass over 100k records is trivial; a
        // generous 2 s ceiling catches any accidental O(n²) regression.
        #expect(elapsed < 2.0, "isCandidate scan took \(elapsed)s over 100k records")

        // candidateIDs must agree with count (same predicate, dedup by id).
        #expect(CoverArtMusicPurge.candidateIDs(in: records).count == plantedCandidates)
    }
}
