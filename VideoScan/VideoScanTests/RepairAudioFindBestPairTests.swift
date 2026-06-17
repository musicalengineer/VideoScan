// RepairAudioFindBestPairTests.swift
// Regression suite for issue #101 — "Repair Audio picks wrong
// candidate." Rick filed it after a real bad pairing in his catalog:
//
//   Video: /Volumes/RicksBackups/.../Donna_by_decade_20260403_115907.mp4
//   Audio: /Volumes/LaCieWorkspace/Avid MediaFiles/MXF/1/00030.A14CE00E59.mxf
//
// The Avid MXF orphan had no filename / directory / timecode / tape
// relationship to the Donna_by_decade demo clip — they shared only
// a coincidental ~11-second duration. The pre-fix scorer returned the
// MXF as the "best pair" because duration (+3) + timestamp (+3) = 6
// cleared the score >= 3 threshold even with zero structural signal.
//
// Fix: findBestPair now requires AT LEAST ONE structural signal
// (filename / directory / timecode / tape) before surfacing a pair
// to the user-facing "Repair Audio" verb. Pure duration+timestamp
// coincidence isn't enough — those are noisy across a catalog of
// thousands of files.
//
// Tests assert both the bug repro (returns nil) and that legitimate
// Avid V↔A pairings still work post-fix.
//
// Rick 2026-06-17.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Repair Audio — findBestPair")
struct RepairAudioFindBestPairTests {

    private func makeAV(
        path: String,
        streamType: StreamType,
        duration: Double = 0,
        dateCreated: Date? = nil,
        timecode: String = "",
        tapeName: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = streamType.rawValue
        r.durationSeconds = duration
        r.dateCreatedRaw = dateCreated
        r.timecode = timecode
        r.tapeName = tapeName
        return r
    }

    /// Bug #101: a duration+timestamp coincidence between an unrelated
    /// video and audio file must NOT surface as a best pair.
    @Test func issue101_donnaByDecadeDoesNotPairWithAvidOrphan() {
        let video = makeAV(
            path: "/Volumes/RicksBackups/RicksHomeBackup/Downloads/demo/Donna_by_decade_20260403_115907.mp4",
            streamType: .videoOnly,
            duration: 11.5,
            dateCreated: Date(timeIntervalSince1970: 1717000000)
        )
        let avidOrphan = makeAV(
            path: "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/Avid MediaFiles/MXF/1/00030.A14CE00E59.mxf",
            streamType: .audioOnly,
            duration: 11.4,
            dateCreated: Date(timeIntervalSince1970: 1717000005)
        )
        let result = CorrelationScorer.findBestPair(
            for: video,
            in: [video, avidOrphan],
            durationTolerance: 1.0,
            timestampTolerance: 5.0
        )
        #expect(result == nil,
                "Pure duration+timestamp coincidence must not produce a confident pair (issue #101).")
    }

    /// Symmetric: audio-only file shouldn't pair with an unrelated
    /// video by duration alone either.
    @Test func issue101_audioOnlyDoesNotPairWithUnrelatedVideoByDuration() {
        let audio = makeAV(
            path: "/Volumes/X/recording.wav",
            streamType: .audioOnly,
            duration: 60.0,
            dateCreated: Date(timeIntervalSince1970: 1717000000)
        )
        let unrelatedVideo = makeAV(
            path: "/Volumes/Y/totally/different/path/clip.mov",
            streamType: .videoOnly,
            duration: 60.5,
            dateCreated: Date(timeIntervalSince1970: 1717000003)
        )
        let result = CorrelationScorer.findBestPair(
            for: audio,
            in: [audio, unrelatedVideo],
            durationTolerance: 1.0,
            timestampTolerance: 5.0
        )
        #expect(result == nil)
    }

    /// Positive control: legitimate Avid V↔A pairing (matching clip
    /// IDs across V/A prefix) must still pair via the filename
    /// correlation key. Don't regress legitimate auto-pairing while
    /// fixing the bug.
    @Test func avidVideoToAvidAudioWithMatchingClipIDsStillPairs() {
        let video = makeAV(
            path: "/Volumes/X/Avid MediaFiles/MXF/1/00001.V14D1BBD3F.mxf",
            streamType: .videoOnly,
            duration: 30.0
        )
        let audio = makeAV(
            path: "/Volumes/X/Avid MediaFiles/MXF/1/00001.A14D1BBD3F.mxf",
            streamType: .audioOnly,
            duration: 30.0
        )
        let result = CorrelationScorer.findBestPair(
            for: video,
            in: [video, audio],
            durationTolerance: 1.0,
            timestampTolerance: 5.0
        )
        #expect(result != nil)
        #expect(result?.audio.filename == "00001.A14D1BBD3F.mxf")
    }

    /// Same-directory pair with matching duration should still pair —
    /// directory match is a legitimate structural signal even when
    /// filenames differ (common for user-renamed clips next to their
    /// original audio).
    @Test func sameDirectoryPlusDurationStillPairs() {
        let video = makeAV(
            path: "/Volumes/X/Project/clip_renamed.mov",
            streamType: .videoOnly,
            duration: 45.0
        )
        let audio = makeAV(
            path: "/Volumes/X/Project/audio_take_3.wav",
            streamType: .audioOnly,
            duration: 45.2
        )
        let result = CorrelationScorer.findBestPair(
            for: video,
            in: [video, audio],
            durationTolerance: 1.0,
            timestampTolerance: 5.0
        )
        #expect(result != nil, "Directory + duration should still cross the threshold")
    }

    /// Timecode-matched pair (rare but real in pro workflows) should
    /// still pair even when filenames differ.
    @Test func matchingTimecodeAcrossDirectoriesStillPairs() {
        let video = makeAV(
            path: "/Volumes/X/A/take_03.mov",
            streamType: .videoOnly,
            duration: 12.0,
            timecode: "01:02:03:04"
        )
        let audio = makeAV(
            path: "/Volumes/X/B/separate_rec.wav",
            streamType: .audioOnly,
            duration: 12.1,
            timecode: "01:02:03:04"
        )
        let result = CorrelationScorer.findBestPair(
            for: video,
            in: [video, audio],
            durationTolerance: 1.0,
            timestampTolerance: 5.0
        )
        #expect(result != nil, "Timecode match is a structural signal that should clear the threshold")
    }

    /// findBestPair must skip records that aren't strictly opposite
    /// types (video↔audio). A video-only record can't pair with
    /// another video-only.
    @Test func videoOnlyDoesNotPairWithVideoOnly() {
        let a = makeAV(path: "/V/a.mov", streamType: .videoOnly, duration: 10)
        let b = makeAV(path: "/V/b.mov", streamType: .videoOnly, duration: 10)
        #expect(CorrelationScorer.findBestPair(
            for: a, in: [a, b],
            durationTolerance: 1.0, timestampTolerance: 5.0
        ) == nil)
    }
}
