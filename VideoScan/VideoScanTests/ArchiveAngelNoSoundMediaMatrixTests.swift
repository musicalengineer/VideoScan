// ArchiveAngelNoSoundMediaMatrixTests.swift
// MEDIA dimension (CLAUDE.md feature-test checklist, 3) for the 10/6 bug:
// the Archive Angel recommended a video-only file with no extension. Real
// synthetic media (ffmpeg testsrc / aevalsrc, `test_*` names, temp dirs —
// never a real path) goes through the REAL scan probe (`probeFile`, on a
// sandboxed model) and, for the sound-track cases, the REAL Verify Audio
// diagnosis, then the sweep's projection and the built-in floors:
//
//   video-only   mp4/h264 · mov/prores · mkv/ffv1 · mxf/mpeg2 · avi/dv  → noSound
//   video-only, extensionless copy of the .mov                       → noSound
//   A/V, silent track, verified                                      → noSound
//   A/V, audio much shorter than video (damaged), verified           → noSound
//   A/V, healthy stereo, verified                                    → passes noSound
//   A/V, never verified                                              → passes (Prepare checks it)
//
// The fixtures are 2 s, so the built-in `tooShort` floor would also fire;
// `noSound` sits before it in policy order, and each row also asks the
// `noSound` floor ALONE (floorFires) so a reorder cannot hide a regression.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — no-sound media matrix", .serialized)
@MainActor
struct ArchiveAngelNoSoundMediaMatrixTests {

    // MARK: Helpers

    /// Probe `path` with the real scan probe on a sandboxed model.
    private func probe(_ path: String) async throws -> VideoRecord {
        let sb = try MasterArchiveTestSupport.makeSandbox("nosound_probe")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        return await model.probeFile(url: URL(fileURLWithPath: path), skipHashing: true)
    }

    /// Run the real Verify Audio diagnosis and persist it the way
    /// VerifyAudioJob.persistVerdict does.
    private func verify(_ r: VideoRecord) async throws {
        let d = try await VerifyAudioProbe.diagnose(path: r.fullPath)
        r.audioVerifyStatus = d.persistedStatus
        r.audioVerifyNote = d.persistedNote
        r.audioVerifyDate = Date()
    }

    private func candidate(_ r: VideoRecord) -> ArchiveAngelCandidate {
        ArchiveAngelNoSoundTests.candidate(r)
    }

    /// The `noSound` floor alone, and the first floor in policy order.
    private func floors(_ r: VideoRecord) -> (alone: ArchiveAngelRejection?, first: ArchiveAngelRejection?) {
        let c = candidate(r)
        let p = AngelRecommendationPolicy.builtIn
        let alone = AngelRuleKind(rawValue: "noSound").flatMap { ArchiveAngelScorer.floorFires($0, c, policy: p, now: Date()) }
        return (alone, ArchiveAngelScorer.hardFloor(c, policy: p))
    }

    private func expectNoSound(_ r: VideoRecord, _ label: String) throws {
        let expected = try ArchiveAngelNoSoundTests.noSound()
        let f = floors(r)
        #expect(f.alone == expected, "\(label): the noSound floor must fire")
        #expect(f.first == expected, "\(label): noSound must be the reason a person hears, got \(String(describing: f.first))")
    }

    private func videoOnly(_ name: String, codec: String, extra: [String] = [],
                           size: String = "320x240", rate: String = "25") async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("nosound")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: name, videoCodec: codec, extraVideoArgs: extra,
                                                     audioCodec: nil, size: size, rate: rate)
        let r = try await probe(path)
        #expect(r.streamTypeRaw == StreamType.videoOnly.rawValue, "\(name): probed as \(r.streamTypeRaw)")
        try expectNoSound(r, name)
    }

    // MARK: Video-only across the checklist containers

    @Test("mp4/h264 video-only → noSound", .timeLimit(.minutes(2)))
    func mp4() async throws {
        try await videoOnly("test_nosound.mp4", codec: "libx264", extra: ["-preset", "ultrafast"])
    }

    @Test("mov/prores video-only → noSound", .timeLimit(.minutes(2)))
    func mov() async throws { try await videoOnly("test_nosound.mov", codec: "prores") }

    @Test("mkv/ffv1 video-only → noSound", .timeLimit(.minutes(2)))
    func mkv() async throws { try await videoOnly("test_nosound.mkv", codec: "ffv1") }

    @Test("mxf/mpeg2 video-only → noSound", .timeLimit(.minutes(2)))
    func mxf() async throws {
        try await videoOnly("test_nosound.mxf", codec: "mpeg2video", extra: ["-g", "15"], size: "720x576")
    }

    @Test("avi/dv video-only → noSound", .timeLimit(.minutes(2)))
    func avi() async throws {
        try await videoOnly("test_nosound.avi", codec: "dvvideo", extra: ["-pix_fmt", "yuv411p"],
                            size: "720x480", rate: "30000/1001")
    }

    @Test("extensionless copy of a DV-in-MOV video-only export → noSound (the 10/6 file's shape)",
          .timeLimit(.minutes(2)))
    func extensionless() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("nosound_noext")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = try VerifyAudioTestMedia.generate(into: dir, name: "test_untitled-video-only.mov",
                                                    videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p"],
                                                    audioCodec: nil, size: "720x480", rate: "30000/1001")
        let bare = dir.appendingPathComponent("test_untitled-video-only")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: mov), to: bare)
        let r = try await probe(bare.path)
        #expect(r.ext.isEmpty)
        #expect(r.streamTypeRaw == StreamType.videoOnly.rawValue, "probed as \(r.streamTypeRaw)")
        #expect(r.videoCodec == "dvvideo")
        try expectNoSound(r, "extensionless")
    }

    // MARK: A sound track that is silent, damaged, healthy or unchecked

    private func avFixture(_ label: String, expr: String = VerifyAudioTestMedia.trueStereoExpr,
                           videoDuration: Double = 2.0, audioDuration: Double? = nil) async throws -> (URL, VideoRecord) {
        let dir = try VerifyAudioTestMedia.makeScratchDir("nosound_\(label)")
        let path = try VerifyAudioTestMedia.generate(into: dir, name: "test_nosound_\(label).mov",
                                                     videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
                                                     audioCodec: "pcm_s16le", audioExpr: expr,
                                                     videoDuration: videoDuration, audioDuration: audioDuration)
        let r = try await probe(path)
        #expect(r.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        return (dir, r)
    }

    @Test("A/V with a SILENT track, verified → noSound", .timeLimit(.minutes(2)))
    func silent() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let (dir, r) = try await avFixture("silent", expr: VerifyAudioTestMedia.silentExpr)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await verify(r)
        #expect(r.audioVerifyStatus == "ok" && r.audioVerifyNote == "silent audio")
        try expectNoSound(r, "silent")
    }

    @Test("A/V with DAMAGED audio (much shorter than the picture), verified → noSound", .timeLimit(.minutes(2)))
    func damaged() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let (dir, r) = try await avFixture("damaged", videoDuration: 10.0, audioDuration: 2.0)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await verify(r)
        #expect(r.audioVerifyStatus == "damaged")
        try expectNoSound(r, "damaged")
    }

    @Test("A/V healthy (verified) and never-verified → the noSound floor does not fire", .timeLimit(.minutes(2)))
    func healthyAndUnchecked() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let (dir, r) = try await avFixture("healthy")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(floors(r).alone == nil, "never verified: a candidate, Prepare checks it")
        try await verify(r)
        #expect(r.audioVerifyStatus == "ok" && r.audioVerifyNote.isEmpty)
        #expect(floors(r).alone == nil, "healthy verified sound")
    }
}
