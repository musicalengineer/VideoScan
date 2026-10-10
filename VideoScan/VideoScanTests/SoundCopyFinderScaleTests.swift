// SoundCopyFinderScaleTests.swift
// SCALE (CLAUDE.md feature-test checklist, 2): "A copy with sound is here"
// over a 100k-record catalog. The lookup is one main-actor pass (three
// compares per record) plus an off-main decision — it must stay well
// inside the sheet's "opens in under a second" promise, and it must never
// run for a file the policy did not flag.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Sound copy finder — scale sensor (100k records)")
@MainActor
struct SoundCopyFinderScaleTests {

    @Test func oneLookupOver100kRecordsStaysUnderBudget() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("soundcopy_scale")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let footGroup = UUID()
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.directory = "/Volumes/test_Scale\(i % 7)/dir\(i % 100)"
            r.filename = "test_clip\(i).mov"
            r.fullPath = r.directory + "/" + r.filename
            r.sizeBytes = 1_000_000
            r.durationSeconds = Double(60 + i % 600)
            r.streamTypeRaw = i % 3 == 0 ? StreamType.audioOnly.rawValue : StreamType.videoAndAudio.rawValue
            if i % 2_000 == 1 {                                                   // 50 same-footage, with sound
                r.streamTypeRaw = StreamType.videoAndAudio.rawValue
                r.footage = FootageMembership(groupID: footGroup, groupSize: 51, confidence: .likely, role: .reEncode,
                                              rank: i / 2_000 + 1, likelyOriginalID: footGroup, originalInCatalog: true,
                                              evidence: ["same name + length"], scannedAt: Date(), algorithmVersion: 2)
            }
            rows.append(r)
        }
        let target = rows[0]
        target.filename = "test_Thanksgiving2009-DVD.m2v"
        target.streamTypeRaw = StreamType.videoOnly.rawValue
        target.durationSeconds = 0
        target.footage = FootageMembership(groupID: footGroup, groupSize: 51, confidence: .likely, role: .original,
                                           rank: 0, likelyOriginalID: target.id, originalInCatalog: true,
                                           evidence: [], scannedAt: Date(), algorithmVersion: 2)
        m.records = rows
        #expect(target.catalogSoundPresence.isWarning)

        let clock = ContinuousClock()
        var input: SoundCopyInput?
        let mainPart = clock.measure { input = SoundCopyFinder.gather(for: target, model: m) }
        var advice: SoundCopyAdvice?
        let whole = await clock.measure { advice = await SoundCopyFinder.load(recordID: target.id, model: m) }

        let i = try #require(input)
        #expect(i.copiesWithSound.count == 50, "every same-footage member with sound, nothing else")
        // dir0 of test_Scale0 holds i ≡ 0 (mod 700); audio-only among them is
        // i ≡ 0 (mod 2100): 2100 … 98700 → 47 files.
        #expect(i.soundFiles.count == 47, "the audio-only files in the m2v's own folder")
        #expect(i.soundFiles.allSatisfy { $0.sameFolder && !$0.sameFootage })
        // No test_Scale drive is connected: the best copy is named, to connect.
        guard case .connect(let c)? = advice else { Issue.record("\(String(describing: advice))"); return }
        #expect(c.relation == "same footage")
        #expect(mainPart < PerformanceLane.loadAwareDebugCeiling(.milliseconds(400)),
                "gather took \(mainPart) (\(PerformanceLane.loadDescription()))")
        #expect(whole < PerformanceLane.loadAwareDebugCeiling(.milliseconds(1_000)),
                "the whole lookup took \(whole) (\(PerformanceLane.loadDescription()))")
    }

    /// The real catalog's shape (Rick 2026-10-10): the m2v (length 0 in the
    /// catalog), its .ac3 beside it, an Avid audio MXF of the same length in
    /// ANOTHER folder, and a near-miss .wav beside it. Only the .ac3 is a
    /// candidate — once a full Verify has measured the picture.
    @Test func theM2vFindsItsAc3AndNothingElse() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("soundpair_m2v")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        func rec(_ dir: String, _ name: String, _ type: StreamType, _ seconds: Double) -> VideoRecord {
            let r = VideoRecord()
            r.directory = dir
            r.filename = name
            r.fullPath = dir + "/" + name
            r.streamTypeRaw = type.rawValue
            r.durationSeconds = seconds
            r.sizeBytes = 1_000
            return r
        }
        let folder = "/Volumes/test_SanDisk/Cheesegrater_ExternalRaid"
        let m2v = rec(folder, "Thanksgiving2009-DVD.m2v", .videoOnly, 0)
        let ac3 = rec(folder, "Thanksgiving2009-Blu-ray.ac3", .audioOnly, 5422.432)
        let nearMiss = rec(folder, "Thanksgiving2009-rough-mix.wav", .audioOnly, 5300)
        let elsewhere = rec("/Volumes/test_SanDisk/From_MyBook/MXF/1", "Thanksgiving2009-Pr4B189A9E.mxf", .audioOnly, 5422.4)
        m.records = [m2v, ac3, nearMiss, elsewhere]

        // Before a full Verify measured it: only "may be", by name start.
        let unmeasured = SoundCopyFinder.pairCandidates(for: m2v, model: m)
        #expect(unmeasured.map(\.audio.filename) == ["Thanksgiving2009-Blu-ray.ac3", "Thanksgiving2009-rough-mix.wav"])
        #expect(unmeasured.allSatisfy { !$0.lengthMatches }, "no length → never a Combine offer")

        // After a full Verify: the card carries the measured length.
        m2v.mediaReportCard = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1_000, headline: "",
                                              checks: [], measuredPictureSeconds: 5422.4)
        let measured = SoundCopyFinder.pairCandidates(for: m2v, model: m)
        #expect(measured.map(\.audio.filename) == ["Thanksgiving2009-Blu-ray.ac3"],
                "the near miss (5,300 s) and the MXF in another folder are not candidates")
        #expect(measured.first?.reason == "same folder, same name start, same length 1:30:22 (0.03 s apart)")
        #expect(SoundCopyFinder.decide(SoundCopyFinder.gather(for: m2v, model: m), isConnected: { _ in true })
                == .combine(try #require(measured.first)))
        #expect(m2v.pairedWith == nil && ac3.pairedWith == nil, "listing never pairs")

        // A card for a different file size no longer describes the file.
        m2v.sizeBytes = 2_000
        #expect(SoundCopyFinder.pairCandidates(for: m2v, model: m).allSatisfy { !$0.lengthMatches })
    }

    /// A file with sound (the overwhelming majority) costs NO pass at all.
    @Test func aFileWithSoundSkipsThePass() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("soundcopy_skip")
        defer { sb.cleanup() }
        let m = MasterArchiveTestSupport.makeModel(sb)
        let rows = (0..<100_000).map { i -> VideoRecord in
            let r = VideoRecord()
            r.filename = "test_ok\(i).mp4"
            r.fullPath = "/Volumes/test_Skip/\(r.filename)"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
        m.records = rows
        let clock = ContinuousClock()
        var advice: SoundCopyAdvice?
        let took = await clock.measure { advice = await SoundCopyFinder.load(recordID: rows[0].id, model: m) }
        #expect(advice == SoundCopyAdvice.none)
        #expect(took < PerformanceLane.loadAwareDebugCeiling(.milliseconds(50)), "took \(took)")
    }
}
