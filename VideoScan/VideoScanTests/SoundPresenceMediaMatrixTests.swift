// SoundPresenceMediaMatrixTests.swift
// MEDIA MATRIX (checklist 3) + SENSOR (checklist 5) for the 2026-10-10 bug:
// Verify and Get Info said Thanksgiving2009-DVD.m2v (an MPEG-2 elementary
// stream, picture only, 2009) was fine.
//
// Real ffmpeg on synthetic `test_*` fixtures in a temp dir (never family
// media), through the REAL header probe (CheckMediaProbe.quick):
//
//   m2v  mpeg2video elementary stream, no sound       → No sound (Warning)
//   mp4  h264 + aac                                   → policy silent (sound pass decides)
//   mp4  h264, no sound                               → No sound (Warning)
//   mov  prores, no sound                             → No sound (Warning)
//   mxf  mpeg2video, no sound                         → No sound (Warning)
//   …and on each picture-only file: pre-1980 → OK "Silent…", a known pair → OK.
//
// SENSOR: the real Verify job (CheckMediaJob, real probe runners, full and
// quick tiers) on the m2v fixture named like the real file never writes an
// OK card or a "healthy" headline, and Get Info's display guard never shows
// one over a stale card. The full tier also measures the picture's length
// (an .m2v header records none) for the Combine offer.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Sound presence — media matrix and Verify sensor", .serialized)
@MainActor
struct SoundPresenceMediaMatrixTests {

    // MARK: Fixtures

    private func make(_ name: String, codec: String, extra: [String] = [], sound: String? = nil,
                      size: String = "320x240", rate: String = "25", output: [String] = []) throws -> (dir: URL, path: String) {
        let dir = try VerifyVideoTestMedia.makeScratchDir("soundpresence")
        let path = try VerifyVideoTestMedia.generate(into: dir, name: name, videoCodec: codec, extraVideoArgs: extra,
                                                     audioCodec: sound, size: size, rate: rate, outputArgs: output)
        return (dir, path)
    }

    private func facts(_ path: String) async throws -> MediaFacts {
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else {
            throw CheckMediaSkip(reason: "unopenable")
        }
        return q.facts
    }

    /// The Sound row the job would write for `facts` under `context`.
    private func soundRow(_ facts: MediaFacts, _ context: SoundPresenceContext) -> MediaCheck? {
        CheckMediaRules.applyingSoundPresence(CheckMediaRules.fullRowsNotRun(), facts: facts, context: context)
            .first { $0.kind == .sound }
    }

    /// A picture-only fixture: Warning when undated or post-1980, OK for
    /// pre-1980 film and for a known pair half.
    private func expectPictureOnly(_ name: String, codec: String, extra: [String] = [],
                                   size: String = "320x240", output: [String] = []) async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let f = try make(name, codec: codec, extra: extra, size: size, output: output)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let probed = try await facts(f.path)
        #expect(probed.video != nil && probed.audio == nil, "\(name): probed as picture only")
        let undated = soundRow(probed, .unknown)
        #expect(undated?.verdict == .warning, "\(name): \(undated?.sentence ?? "no row")")
        #expect(undated.map(CheckMediaRules.isNoSoundRow) == true, "\(name)")
        #expect(soundRow(probed, SoundPresenceContext(recordedYear: 2009, yearSource: .filename))?.verdict == .warning, "\(name)")
        #expect(soundRow(probed, SoundPresenceContext(recordedYear: 1968, yearSource: .userDate))?.verdict == .ok, "\(name)")
        #expect(soundRow(probed, SoundPresenceContext(soundPartnerName: "test_A01.mxf"))?.verdict == .ok, "\(name)")
    }

    // MARK: The matrix

    @Test("m2v / mpeg2 elementary stream, picture only", .timeLimit(.minutes(2)))
    func m2v() async throws {
        try await expectPictureOnly("test_sp.m2v", codec: "mpeg2video", output: ["-f", "mpeg2video"])
    }

    @Test("mp4 / h264, picture only", .timeLimit(.minutes(2)))
    func mp4NoSound() async throws {
        try await expectPictureOnly("test_sp_vo.mp4", codec: "libx264", extra: ["-preset", "ultrafast"])
    }

    @Test("mov / prores, picture only", .timeLimit(.minutes(2)))
    func movProres() async throws {
        try await expectPictureOnly("test_sp.mov", codec: "prores")
    }

    @Test("mxf / mpeg2, picture only (an Avid-style video half)", .timeLimit(.minutes(2)))
    func mxfVideoOnly() async throws {
        try await expectPictureOnly("test_sp.mxf", codec: "mpeg2video", extra: ["-g", "15", "-aspect", "4:3"], size: "720x576")
    }

    @Test("mp4 / h264 + aac: the policy stays out of it", .timeLimit(.minutes(2)))
    func mp4WithSound() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let f = try make("test_sp_av.mp4", codec: "libx264", extra: ["-preset", "ultrafast"], sound: "aac")
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let probed = try await facts(f.path)
        #expect(probed.audio != nil)
        #expect(CheckMediaRules.soundPresenceRow(facts: probed, context: .unknown) == nil)
        let rows = CheckMediaRules.fullRowsNotRun()
        #expect(CheckMediaRules.applyingSoundPresence(rows, facts: probed, context: .unknown) == rows,
                "a file with sound keeps the sound pass's own row")
    }

    // MARK: SENSOR — the real Verify job never calls it fine

    private func verify(_ path: String, filename: String, tier: MediaReportCard.Tier,
                        configure: (VideoRecord) -> Void = { _ in }) async throws -> (VideoRecord, CheckMediaJob) {
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.filename = filename
        rec.fullPath = path
        rec.directory = (path as NSString).deletingLastPathComponent
        rec.streamTypeRaw = StreamType.videoOnly.rawValue
        rec.sizeBytes = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        configure(rec)
        model.records = [rec]
        let job = CheckMediaJob(records: [rec], tier: tier, model: model, center: nil)
        job.start()
        await job.task?.value
        return (rec, job)
    }

    private func expectNeverFine(_ card: MediaReportCard, _ label: String) {
        #expect(card.verdict == .warning, "\(label): \(card.headline)")
        #expect(card.verdictWord != "OK", "\(label)")
        #expect(!card.isQuickPassOnly, "\(label): a no-sound file is not a quick pass")
        for word in ["healthy", "fine", "No problems found"] {
            #expect(!card.displayHeadline.contains(word), "\(label): \(card.displayHeadline)")
        }
        #expect(card.displayHeadline.hasPrefix("No sound — this copy has no audio track"), "\(label): \(card.displayHeadline)")
        #expect(card.check(.sound).map(CheckMediaRules.isNoSoundRow) == true, "\(label)")
    }

    @Test("full Verify of a 2009 .m2v: Warning, never healthy; the length is measured", .timeLimit(.minutes(3)))
    func fullVerifyOfTheM2v() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let f = try make("test_Thanksgiving2009-DVD.m2v", codec: "mpeg2video", rate: "30000/1001", output: ["-f", "mpeg2video"])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (rec, job) = try await verify(f.path, filename: "Thanksgiving2009-DVD.m2v", tier: .full)
        let card = try #require(rec.mediaReportCard)
        #expect(card.tier == .full)
        expectNeverFine(card, "full")
        #expect(card.check(.sound)?.sentence == "No sound — this copy has no audio track. It dates from 2009 (from its name), "
                + "and home video after 1980 normally has sound.")
        // The picture's length, which the .m2v header does not record.
        let measured = try #require(card.measuredPictureSeconds)
        #expect(abs(measured - 2.0) < 0.2, "measured \(measured) s for a 2 s fixture")
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("Warning — No sound — this copy has no audio track"), "\(summary)")
        // Get Info reads the same card through its guard.
        #expect(SoundPresencePolicy.displayHeadline(card: card, presence: rec.catalogSoundPresence)
                .hasPrefix("No sound — this copy has no audio track"))
    }

    @Test("quick Verify of an undated .m2v: Warning, not a quick pass", .timeLimit(.minutes(2)))
    func quickVerifyUndated() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let f = try make("test_reel.m2v", codec: "mpeg2video", output: ["-f", "mpeg2video"])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (rec, _) = try await verify(f.path, filename: "test_reel.m2v", tier: .quick)
        let card = try #require(rec.mediaReportCard)
        expectNeverFine(card, "quick, undated")
        #expect(card.check(.sound)?.evidence.contains(MediaEvidence("Dated", "unknown — treated as after 1980")) == true)
        #expect(card.measuredPictureSeconds == nil, "the quick tier measures no length")
    }

    @Test("full Verify of pre-1980 film without sound: fine, with the silent note", .timeLimit(.minutes(3)))
    func preNineteenEightyIsFine() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let f = try make("test_reel_1968.m2v", codec: "mpeg2video", output: ["-f", "mpeg2video"])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (rec, _) = try await verify(f.path, filename: "test_reel.m2v", tier: .full) { $0.userDate = "1968" }
        let card = try #require(rec.mediaReportCard)
        #expect(card.check(.sound)?.verdict == .ok)
        #expect(card.check(.sound)?.sentence == "Silent (normal for film before 1980). Dated 1968, from your date.")
        // Other rows may warn about the synthetic clip itself (a short
        // testsrc encode can read as "mostly repeats"); the SOUND must not.
        #expect(!card.checks.contains { $0.kind == .sound && $0.verdict.rank >= MediaCheckVerdict.warning.rank })
        #expect(!card.headline.hasPrefix("No sound"), "\(card.headline)")
        #expect(SoundPresencePolicy.displayHeadline(card: card, presence: rec.catalogSoundPresence) == card.displayHeadline,
                "Get Info adds no warning for pre-1980 film")
    }

    /// SENSOR on the Get Info source: the verdict line goes through the
    /// policy's guard, never the raw stored headline.
    @Test func getInfoVerdictLineGoesThroughThePolicy() throws {
        let code = try SourceTree.appCode(named: "MediaInfoSheet.swift")
        #expect(code.contains("SoundPresencePolicy.displayHeadline(card: card, presence: soundPresence)"))
        #expect(code.contains("SoundPresencePolicy.displayVerdict(card: card, presence: soundPresence)"))
        #expect(!code.contains("Text(card.displayHeadline)"), "the raw stored headline can say 'Looks healthy'")
    }

    /// SENSOR: no O(records) work in a view body. The catalog pass lives in
    /// SoundCopyFinder (gather / pairCandidates); Get Info reaches it only
    /// through the presenter's hook, run from `.task`; the Copies & Advice
    /// card only from its `.task` helper.
    @Test func theLookupNeverRunsInAViewBody() throws {
        let info = try SourceTree.appCode(named: "MediaInfoSheet.swift")
        #expect(!info.contains("SoundCopyFinder."), "the sheet stays presentation-only")
        #expect(info.contains("soundAdvice = await hooks.load()"))
        let card = try SourceTree.appCode(named: "CopiesAdviceSheet.swift")
        let uses = card.components(separatedBy: "SoundCopyFinder.").count - 1
        #expect(uses == 1, "one call, in loadSound()")
        let loader = try #require(card.range(of: "private func loadSound() async"))
        let call = try #require(card.range(of: "SoundCopyFinder.load("))
        #expect(call.lowerBound > loader.lowerBound, "the call sits in the async .task helper")
        #expect(card.contains("await loadSound()"))
    }
}
