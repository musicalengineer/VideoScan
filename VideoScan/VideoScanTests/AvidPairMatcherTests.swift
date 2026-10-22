// AvidPairMatcherTests.swift
// The Avid MXF pair-matcher fix (Rick 2026-10-22: "find matching pair fails
// to find the correct sequence… broken"). Avid renders (`Boston.*`) are
// video-only by design and have NO audio partner, yet bulk Correlate,
// Find A/V Pair and the stored-pair reload had joined them to Logic
// "Upright Jazz Bass" samples and other unrelated audio. The rule
// (AvidPairEvidence), for an MXF video:
//   • a render never pairs;
//   • its partner must be an MXF;
//   • pair only on an equal UMID or an equal material package name;
//   • with neither ID on both sides, no NEW pair (no duration / filename
//     fallback) — but a STORED pair is kept: only positive evidence
//     (render, non-MXF partner, two different names) releases one.
// Non-MXF files keep today's scoring.
//
// Dimensions (CLAUDE.md feature-test checklist): logic (this suite), scale
// and sensor (100k, below), isolation (the poisoned stored links, below).
// The media matrix lives in AvidPairMatcherMediaMatrixTests.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Fixtures (synthetic metadata only — no personal media)

enum AvidPairFixture {
    static let avidDir = "/Volumes/test_Avid/Avid MediaFiles/MXF/1"
    static let samplesDir = "/Volumes/test_Archive/Logic Projects/Samples/Upright Jazz Bass"

    static func record(_ filename: String, _ stream: StreamType, duration: Double,
                       directory: String = avidDir, umid: String = "", name: String = "",
                       render: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.filename = filename
        r.ext = (filename as NSString).pathExtension.lowercased()
        r.directory = directory
        r.fullPath = directory + "/" + filename
        r.streamTypeRaw = stream.rawValue
        r.durationSeconds = duration
        r.container = r.ext == "mxf" ? "MXF (Material eXchange Format)" : ""
        r.materialPackageUMID = umid
        r.materialPackageName = name
        r.isAvidRender = render
        return r
    }

    static func link(_ a: VideoRecord, _ b: VideoRecord, confidence: PairConfidence = .medium) {
        let gid = UUID()
        a.pairedWith = b; a.pairGroupID = gid; a.pairConfidence = confidence
        b.pairedWith = a; b.pairGroupID = gid; b.pairConfidence = confidence
    }

    /// The real consolidate case (clip 00002 on Rick's drives): A1/A2 share
    /// a UMID, the V was re-minted later and has its own; all say "00002".
    static func consolidatedClip() -> (video: VideoRecord, a1: VideoRecord) {
        let v = record("00002.V14D1BBD84.mxf", .videoOnly, duration: 12.012,
                       umid: "0x060A2B34TEST4D1BBD84", name: "00002")
        let a = record("00002.A14B9428E6.mxf", .audioOnly, duration: 12.012,
                       umid: "0x060A2B34TEST4B9428E6", name: "00002")
        return (v, a)
    }

    /// An Avid render — `Boston.Sequence updated.03,Title,13`.
    static func bostonRender(duration: Double = 2.291667) -> VideoRecord {
        record("Boston.Sequence upd4C6B6468.mxf", .videoOnly, duration: duration,
               umid: "0x060A2B34TEST4C6B6468", name: "Boston.Sequence updated.03,Title,13", render: true)
    }

    static func best(_ r: VideoRecord, in all: [VideoRecord]) -> CorrelationScorer.Candidate? {
        CorrelationScorer.findBestPair(for: r, in: all, durationTolerance: 1.0, timestampTolerance: 5.0)
    }

    @MainActor
    static func bulk(_ all: [VideoRecord]) async -> [CorrelationScorer.PairAssignment] {
        let videos = all.filter { $0.streamType == .videoOnly }.map(CorrelationScorer.snap)
        let audios = all.filter { $0.streamType == .audioOnly }.map(CorrelationScorer.snap)
        return await CorrelationScorer.assignPairs(videos: videos, audios: audios,
                                                   durationTolerance: 1.0, timestampTolerance: 5.0)
    }
}

// MARK: - Logic

@Suite("Avid pair matcher — logic") @MainActor
struct AvidPairMatcherLogicTests {
    typealias F = AvidPairFixture

    @Test func sameNamePairs() async throws {
        let v = F.record("00010.V14D1BC063.mxf", .videoOnly, duration: 8.0, name: "00010")
        let a = F.record("00010.A14D1BC0C4.mxf", .audioOnly, duration: 8.0, name: "00010")
        #expect(F.best(v, in: [v, a])?.audio === a)
        #expect(F.best(a, in: [v, a])?.video === v)
        let bulk = await F.bulk([v, a])
        #expect(bulk.count == 1 && bulk.first?.videoID == v.id && bulk.first?.audioID == a.id)
    }

    @Test func sameUMIDPairs() async throws {
        let v = F.record("00011.V14B942D67.mxf", .videoOnly, duration: 9.5, umid: "0x060A2B34TESTSHARED")
        let a = F.record("00011.A14B942D67.mxf", .audioOnly, duration: 9.5, umid: "0x060A2B34TESTSHARED")
        #expect(F.best(v, in: [v, a])?.audio === a)
        #expect(await F.bulk([v, a]).count == 1)
    }

    @Test func consolidatedVideoWithDifferentUMIDButSameNamePairs() async throws {
        let (v, a) = F.consolidatedClip()
        #expect(v.materialPackageUMID != a.materialPackageUMID)
        #expect(F.best(v, in: [v, a])?.audio === a)
        #expect(await F.bulk([v, a]).count == 1)
        #expect(CorrelationScorer.persistedPairIsValid(v, a))
    }

    /// Avid appends `.new.NN` on each consolidate; V and A of one clip may
    /// carry different counters ("00045.new.03" / "00045.new.02" — 178 such
    /// stored pairs on Rick's catalog). Same clip, not a contradiction.
    @Test func consolidateCounterSuffixIsTheSameClip() async throws {
        let v = F.record("00045.PHYSV01.EB_4D4D1D79CD.mxf", .videoOnly, duration: 6.0, name: "00045.new.03")
        let a = F.record("00045.PHYSA02.86_4D4D1D78B7.mxf", .audioOnly, duration: 6.0, name: "00045.new.02")
        #expect(F.best(v, in: [v, a])?.audio === a)
        F.link(v, a)
        #expect(CorrelationScorer.persistedPairIsValid(v, a))
        #expect(CorrelationScorer.revalidateExistingPairs(in: [v, a]) == 0)
    }

    @Test func aRenderNeverPairs() async throws {
        let render = F.bostonRender()
        // Even an audio carrying the render's own name and duration.
        let a = F.record("Boston.SequencA14C6B6468.mxf", .audioOnly, duration: 2.291667,
                         umid: render.materialPackageUMID, name: render.materialPackageName)
        #expect(F.best(render, in: [render, a]) == nil)
        #expect(F.best(a, in: [render, a]) == nil)
        #expect(await F.bulk([render, a]).isEmpty)
        #expect(!CorrelationScorer.persistedPairIsValid(render, a))
    }

    @Test func mxfVideoWithWavOrAifPartnerIsRefused() async throws {
        let (v, _) = F.consolidatedClip()
        for name in ["00002.wav", "00002.aif", "00002.aiff"] {
            let a = F.record(name, .audioOnly, duration: v.durationSeconds, directory: v.directory, name: "00002")
            #expect(F.best(v, in: [v, a]) == nil, "\(name)")
            #expect(F.best(a, in: [v, a]) == nil, "\(name)")
            #expect(await F.bulk([v, a]).isEmpty, "\(name)")
            #expect(!CorrelationScorer.persistedPairIsValid(v, a), "\(name)")
        }
    }

    /// The Boston.115 shape: a 0.17 s render-era video and a 0.32 s Logic
    /// sample with no extension, in another folder. Duration alone scored 3
    /// and the thin pool searched every audio in the catalog.
    @Test func tinyMXFVideoAgainstTinyNonMXFAudioIsRefused() async throws {
        let v = F.record("Boston.115.Doug.Tra442C5353.mxf", .videoOnly, duration: 0.17)
        let a = F.record("KONTBSTR1X32", .audioOnly, duration: 0.32, directory: F.samplesDir)
        #expect(F.best(v, in: [v, a]) == nil)
        #expect(await F.bulk([v, a]).isEmpty)
        F.link(v, a)
        #expect(!CorrelationScorer.persistedPairIsValid(v, a))
        #expect(CorrelationScorer.revalidateExistingPairs(in: [v, a]) == 2)
        #expect(v.pairedWith == nil && a.pairedWith == nil)
    }

    @Test func missingIDsMakeNoNewPairButKeepAStoredOne() async throws {
        let v = F.record("00001.V14D1BBD3F.mxf", .videoOnly, duration: 30.0)
        let a = F.record("00001.A14D1BBD3F.mxf", .audioOnly, duration: 30.0)
        #expect(F.best(v, in: [v, a]) == nil)
        #expect(await F.bulk([v, a]).isEmpty)
        F.link(v, a)
        #expect(CorrelationScorer.persistedPairIsValid(v, a))
        #expect(CorrelationScorer.revalidateExistingPairs(in: [v, a]) == 0)
        #expect(v.pairedWith === a)
        // One side known, the other not: still unproven — kept.
        v.materialPackageName = "00001"
        #expect(CorrelationScorer.revalidateExistingPairs(in: [v, a]) == 0)
    }

    @Test func twoDifferentNamesReleaseAStoredPair() {
        let v = F.record("00005.PHYSV01.91_4D4D228565.mxf", .videoOnly, duration: 4.0, name: "00005.new.05")
        let a = F.record("00041.A24D1BD29D.mxf", .audioOnly, duration: 4.0, name: "00041")
        F.link(v, a)
        #expect(!CorrelationScorer.persistedPairIsValid(v, a))
        #expect(CorrelationScorer.revalidateExistingPairs(in: [v, a]) == 2)
        #expect(v.pairGroupID == nil && a.pairConfidence == nil)
    }

    @Test func preferredPairIgnoresAStoredRenderLink() {
        let render = F.bostonRender()
        let sample = F.record("KONTBFINWX03", .audioOnly, duration: 0.5, directory: F.samplesDir)
        F.link(render, sample)
        #expect(CorrelationScorer.preferredPair(for: render, in: [render, sample],
                                                durationTolerance: 1.0, timestampTolerance: 5.0) == nil)
    }

    @Test func legacyCorrelatorHonoursTheRule() {
        let render = F.bostonRender()
        let a = F.record("00032.A24CE00E83.mxf", .audioOnly, duration: 2.002)
        let wav = F.record("hihat01 R.wav", .audioOnly, duration: 2.2)
        _ = Correlator.correlate(records: [render, a, wav])
        #expect(render.pairedWith == nil)
    }

    /// Non-MXF files keep today's scoring, byte for byte.
    @Test func nonMXFFilesAreUnaffected() async throws {
        for (vName, aName) in [("test_clip.mov", "test_clip.wav"), ("test_clip.mp4", "test_clip.m4a"),
                               ("test_clip.mkv", "test_clip.aif"), ("test_clip.dv", "test_clip.wav")] {
            let v = F.record(vName, .videoOnly, duration: 10.0, directory: "/Volumes/test_Home/clips")
            let a = F.record(aName, .audioOnly, duration: 10.0, directory: "/Volumes/test_Home/clips")
            #expect(F.best(v, in: [v, a])?.audio === a, "\(vName)")
            #expect(await F.bulk([v, a]).count == 1, "\(vName)")
            #expect(CorrelationScorer.persistedPairIsValid(v, a), "\(vName)")
        }
    }
}

// MARK: - Scale + sensor (100k)

@Suite("Avid pair matcher — scale and sensor", .serialized) @MainActor
struct AvidPairMatcherScaleTests {
    typealias F = AvidPairFixture

    /// 100k records: 5k sub-2 s MXF video orphans (half renders, half with
    /// no Avid IDs), 20k short non-MXF audio files (Logic samples, Berklee
    /// loops), 75k ordinary video+audio rows. Bulk Correlate must make ZERO
    /// pairs among them, within a time budget.
    static func catalog() -> (all: [VideoRecord], videos: [VideoRecord], audios: [VideoRecord]) {
        var all: [VideoRecord]
        var videos: [VideoRecord] = []
        var audios: [VideoRecord] = []
        for i in 0..<5_000 {
            let duration = 0.04 + Double(i % 46) * 0.04       // 0.04 … 1.84 s
            let v: VideoRecord
            if i.isMultiple(of: 2) {
                v = F.record(String(format: "Boston.Sequence%08X.mxf", i), .videoOnly, duration: duration,
                             name: "Boston.Sequence updated.\(i % 9),Title,\(i % 40)", render: true)
            } else {
                v = F.record(String(format: "Boston.115.Doug.Tra%08X.mxf", i), .videoOnly, duration: duration)
            }
            videos.append(v)
        }
        for i in 0..<20_000 {
            let duration = 0.05 + Double(i % 60) * 0.03       // 0.05 … 1.82 s
            let name = i.isMultiple(of: 3) ? String(format: "KONTBSTR%05d", i) : String(format: "hihat%05d.wav", i)
            audios.append(F.record(name, .audioOnly, duration: duration, directory: F.samplesDir + "/\(i % 50)"))
        }
        all = videos + audios
        for i in 0..<75_000 {
            all.append(F.record(String(format: "test_family_%06d.mov", i), .videoAndAudio, duration: 60,
                                directory: "/Volumes/test_Home/Movies/\(i % 200)"))
        }
        return (all, videos, audios)
    }

    /// The sensor's own reading of "same clip": the name with Avid's
    /// consolidate counters (`.new.NN`, repeated) removed. Written here, not
    /// borrowed from production, so the sensor cannot drift with the code.
    static func clipName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        while let r = n.range(of: #"\.new\.\d+$"#, options: .regularExpression) { n.removeSubrange(r) }
        return n
    }

    @Test func bulkCorrelateMakesNoBadPairsAt100k() async throws {
        let (all, videos, audios) = Self.catalog()
        #expect(all.count == 100_000)
        let vs = videos.map(CorrelationScorer.snap)
        let aSnaps = audios.map(CorrelationScorer.snap)
        let clock = ContinuousClock()
        let started = clock.now
        let assignments = await CorrelationScorer.assignPairs(videos: vs, audios: aSnaps,
                                                             durationTolerance: 1.0, timestampTolerance: 5.0)
        let elapsed = started.duration(to: clock.now)
        #expect(assignments.isEmpty, "\(assignments.count) bad pairs, e.g. \(assignments.first.map { "\($0.videoFilename) ↔ \($0.audioFilename)" } ?? "")")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(5)), "assignPairs at 100k took \(elapsed)")
    }

    /// SENSOR: no stored pair joins a render, an MXF video to non-MXF audio,
    /// or two different non-empty names — after revalidation, at 100k, and
    /// the genuine pairs (same UMID / same name / non-MXF / unproven) stay.
    @Test func sensorNoBadStoredPairSurvivesRevalidationAt100k() throws {
        let (base, videos, audios) = Self.catalog()
        var all = base
        // Poison: every video orphan linked to an audio sample.
        for (i, v) in videos.enumerated() { F.link(v, audios[i]) }
        // Two different names, 1k of them.
        var genuine: [(VideoRecord, VideoRecord)] = []
        for i in 0..<1_000 {
            let v = F.record("\(10_000 + i).V1TEST.mxf", .videoOnly, duration: 5, name: "clip\(i)")
            let a = F.record("\(20_000 + i).A1TEST.mxf", .audioOnly, duration: 5, name: "other\(i)")
            F.link(v, a)
            all += [v, a]
        }
        // Genuine, 4k: same UMID, same name (consolidate), non-MXF, unproven.
        for i in 0..<1_000 {
            let pairs: [(VideoRecord, VideoRecord)] = [
                (F.record("\(i).V1U.mxf", .videoOnly, duration: 5, umid: "U\(i)"),
                 F.record("\(i).A1U.mxf", .audioOnly, duration: 5, umid: "U\(i)")),
                (F.record("\(i).V1N.mxf", .videoOnly, duration: 5, umid: "VU\(i)", name: "n\(i).new.05"),
                 F.record("\(i).A1N.mxf", .audioOnly, duration: 5, umid: "AU\(i)", name: "n\(i).new.04")),
                (F.record("test_\(i).mov", .videoOnly, duration: 5, directory: "/Volumes/test_Home"),
                 F.record("test_\(i).wav", .audioOnly, duration: 5, directory: "/Volumes/test_Home")),
                (F.record("\(i).V1X.mxf", .videoOnly, duration: 5),
                 F.record("\(i).A1X.mxf", .audioOnly, duration: 5)),
            ]
            for (v, a) in pairs { F.link(v, a); all += [v, a]; genuine.append((v, a)) }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let cleared = CorrelationScorer.revalidateExistingPairs(in: all)
        let elapsed = started.duration(to: clock.now)
        #expect(cleared == 2 * (5_000 + 1_000))
        var bad = 0
        for r in all where r.streamType == .videoOnly {
            guard let p = r.pairedWith else { continue }
            let isMXF = r.filename.lowercased().hasSuffix(".mxf")
            let pMXF = p.filename.lowercased().hasSuffix(".mxf")
            let namesDiffer = !r.materialPackageName.isEmpty && !p.materialPackageName.isEmpty
                && Self.clipName(r.materialPackageName) != Self.clipName(p.materialPackageName)
            if r.isAvidRender || p.isAvidRender || (isMXF && !pMXF) || namesDiffer { bad += 1 }
        }
        #expect(bad == 0)
        #expect(genuine.allSatisfy { $0.0.pairedWith === $0.1 && $0.1.pairedWith === $0.0 })
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(3)), "revalidation at 100k took \(elapsed)")
    }
}
