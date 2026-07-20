import Foundation
import Testing
@testable import VideoScan

// MARK: - Music-triage chip precision tests (GH #124 layer 2)
//
// The PRECISION RULE is the load-bearing contract: the chip must NEVER
// suggest audio that belongs to the video mission —
//   * MXF audio halves (Avid essence) — never, unconditionally;
//   * correlated audio (pairedWith / pairGroupID) — never;
//   * video-adjacent audio (same stem as ANY video-bearing record via
//     correlate's own filenameCorrelationKey) — never.
// False negatives are acceptable; false positives are the failure mode.
//
// Five-dimension coverage:
//   Logic     — the truth table below (positives AND every veto).
//   Scale     — 100k synthetic records with an explicit budget (the memo
//               recompute path runs on the main thread per catalog
//               mutation, so this pins its cost).
//   Isolation — pure functions over constructed records; no defaults, no
//               real paths.
//   Sensor    — layer-2/layer-3 alignment: MusicTriage.pathMarkers is
//               DERIVED from SkipCategories.musicLibraryDirs, so the
//               trees the scanner skips are the trees the chip flags.
// Media matrix: N/A — pure catalog metadata, no file I/O.

/// Production stores `ext` UPPERCASED (probe engine:
/// `url.pathExtension.uppercased()`) — mirror that here so the tests
/// exercise the same case-insensitivity the real catalog needs.
private func mtRec(
    _ filename: String,
    stream: StreamType = .audioOnly,
    dir: String = "/Volumes/Backup/stuff",
    purged: Bool = false,
    setAside: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = 5_000_000
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    r.setAsideReason = setAside
    return r
}

private func candidateNames(_ records: [VideoRecord]) -> Set<String> {
    let ids = Set(MusicTriage.candidateIDs(in: records))
    return Set(records.filter { ids.contains($0.id) }.map(\.filename))
}

@Suite("Music triage — chip population precision")
struct MusicTriagePrecisionTests {

    // MARK: Positives

    @Test func musicExtensionAnywhereQualifies() {
        // mp3/m4a/etc. qualify by extension alone — no path marker needed.
        let recs = [
            mtRec("track01.mp3"),
            mtRec("song.m4a", dir: "/Volumes/Old/random"),
            mtRec("ripped.ogg"),
            mtRec("radio.aac"),
            mtRec("win.wma"),
            mtRec("protected.m4p"),
        ]
        #expect(candidateNames(recs) == ["track01.mp3", "song.m4a", "ripped.ogg",
                                         "radio.aac", "win.wma", "protected.m4p"])
    }

    @Test func iTunesPathQualifiesNonMusicExtensions() {
        // A .wav qualifies ONLY via a library path marker.
        let inLibrary = mtRec("take.wav",
                              dir: "/Volumes/Backup/iTunes/iTunes Media/Music/Artist")
        let bundle = mtRec("cut.wav",
                           dir: "/Volumes/B/Music/Music Library.musiclibrary/Media")
        let generic = mtRec("interview.wav", dir: "/Volumes/Backup/1994")
        let names = candidateNames([inLibrary, bundle, generic])
        #expect(names == ["take.wav", "cut.wav"])
    }

    @Test func caseInsensitiveExtensionAndPath() {
        // Real catalog ext is "MP3"; paths may carry any casing.
        let recs = [
            mtRec("SHOUTY.MP3"),
            mtRec("take.wav", dir: "/Volumes/Backup/ITUNES/ITUNES MUSIC"),
        ]
        #expect(candidateNames(recs).count == 2)
    }

    // "Wedding/Music" is a family folder, NOT a library marker — the
    // deliberate reason bare "music" is not in musicLibraryDirs.
    @Test func bareMusicFolderIsNotAMarker() {
        let wav = mtRec("ceremony.wav", dir: "/Volumes/Backup/Wedding/Music")
        #expect(candidateNames([wav]).isEmpty)
    }

    // MARK: Precision vetoes (the NEVER cases)

    @Test func mxfAudioHalvesNeverSuggested() {
        // Even in an iTunes path, even audio-only — .mxf is Avid essence.
        let orphanHalf = mtRec("00000.A14BB2CE9D.mxf", dir: "/Volumes/Avid/media")
        let perversePath = mtRec("half.mxf", dir: "/Volumes/Backup/iTunes/iTunes Media")
        #expect(candidateNames([orphanHalf, perversePath]).isEmpty,
                "MXF audio halves must NEVER be suggested as music")
    }

    @Test func pairedAudioNeverSuggested() {
        // A correlated pair half — even with a music extension (perverse
        // but possible after a rename) is settled A/V history.
        let video = mtRec("clipV.mov", stream: .videoOnly)
        let audio = mtRec("clipsound.m4a")
        audio.pairedWith = video
        audio.pairGroupID = UUID()
        video.pairedWith = audio
        #expect(candidateNames([video, audio]).isEmpty)
        // pairGroupID alone (defensive — should always travel with
        // pairedWith, but the veto checks both).
        let grouped = mtRec("grouped.mp3")
        grouped.pairGroupID = UUID()
        #expect(candidateNames([grouped]).isEmpty)
    }

    @Test func sameStemAsVideoNeverSuggested() {
        // Video-adjacent audio: same stem as a video sibling, protected
        // BEFORE correlate has run (no pair links set).
        let video = mtRec("Wedding1994.mov", stream: .videoAndAudio)
        let adjacent = mtRec("Wedding1994.m4a")   // music ext, same stem
        let unrelated = mtRec("PartyMix.m4a")
        #expect(candidateNames([video, adjacent, unrelated]) == ["PartyMix.m4a"])
    }

    @Test func avidStemHeuristicProtectsAcrossVAndAForms() {
        // correlate's key normalizes {Tape}{V|A}{nn}.{clipID} to the same
        // key — an audio half in a non-mxf container is still protected
        // when its video half is cataloged.
        let video = mtRec("NewTape9V01.4B9C1586.8D8520.mxf", stream: .videoOnly)
        let audioAiff = mtRec("NewTape9A01.4B9C1586.8D8520.aiff")
        #expect(candidateNames([video, audioAiff]).isEmpty)
    }

    @Test func damagedVideoStillProtectsSameStemAudio() {
        // ffprobeFailed sibling (damaged Avid video) still contributes
        // its stem to the protection set.
        let broken = mtRec("Reel7.mov", stream: .ffprobeFailed)
        let sibling = mtRec("Reel7.m4a")
        #expect(candidateNames([broken, sibling]).isEmpty)
    }

    @Test func nonAudioShapesNeverSuggested() {
        // Stream shape is decided by probe evidence, not extension: a
        // video-bearing .mp3 (mislabeled) is not audio-only, so no chip.
        let weird = mtRec("mislabeled.mp3", stream: .videoAndAudio)
        let still = mtRec("noStreams.mp3", stream: .noStreams)
        let failed = mtRec("failed.mp3", stream: .ffprobeFailed)
        #expect(candidateNames([weird, still, failed]).isEmpty)
    }

    @Test func purgedAndSetAsideExcluded() {
        let purged = mtRec("gone.mp3", purged: true)
        let aside = mtRec("tidied.mp3", setAside: "music-format")
        let live = mtRec("live.mp3")
        #expect(candidateNames([purged, aside, live]) == ["live.mp3"])
    }

    // MARK: Layer alignment sensor

    @Test func pathMarkersDeriveFromScanSkipSet() {
        // Layer 2 (catalog triage) and layer 3 (scan prevention) must
        // agree: every scan-skip dir name appears as a path marker.
        for dirName in SkipCategories.musicLibraryDirs {
            #expect(MusicTriage.pathMarkers.contains("/\(dirName)/"),
                    "scan-skip dir '\(dirName)' missing from triage markers")
        }
        // Plus the bundle shapes that appear as path segments in
        // already-cataloged records.
        #expect(MusicTriage.pathMarkers.contains(".musiclibrary/"))
        #expect(MusicTriage.pathMarkers.contains(".itlp/"))
    }

    @Test func verdictHelperAgreesWithBatch() {
        // candidateVerdict (exposed for these tests) and candidateIDs
        // must agree — pins the precomputed-stem-set plumbing.
        let video = mtRec("Wedding1994.mov", stream: .videoAndAudio)
        let adjacent = mtRec("Wedding1994.m4a")
        let music = mtRec("PartyMix.m4a")
        let recs = [video, adjacent, music]
        let keys = MusicTriage.videoStemKeys(in: recs)
        #expect(!MusicTriage.candidateVerdict(adjacent, videoStemKeys: keys))
        #expect(MusicTriage.candidateVerdict(music, videoStemKeys: keys))
        #expect(MusicTriage.candidateIDs(in: recs) == [music.id])
    }
}

// MARK: Scale

@Suite("Music triage — scale")
struct MusicTriageScaleTests {

    // 100k records at Rick's real shape (~78% audio-only, mostly music,
    // some MXF halves and video-adjacent wavs mixed in). The detection
    // pass runs on the main thread once per catalog mutation via the
    // RenderMemo — this budget pins that cost. Budget is generous for
    // Debug-build CI variance; the sensor half asserts exact precision
    // at scale, not just speed.
    @Test func candidates100kWithinBudgetAndPrecise() {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        var expectedCandidates = 0
        for i in 0..<100_000 {
            switch i % 10 {
            case 0, 1:      // 20% video-bearing
                recs.append(mtRec("clip\(i).mov", stream: .videoAndAudio))
            case 2:         // 10% MXF audio halves — never suggested
                recs.append(mtRec("0000\(i).A14BB2CE\(i).mxf",
                                  dir: "/Volumes/Avid/media"))
            case 3:         // 10% video-adjacent audio with a MUSIC extension
                            // (stem matches case 0's clip) — the same-stem
                            // veto must beat the extension qualifier
                recs.append(mtRec("clip\(i - 3).m4a"))
            default:        // 60% music library files — all suggested
                recs.append(mtRec("track\(i).mp3",
                                  dir: "/Volumes/Backup/iTunes/iTunes Media/Music"))
                expectedCandidates += 1
            }
        }
        let start = Date()
        let ids = MusicTriage.candidateIDs(in: recs)
        let elapsed = Date().timeIntervalSince(start)
        #expect(ids.count == expectedCandidates,
                "expected \(expectedCandidates) candidates, got \(ids.count)")
        #expect(elapsed < 3.0,
                "music-triage detection over 100k took \(elapsed)s — budget 3.0s (Debug)")
    }
}
