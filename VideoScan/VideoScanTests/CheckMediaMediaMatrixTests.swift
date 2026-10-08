// CheckMediaMediaMatrixTests.swift
// MEDIA MATRIX + SENSOR for Check Media (Rick 2026-10-07): real ffmpeg on
// synthetic `test_*` fixtures in a temp dir (never family media).
//
//   * The CLAUDE.md matrix — mp4/h264, mov/prores, mkv/ffv1+pcm, mxf,
//     avi/dv — are healthy controls: every quick check must say OK.
//   * The CapeCod-class pathology, reproduced: 2 s of 25 fps picture
//     written at 3,000 fps, so each real frame is stored ~120× as
//     near-empty packets with 1/3000 s timestamps. The quick tier must
//     call it a Problem on frame rate, timing and repeats, inside a time
//     budget (the "within seconds" promise) — the regression SENSOR.
//   * One full check end to end on the mp4 (decode + signals + sound).

import Testing
import Foundation
@testable import VideoScan

@Suite("Check Media — media matrix", .serialized)
struct CheckMediaMediaMatrixTests {

    private func quickCard(_ path: String) async throws -> (CheckMediaQuickInputs, [MediaCheck]) {
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else {
            throw CheckMediaSkip(reason: "unopenable")
        }
        return (q, CheckMediaRules.quickChecks(q))
    }

    private func expectHealthy(name: String, videoCodec: String, extraVideoArgs: [String] = [],
                               audioCodec: String = "pcm_s16le", size: String = "320x240",
                               rate: String = "25", outputArgs: [String] = []) async throws {
        let dir = try VerifyVideoTestMedia.makeScratchDir("checkmedia")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: name, videoCodec: videoCodec, extraVideoArgs: extraVideoArgs,
            audioCodec: audioCodec, size: size, rate: rate, outputArgs: outputArgs)
        let (q, checks) = try await quickCard(path)
        #expect(q.facts.video != nil && q.facts.audio != nil, "\(name): both streams probed")
        #expect((q.packets?.packets ?? 0) > 0, "\(name): the packet sample ran")
        #expect(!(q.distinct?.usable.isEmpty ?? true), "\(name): a frame window decoded")
        #expect(!(q.layout?.windows.isEmpty ?? true), "\(name): the layout window measured both streams")
        #expect(checks.first { $0.kind == .layout }?.verdict == .ok, "\(name): no false layout problem")
        for c in checks {
            if case .notRun = c.verdict { continue }   // e.g. no sample count in this container
            #expect(c.verdict == .ok, "\(name) \(c.kind): \(c.sentence)")
        }
        #expect(!checks.contains { $0.verdict == .problem || $0.verdict == .warning })
    }

    @Test("mp4/h264+aac is healthy", .timeLimit(.minutes(2)))
    func mp4() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectHealthy(name: "test_cm_matrix.mp4", videoCodec: "libx264",
                                extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
    }

    @Test("mov/prores+pcm is healthy", .timeLimit(.minutes(2)))
    func mov() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectHealthy(name: "test_cm_matrix.mov", videoCodec: "prores")
    }

    @Test("mkv/ffv1+pcm is healthy", .timeLimit(.minutes(2)))
    func mkv() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectHealthy(name: "test_cm_matrix.mkv", videoCodec: "ffv1")
    }

    @Test("mxf/mpeg2+pcm is healthy", .timeLimit(.minutes(2)))
    func mxf() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        // A real SD master says 4:3; without it the square-pixel SD rule
        // (rightly) warns.
        try await expectHealthy(name: "test_cm_matrix.mxf", videoCodec: "mpeg2video",
                                extraVideoArgs: ["-g", "15", "-aspect", "4:3"], size: "720x576")
    }

    @Test("avi/dv+pcm is healthy", .timeLimit(.minutes(2)))
    func avi() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectHealthy(name: "test_cm_matrix.avi", videoCodec: "dvvideo",
                                extraVideoArgs: ["-pix_fmt", "yuv411p", "-aspect", "4:3"],
                                size: "720x480", rate: "30000/1001")
    }

    /// SENSOR: the CapeCod class, reproduced synthetically, is a Problem in
    /// seconds — frame rate, timing and repeats all say so, and the
    /// headline is the plain sentence.
    @Test("duplicate-frame pathology is a Problem within seconds", .timeLimit(.minutes(2)))
    func capeCodClassFixture() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("cmbloat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_cm_bloat.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac",
            size: "160x120", outputArgs: ["-r", "3000"])
        let clock = ContinuousClock()
        var result: (CheckMediaQuickInputs, [MediaCheck])?
        let elapsed = try await clock.measure { result = try await quickCard(path) }
        let (q, checks) = try #require(result)
        let v = Dictionary(uniqueKeysWithValues: checks.map { ($0.kind, $0.verdict) })
        #expect(v[.frameRate] == .problem, "\(checks.map(\.sentence))")
        #expect(v[.timestamps] == .problem)
        #expect(v[.distinctFrames] == .problem)
        #expect(v[.bitrate] == .problem)
        let card = CheckMediaRules.card(tier: .quick, checks: checks, quick: q, at: Date())
        #expect(card.headline.hasPrefix("Plays, but its timing is broken: ~3,000 fps — each real frame is stored ~"),
                "\(card.headline)")
        #expect(CheckMediaRules.conclusiveVideoDiagnosis(q)?.verdict == .broken,
                "the quick tier settles the picture verdict — no 46 GB decode")
        #expect(elapsed < .seconds(20), "quick tier took \(elapsed)")
    }

    @Test("a full check decodes, measures sound and reads OK", .timeLimit(.minutes(3)))
    func fullCheckOnHealthyMp4() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("cmfull")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_cm_full.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac", videoDuration: 4)
        let (q, _) = try await quickCard(path)
        let full = try await CheckMediaProbe.full(path: path, facts: q.facts)
        let checks = CheckMediaRules.fullChecks(full, facts: q.facts)
        let v = Dictionary(uniqueKeysWithValues: checks.map { ($0.kind, $0.verdict) })
        #expect(v[.decode] == .ok, "\(checks.map(\.sentence))")
        #expect(v[.sound] == .ok)
        #expect(v[.black] == .ok && v[.freeze] == .ok)
        #expect(full.signals != nil, "the signal filters rode the decode")
        #expect(checks.first { $0.kind == .sound }?.evidence.count == 2, "loudness per channel")
        #expect(v[.soundContinuity] == .ok, "\(checks.first { $0.kind == .soundContinuity }?.sentence ?? "")")
        let card = CheckMediaRules.card(tier: .full, checks: CheckMediaRules.quickChecks(q) + checks, quick: q, at: Date())
        #expect(card.headline == CheckMediaRules.fullPassHeadline, "only a full pass may say healthy: \(card.headline)")
    }

    /// SENSOR (the Brockton class): all the picture stored, then all the
    /// sound. A fragmented mov written as ONE fragment puts every picture
    /// sample before every sound sample; 8 s of uncompressed 640×480
    /// (≈ 147 MB) puts the sound ≈ 80–150 MB from its picture, past the
    /// 64 MB threshold (5 s ≈ 92 MB was only 47 MB median — a Warning). The quick tier must say
    /// Problem, in seconds, and the headline must name the stutter.
    @Test("sound stored after all the picture is a Layout Problem", .timeLimit(.minutes(2)))
    func nonInterleavedFixture() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("cmlayout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_cm_notinterleaved.mov", videoCodec: "rawvideo",
            extraVideoArgs: ["-pix_fmt", "uyvy422"], size: "640x480", rate: "30", videoDuration: 8,
            outputArgs: ["-movflags", "+empty_moov+frag_custom", "-frag_duration", "60000000"])
        let clock = ContinuousClock()
        var result: (CheckMediaQuickInputs, [MediaCheck])?
        let elapsed = try await clock.measure { result = try await quickCard(path) }
        let (q, checks) = try #require(result)
        let layout = try #require(checks.first { $0.kind == .layout })
        #expect(layout.verdict == .problem, "\(layout.sentence) \(layout.evidence)")
        #expect(layout.sentence.hasPrefix("All the sound is stored after all the picture"), "\(layout.sentence)")
        #expect(layout.fix == CheckMediaRules.layoutFix)
        let card = CheckMediaRules.card(tier: .quick, checks: checks + CheckMediaRules.fullRowsNotRun(), quick: q, at: Date())
        #expect(card.headline.hasPrefix("Sound may stutter: "), "\(card.headline)")
        #expect(elapsed < .seconds(20), "quick tier took \(elapsed)")
    }
}
