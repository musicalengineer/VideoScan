// CorrelatorDurationGateTests.swift
// GH #125 — duration-compatibility gate for A/V correlation.
//
// The real incident: Correlate paired a 3808.27 s video-only Avid MXF
// (`Untitled Sequence.04D1C4907.mxf`) with an UNRELATED 125.6255 s
// audio-only MXF (`00047.PHYSA01.1_4D14D1C5284.mxf`) from the same
// directory — directory + timestamp coincidence cleared the score
// floor. Combine then muxed them into an hour-long family video with
// 2 minutes of wrong audio. CombineVerifier's audio-coverage check
// (commit 3974f9d) now catches the damage post-mux; these tests pin
// that the correlator never OFFERS such a pair in the first place.
//
// Gate rule (CorrelationScorer.durationCompatible): compatible iff
// both durations are known (> 0) and
//     abs(v - a) <= max(2.0, 0.02 * max(v, a))
// — the same tolerance shape as CombineVerifier's coverage check.
// Unknown/zero durations fail the gate on the fuzzy/scored paths
// (do-nothing-rather-than-conflate); the Avid clip-ID path is the
// deliberate exception (structural identity + ffprobe routinely fails
// on Avid RGBA video), gated only when BOTH durations are known.
//
// Feature-test checklist coverage:
//   1. Logic    — gate math boundaries + pair-formation exclusion below.
//   2. Scale    — 100k synthetic snaps through assignPairs with a
//                 wall-clock budget (DurationGateScaleTests).
//   3. Media    — N/A: this is a metadata-only change; no code path
//                 here opens a media file.
//   4. Isolation— N/A: the gate and both scoring pipelines are pure
//                 functions over their inputs (no UserDefaults, no
//                 shared caches, no real paths read).
//   5. Sensor   — issue125_* tests reproduce the incident shape at
//                 metadata level and pin the fixed behavior.

import Testing
import Foundation
@testable import VideoScan

// MARK: - 1a. Gate math (pure function boundaries)

@Suite("Duration gate — math")
struct DurationGateMathTests {

    @Test func exactlyAtAbsoluteToleranceIsCompatible() {
        // Short programs: tolerance floor is 2.0 s. Diff of exactly 2.0
        // sits ON the boundary — compatible (<=, not <).
        #expect(CorrelationScorer.durationCompatible(videoDuration: 100.0, audioDuration: 98.0))
        #expect(CorrelationScorer.durationCompatible(videoDuration: 98.0, audioDuration: 100.0))
    }

    @Test func justOverAbsoluteToleranceIsIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 100.0, audioDuration: 97.8))
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 97.8, audioDuration: 100.0))
    }

    @Test func percentBranchGovernsLongPrograms() {
        // 3600 s program: tolerance is max(2.0, 72.0) = 72.0 s.
        #expect(CorrelationScorer.durationCompatible(videoDuration: 3600.0, audioDuration: 3529.0))
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 3600.0, audioDuration: 3527.0))
    }

    @Test func unknownVideoDurationIsIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 0, audioDuration: 60.0))
    }

    @Test func unknownAudioDurationIsIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 60.0, audioDuration: 0))
    }

    @Test func bothUnknownIsIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 0, audioDuration: 0))
    }

    @Test func negativeAndNonFiniteAreIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: -5, audioDuration: 60))
        #expect(!CorrelationScorer.durationCompatible(videoDuration: .nan, audioDuration: 60))
        #expect(!CorrelationScorer.durationCompatible(videoDuration: .infinity, audioDuration: 60))
    }

    /// The exact GH #125 incident durations.
    @Test func issue125_incidentDurationsAreIncompatible() {
        #expect(!CorrelationScorer.durationCompatible(videoDuration: 3808.27,
                                                      audioDuration: 125.6255))
    }
}

// MARK: - 1b. Pair-formation exclusion (regression sensors)

@MainActor
@Suite("Duration gate — pair formation")
struct DurationGatePairFormationTests {

    private func makeAV(
        filename: String,
        streamType: StreamType,
        dir: String = "/Volumes/LaCie/Avid MediaFiles/MXF/1",
        duration: Double = 0,
        dateCreated: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.directory = dir
        r.fullPath = dir + "/" + filename
        r.streamTypeRaw = streamType.rawValue
        r.durationSeconds = duration
        r.dateCreatedRaw = dateCreated
        return r
    }

    /// SENSOR (GH #125): the incident pair — hour-long video, 2-minute
    /// unrelated audio, same directory, close timestamps. Pre-fix,
    /// directory(1) + timestamp(3) = 4 cleared the score≥3 floor and
    /// the pair was offered at medium confidence. The gate must keep it
    /// out of the legacy correlate engine entirely.
    @Test func issue125_correlatorNeverOffersHourVideoWithTwoMinuteAudio() {
        let t0 = Date(timeIntervalSince1970: 1_720_000_000)
        let video = makeAV(filename: "Untitled Sequence.04D1C4907.mxf",
                           streamType: .videoOnly,
                           duration: 3808.27, dateCreated: t0)
        let audio = makeAV(filename: "00047.PHYSA01.1_4D14D1C5284.mxf",
                           streamType: .audioOnly,
                           duration: 125.6255, dateCreated: t0.addingTimeInterval(2))

        Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith == nil,
                "GH #125: a 3808 s video must never be offered a 125 s audio")
        #expect(audio.pairedWith == nil)
        #expect(video.pairConfidence == nil && audio.pairConfidence == nil)
    }

    /// SENSOR (GH #125): same incident shape through the PRODUCTION
    /// snap pipeline (assignPairs — what Correlate All actually runs).
    @Test func issue125_assignPairsNeverOffersTheIncidentPair() async {
        let t0 = Date(timeIntervalSince1970: 1_720_000_000)
        let v = CorrelationScorer.Snap(
            id: UUID(), filename: "Untitled Sequence.04D1C4907.mxf",
            directory: "/Volumes/LaCie/Avid MediaFiles/MXF/1",
            durationSeconds: 3808.27, dateCreatedRaw: t0,
            timecode: "", tapeName: "")
        let a = CorrelationScorer.Snap(
            id: UUID(), filename: "00047.PHYSA01.1_4D14D1C5284.mxf",
            directory: "/Volumes/LaCie/Avid MediaFiles/MXF/1",
            durationSeconds: 125.6255, dateCreatedRaw: t0.addingTimeInterval(2),
            timecode: "", tapeName: "")

        let assignments = await CorrelationScorer.assignPairs(
            videos: [v], audios: [a],
            durationTolerance: 1.0, timestampTolerance: 5.0)

        #expect(assignments.isEmpty,
                "GH #125: Correlate All's snap pipeline must not offer the incident pair")
    }

    /// SENSOR (GH #125): same shape through findBestPair — the
    /// user-facing Find Matching Audio / Find A/V Pair verbs.
    @Test func issue125_findBestPairNeverOffersTheIncidentPair() {
        let t0 = Date(timeIntervalSince1970: 1_720_000_000)
        let video = makeAV(filename: "Untitled Sequence.04D1C4907.mxf",
                           streamType: .videoOnly,
                           duration: 3808.27, dateCreated: t0)
        let audio = makeAV(filename: "00047.PHYSA01.1_4D14D1C5284.mxf",
                           streamType: .audioOnly,
                           duration: 125.6255, dateCreated: t0.addingTimeInterval(2))

        let result = CorrelationScorer.findBestPair(
            for: video, in: [video, audio],
            durationTolerance: 1.0, timestampTolerance: 5.0)

        #expect(result == nil,
                "GH #125: Find Matching Audio must not surface a duration-incompatible pair")
    }

    /// Unknown durations are not auto-offered as a confident match on
    /// the fuzzy paths — even with a perfect Avid filename-key match.
    /// (The clip-ID path in correlateAcrossVolumes still recovers such
    /// pairs; see the Avid tests below.)
    @Test func unknownDurationsAreNotAutoOfferedByFuzzyCorrelator() {
        let video = makeAV(filename: "V01AB23.mxf", streamType: .videoOnly, duration: 0)
        let audio = makeAV(filename: "A01AB23.mxf", streamType: .audioOnly, duration: 0)

        Correlator.correlate(records: [video, audio])
        #expect(video.pairedWith == nil,
                "Unknown durations: do nothing rather than conflate")

        let best = CorrelationScorer.findBestPair(
            for: video, in: [video, audio],
            durationTolerance: 1.0, timestampTolerance: 5.0)
        #expect(best == nil)
    }

    /// The gate is a FILTER, not a rescore: a compatible pair keeps its
    /// exact pre-gate score, confidence, and reasons.
    @Test func compatiblePairBehaviorIsUnchanged() {
        let video = makeAV(filename: "V01AB23.mxf", streamType: .videoOnly, duration: 30.0)
        let audio = makeAV(filename: "A01AB23.mxf", streamType: .audioOnly, duration: 30.2)

        Correlator.correlate(records: [video, audio])

        #expect(video.pairedWith === audio)
        #expect(audio.pairedWith === video)
        // filename 4 + duration 3 + directory 1 = 8 → high, exactly as pre-gate.
        #expect(video.pairConfidence == .high)
    }

    /// A long program inside the 2% window still pairs on the weaker
    /// signals — the gate must be looser than the 1.0 s duration-score
    /// tolerance, mirroring CombineVerifier's coverage tolerance.
    @Test func longProgramInsidePercentWindowStillPairs() async {
        let t0 = Date(timeIntervalSince1970: 1_720_000_000)
        // 3600 vs 3590: diff 10 s <= 72 s window → gate passes; no
        // duration score point (diff > 1.0 s) — timestamp 3 + directory 1
        // = 4 pairs at medium, same as before the gate existed.
        let v = CorrelationScorer.Snap(
            id: UUID(), filename: "ceremony_master.mxf",
            directory: "/Volumes/LaCie/captures",
            durationSeconds: 3600.0, dateCreatedRaw: t0,
            timecode: "", tapeName: "")
        let a = CorrelationScorer.Snap(
            id: UUID(), filename: "ceremony_audio.wav",
            directory: "/Volumes/LaCie/captures",
            durationSeconds: 3590.0, dateCreatedRaw: t0.addingTimeInterval(1),
            timecode: "", tapeName: "")

        let assignments = await CorrelationScorer.assignPairs(
            videos: [v], audios: [a],
            durationTolerance: 1.0, timestampTolerance: 5.0)

        #expect(assignments.count == 1,
                "Near-match long programs must keep pairing — the gate is not a rescore")
        #expect(assignments.first?.confidence == .medium)
    }

    // MARK: Avid clip-ID path (deliberate unknown-duration exception)

    /// The clip-ID correlator keeps pairing when durations are unknown:
    /// clip-ID identity is structural, and ffprobe routinely fails to
    /// report duration for Avid RGBA video essence. Pinning this so the
    /// gate never silently guts the Avid rescue pipeline.
    @Test func avidClipIDPathStillPairsUnknownDurations() async {
        func snap(_ name: String) -> CorrelationScorer.AvidSnap {
            CorrelationScorer.AvidSnap(
                id: UUID(), filename: name, fullPath: "/volA/" + name,
                isPlayable: "Yes", sizeBytes: 1000, isPaired: false,
                durationSeconds: 0)   // ffprobe failed — unknown
        }
        let result = await CorrelationScorer.assignAvidPairs(
            [snap("00001.V14D1BBD3F.mxf"), snap("00001.A14D1BBD3F.mxf")])
        #expect(result.assignments.count == 1,
                "Unknown durations must not block clip-ID (structural identity) pairing")
    }

    /// …but when BOTH durations are known and grossly mismatched, even
    /// a clip-ID match is refused: the essences cannot be the same
    /// program (truncated or corrupt file) — do nothing rather than
    /// conflate. GH #125 rule applied to the clip-ID path.
    @Test func avidClipIDPathRefusesKnownIncompatibleDurations() async {
        func snap(_ name: String, duration: Double) -> CorrelationScorer.AvidSnap {
            CorrelationScorer.AvidSnap(
                id: UUID(), filename: name, fullPath: "/volA/" + name,
                isPlayable: "Yes", sizeBytes: 1000, isPaired: false,
                durationSeconds: duration)
        }
        let result = await CorrelationScorer.assignAvidPairs(
            [snap("00001.V14D1BBD3F.mxf", duration: 3808.27),
             snap("00001.A14D1BBD3F.mxf", duration: 125.6255)])
        #expect(result.assignments.isEmpty,
                "Known-incompatible durations must not pair even on clip-ID identity")
    }
}

// MARK: - 2. Scale: 100k records through the gated production pipeline
//
// Correlation iterates `records`, so per the feature-test checklist the
// gated path gets a 100k synthetic run with an explicit wall-clock
// budget. Shape mirrors the real catalog: bounded per-directory pools
// (10 A + 10 V per directory) so the indexed lookups stay hot and the
// thin-pool O(N) fallback never fires — the same shape
// CorrelateLedgerPerfTests uses. Worst-case memory: 100k Snap values +
// index dictionaries, low tens of MB — no media I/O.

@Suite(.serialized) struct DurationGateScaleTests {

    @Test func gatedAssignPairsAt100kRecordsWithinBudget() async {
        let t0 = Date(timeIntervalSince1970: 1_720_000_000)
        var videos: [CorrelationScorer.Snap] = []
        var audios: [CorrelationScorer.Snap] = []
        videos.reserveCapacity(50_000)
        audios.reserveCapacity(50_000)
        var incompatibleAudioIDs = Set<UUID>()

        for i in 0..<50_000 {
            let dir = "/vol/pool\(i / 10)"          // 10 pairs per directory
            let clipID = String(format: "%08X", i)
            let vDur = 100.0 + Double(i % 40)
            videos.append(CorrelationScorer.Snap(
                id: UUID(), filename: "00001.V\(clipID).mxf",
                directory: dir, durationSeconds: vDur,
                dateCreatedRaw: t0.addingTimeInterval(Double(i)),
                timecode: "", tapeName: ""))
            // Even pairs: compatible partner (+0.2 s). Odd pairs: the
            // GH #125 shape — an unrelated audio ~500 s off.
            let aDur = i.isMultiple(of: 2) ? vDur + 0.2 : vDur + 500.0
            let aID = UUID()
            if !i.isMultiple(of: 2) { incompatibleAudioIDs.insert(aID) }
            audios.append(CorrelationScorer.Snap(
                id: aID, filename: "00001.A\(clipID).mxf",
                directory: dir, durationSeconds: aDur,
                dateCreatedRaw: t0.addingTimeInterval(Double(i)),
                timecode: "", tapeName: ""))
        }

        let clock = ContinuousClock()
        var assignments: [CorrelationScorer.PairAssignment] = []
        let elapsed = await clock.measure {
            assignments = await CorrelationScorer.assignPairs(
                videos: videos, audios: audios,
                durationTolerance: 1.0, timestampTolerance: 5.0)
        }

        // Pooled scoring is ~11 candidates per video → ~550k gate+score
        // calls; single-digit seconds even on the M1. Budget 10 s.
        #expect(elapsed < .seconds(10),
                "gated assignPairs took \(elapsed) at 100k records — the O(records) shape has regressed")
        #expect(assignments.count == 25_000,
                "exactly the 25k compatible pairs must match (got \(assignments.count))")
        #expect(assignments.allSatisfy { !incompatibleAudioIDs.contains($0.audioID) },
                "no duration-incompatible audio may appear in any assignment (GH #125)")
    }
}
