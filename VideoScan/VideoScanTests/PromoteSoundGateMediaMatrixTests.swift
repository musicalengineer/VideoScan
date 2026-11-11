// PromoteSoundGateMediaMatrixTests.swift
// MEDIA dimension for the Promote sound gate (Rick 2026-11-10). Real
// synthetic media (ffmpeg testsrc / aevalsrc, `test_*` names, temp dirs —
// never a real path) through the REAL scan probe, the REAL measurement
// (`PromoteSoundGate.Measure.live`: ffprobe + the levels pass) and the REAL
// Promote job against a sandbox archive.
//
// Five containers × five sound shapes:
//
//                       stereo   left only   silent track   −68 dBFS both   no track
//   mp4 / h264 + aac    promote  promote+L   REFUSED        REFUSED         REFUSED
//   mov / prores + pcm  promote  promote+L   REFUSED        REFUSED         REFUSED
//   mkv / ffv1 + pcm    promote  promote+L   REFUSED        REFUSED         REFUSED
//   mxf / mpeg2 + pcm   promote  promote+L   REFUSED        REFUSED         REFUSED
//   avi / dv + pcm      promote  promote+L   REFUSED        REFUSED         REFUSED
//
// The −68 dBFS column is the real archived title's shape (two channels, both
// peaking far under the −60 line): the header says "2 channels", the
// measurement says silent.
//
// RED before the gate was wired (2026-11-10): every REFUSED cell promoted.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Promote sound gate — media matrix (real decode)", .serialized)
@MainActor
struct PromoteSoundGateMediaMatrixTests {

    typealias S = MasterArchiveTestSupport

    struct Container {
        let ext: String
        let videoCodec: String
        var extraVideoArgs: [String] = []
        let audioCodec: String
        var size = "320x240"
        var rate = "25"
    }

    enum Shape: String, CaseIterable {
        case stereo, leftOnly, silent, quiet68, noTrack

        /// aevalsrc expression; nil = no audio stream at all.
        var expr: String? {
            switch self {
            case .stereo: return VerifyAudioTestMedia.trueStereoExpr
            case .leftOnly: return "0.5*sin(440*2*PI*t)|0"
            case .silent: return VerifyAudioTestMedia.silentExpr
            // A sine's RMS is A/√2: A = 0.000563 → about −68 dBFS RMS on both channels.
            case .quiet68: return "0.000563*sin(440*2*PI*t)|0.000563*sin(987*2*PI*t)"
            case .noTrack: return nil
            }
        }
    }

    /// Generate the five shapes in `c`, catalog them with the real probe,
    /// promote them in ONE job with the live measurement, and check each.
    private func run(_ c: Container) async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let sb = try S.makeSandbox("sg_matrix_\(c.ext)"); defer { sb.cleanup() }
        let model = S.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try S.initialize(model, in: sb)

        var records: [Shape: VideoRecord] = [:]
        for shape in Shape.allCases {
            let path = try VerifyAudioTestMedia.generate(
                into: sb.sources, name: "test_sg_\(shape.rawValue).\(c.ext)",
                videoCodec: c.videoCodec, extraVideoArgs: c.extraVideoArgs,
                audioCodec: shape.expr == nil ? nil : c.audioCodec,
                audioExpr: shape.expr ?? VerifyAudioTestMedia.silentExpr, size: c.size, rate: c.rate)
            let rec = await model.probeFile(url: URL(fileURLWithPath: path), skipHashing: true)
            model.records.append(rec)
            records[shape] = rec
        }
        // The header cannot tell the first four apart: every one says "video + audio".
        for shape in [Shape.stereo, .leftOnly, .silent, .quiet68] {
            #expect(records[shape]?.streamTypeRaw == StreamType.videoAndAudio.rawValue, "\(c.ext) \(shape): \(records[shape]?.streamTypeRaw ?? "")")
        }

        let before = S.archivedFiles(sb)
        let job = try #require(await S.promote(model, ids: Shape.allCases.compactMap { records[$0]?.id }, measure: .live))
        await job.completionTask?.value
        func outcome(_ shape: Shape) throws -> PromoteToArchiveJob.FileOutcome {
            let id = try #require(records[shape]?.id)
            return try #require(job.outcomes.first { $0.recordID == id }, "\(c.ext) \(shape): no outcome")
        }

        let stereo = try outcome(.stereo)
        #expect(stereo.kind == .promoted && stereo.soundNote == nil, "\(c.ext) stereo: \(stereo.kind) — \(stereo.detail)")
        let left = try outcome(.leftOnly)
        #expect(left.kind == .promoted, "\(c.ext) left only: \(left.kind) — \(left.detail)")
        #expect(left.soundNote == "sound on the left side only", "\(c.ext) left only: \(left.soundNote ?? "nil")")

        let silent = try outcome(.silent)
        #expect(silent.kind == .failed && silent.refusalCode == "sound-silent", "\(c.ext) silent: \(silent.refusalCode ?? "nil") — \(silent.detail)")
        let quiet = try outcome(.quiet68)
        #expect(quiet.kind == .failed && quiet.refusalCode == "sound-silent", "\(c.ext) −68 dBFS: \(quiet.refusalCode ?? "nil") — \(quiet.detail)")
        #expect(quiet.detail.contains("every channel is under -60.0 dBFS"), "\(quiet.detail)")
        let none = try outcome(.noTrack)
        #expect(none.kind == .failed && none.refusalCode == "sound-none", "\(c.ext) no track: \(none.refusalCode ?? "nil") — \(none.detail)")

        // Exactly the two sound-bearing files are in the archive; the three refused are not.
        #expect(before.isEmpty && S.archivedFiles(sb).count == 2, "\(c.ext): \(S.archivedFiles(sb))")
        #expect(S.manifestRows(sb).count == 2)
        for shape in [Shape.silent, .quiet68, .noTrack] {
            #expect(model.masterArchiveCopy(of: try #require(records[shape])) == nil, "\(c.ext) \(shape) must not be archived")
        }
        // The gate stores nothing: no verdict was written for any of the five.
        for shape in Shape.allCases {
            #expect(records[shape]?.audioVerifyStatus == "" && records[shape]?.audioVerifyDate == nil, "\(c.ext) \(shape)")
        }
        // TRUTH: the measured line in the log names the side the fixture put the tone on.
        await PromoteSoundGateJobTests.consoleSettled()
        #expect(model.dashboard.consoleLines.contains { $0.contains("SOUND OUTCOME") && $0.contains("present, left only") })
    }

    @Test("mp4 / h264 + aac", .timeLimit(.minutes(5)))
    func mp4() async throws {
        try await run(Container(ext: "mp4", videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac"))
    }

    @Test("mov / prores + pcm", .timeLimit(.minutes(5)))
    func mov() async throws {
        try await run(Container(ext: "mov", videoCodec: "prores", audioCodec: "pcm_s16le"))
    }

    @Test("mkv / ffv1 + pcm", .timeLimit(.minutes(5)))
    func mkv() async throws {
        try await run(Container(ext: "mkv", videoCodec: "ffv1", audioCodec: "pcm_s16le"))
    }

    @Test("mxf / mpeg2 + pcm", .timeLimit(.minutes(5)))
    func mxf() async throws {
        try await run(Container(ext: "mxf", videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15"], audioCodec: "pcm_s16le",
                                size: "720x576"))
    }

    @Test("avi / dv + pcm", .timeLimit(.minutes(5)))
    func avi() async throws {
        try await run(Container(ext: "avi", videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p"], audioCodec: "pcm_s16le",
                                size: "720x480", rate: "30000/1001"))
    }

    @Test("REFUSED — Codex #280 F1: ffmpeg missing (ffprobe present) is 'tool unavailable', never a 'damaged' verdict on a healthy file",
          .timeLimit(.minutes(5)))
    func missingFfmpegIsNotDamage() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let sb = try S.makeSandbox("sg_noffmpeg"); defer { sb.cleanup() }
        let model = S.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try S.initialize(model, in: sb)
        let path = try VerifyAudioTestMedia.generate(into: sb.sources, name: "test_sg_healthy.mov", videoCodec: "prores",
                                                     audioCodec: "pcm_s16le")
        // The probe itself: the levels step reports the tool missing while the file is still probeable.
        await #expect(throws: AudioVerifyProbeError.self) {
            _ = try await VerifyAudioProbe.diagnose(path: path,
                                                    analyzeOverride: { _ in throw AudioBalanceProbeError.toolUnavailable("ffmpeg not found") },
                                                    sourceRecheckOverride: { _ in true })
        }
        // Through the job: could not check, nothing stored, nothing archived.
        let rec = await model.probeFile(url: URL(fileURLWithPath: path), skipHashing: true)
        model.records.append(rec)
        let noFfmpeg = PromoteSoundGate.Measure { p in
            try await VerifyAudioProbe.diagnose(path: p,
                                                analyzeOverride: { _ in throw AudioBalanceProbeError.toolUnavailable("ffmpeg not found") },
                                                sourceRecheckOverride: { _ in true })
        }
        let job = try #require(await S.promote(model, ids: [rec.id], measure: noFfmpeg))
        let o = try #require(job.outcomes.first)
        #expect(o.kind == .failed && o.refusalCode == "sound-unchecked", "\(o.kind) \(o.refusalCode ?? "nil") — \(o.detail)")
        #expect(rec.audioVerifyStatus.isEmpty && rec.audioVerifyDate == nil, "no verdict — least of all 'damaged': \(rec.audioVerifyStatus) \(rec.audioVerifyNote)")
        #expect(S.archivedFiles(sb).isEmpty)
    }

    @Test("TRUTH: the −68 dBFS refusal carries the number the levels pass measured (mov / pcm)", .timeLimit(.minutes(5)))
    func theNumberIsTheMeasurement() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("sg_truth"); defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: "test_sg_truth.mov", videoCodec: "prores",
                                                     audioCodec: "pcm_s16le", audioExpr: try #require(Shape.quiet68.expr))
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let channels = try #require(d.balanceAnalysis?.measurements.channels)
        let loudest = try #require(channels.map(\.rmsDBFS).max())
        #expect(loudest < -62 && loudest > -75, "the fixture measures about −68 dBFS: \(loudest)")
        #expect(d.shape.audioChannels == 2, "the header says two channels")
        guard case .silent(_, let reported) = PromoteSoundGate.finding(from: d) else {
            Issue.record("measured silent expected: \(PromoteSoundGate.finding(from: d))"); return
        }
        #expect(reported == loudest)
        guard case .refuse(_, let detail, _) = PromoteSoundGate.decide(finding: PromoteSoundGate.finding(from: d),
                                                                       mark: .absent, soundPartnerName: nil, recordedYear: nil,
                                                                       digestPrefix: "") else {
            Issue.record("refusal expected"); return
        }
        #expect(detail.contains("(loudest \(PromoteSoundGate.db(loudest)))"), "\(detail)")
    }
}
