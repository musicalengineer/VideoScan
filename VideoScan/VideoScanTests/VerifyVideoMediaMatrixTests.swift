// VerifyVideoMediaMatrixTests.swift
// MEDIA MATRIX dimension (feature-test checklist item 3) for Verify Video:
// the checklist containers run through a FULL VerifyVideoProbe.diagnose
// (real ffprobe header + packet samples + real full decode):
//
//   mp4 / h264 + aac      mov / prores + pcm     mkv / ffv1 + pcm
//   mxf / mpeg2 + pcm     avi / dv + pcm
//
// each must read OK. Then synthetic BROKEN ones:
//   - duplicate-frame bloat (a 25 fps picture stored at 3,000 fps — the
//     Dicky class in miniature) → Broken, full decode skipped
//   - a truncated mp4 (half the bytes, index gone) → Broken, can't open
//   - a corrupt-bytes MPEG-TS (random bytes over its middle) → decode
//     errors, not OK
//   - picture 6 s vs sound 2 s → Warning
//   - a decode budget far too small → "partially checked", never a failure
//   - an audio-only file → no verdict (noVideoStream)
// Fixtures are tiny (2–20 s, `test_` prefix, per-test temp dirs removed
// in a defer). Nothing outside the temp dir is read or written.

import Testing
import Foundation
@testable import VideoScan

enum VerifyVideoTestMedia {

    static var toolsAvailable: Bool { CleanupTestMedia.toolsAvailable }

    static func makeScratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_verifyvideo_\(label)_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// testsrc picture + (optional) stereo tone, per-case codec control.
    @discardableResult
    static func generate(into dir: URL, name: String,
                         videoCodec: String, extraVideoArgs: [String] = [],
                         audioCodec: String? = "pcm_s16le",
                         size: String = "320x240", rate: String = "25",
                         videoDuration: Double = 2.0, audioDuration: Double? = nil,
                         outputArgs: [String] = []) throws -> String {
        let out = dir.appendingPathComponent(name).path
        var args = ["-f", "lavfi",
                    "-i", "testsrc=duration=\(videoDuration):size=\(size):rate=\(rate)"]
        if let audioCodec {
            args += ["-f", "lavfi",
                     "-i", "aevalsrc=0.5*sin(440*2*PI*t)|0.5*sin(987*2*PI*t):s=48000:d=\(audioDuration ?? videoDuration)",
                     "-map", "0:v:0", "-map", "1:a:0",
                     "-c:v", videoCodec] + extraVideoArgs + ["-c:a", audioCodec]
        } else {
            args += ["-c:v", videoCodec] + extraVideoArgs + ["-an"]
        }
        try CleanupTestMedia.runFFmpeg(args + outputArgs, output: out)
        return out
    }
}

@Suite("VerifyVideo — media matrix", .serialized)
struct VerifyVideoMediaMatrixTests {

    private func expectOK(name: String, videoCodec: String, extraVideoArgs: [String] = [],
                          audioCodec: String = "pcm_s16le", size: String = "320x240",
                          rate: String = "25", container: String) async throws {
        let dir = try VerifyVideoTestMedia.makeScratchDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: name, videoCodec: videoCodec, extraVideoArgs: extraVideoArgs,
            audioCodec: audioCodec, size: size, rate: rate)
        let d = try await VerifyVideoProbe.diagnose(path: path)
        #expect(d.verdict == .ok, "\(name): expected OK, got \(d.findings)")
        #expect(d.persistedStatus == "ok")
        #expect(d.persistedNote == "", "\(name): \(d.persistedNote)")
        #expect(d.decode?.coverage == .complete, "\(name): full decode must run to the end")
        #expect(d.decode?.errorCount == 0)
        #expect(d.facts.hasVideo && d.facts.width > 0)
        #expect(d.facts.containerFormat.contains(container), "\(name): \(d.facts.containerFormat)")
        #expect((d.sample?.packets ?? 0) > 0, "\(name): the packet sample must run")
    }

    @Test("mp4/h264+aac reads OK", .timeLimit(.minutes(2)))
    func mp4() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectOK(name: "test_vv_matrix.mp4", videoCodec: "libx264",
                           extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac",
                           container: "mp4")
    }

    @Test("mov/prores+pcm reads OK", .timeLimit(.minutes(2)))
    func mov() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectOK(name: "test_vv_matrix.mov", videoCodec: "prores", container: "mov")
    }

    @Test("mkv/ffv1+pcm reads OK", .timeLimit(.minutes(2)))
    func mkv() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectOK(name: "test_vv_matrix.mkv", videoCodec: "ffv1", container: "matroska")
    }

    @Test("mxf/mpeg2+pcm reads OK", .timeLimit(.minutes(2)))
    func mxf() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectOK(name: "test_vv_matrix.mxf", videoCodec: "mpeg2video",
                           extraVideoArgs: ["-g", "15"], size: "720x576", container: "mxf")
    }

    @Test("avi/dv+pcm reads OK", .timeLimit(.minutes(2)))
    func avi() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        try await expectOK(name: "test_vv_matrix.avi", videoCodec: "dvvideo",
                           extraVideoArgs: ["-pix_fmt", "yuv411p"],
                           size: "720x480", rate: "30000/1001", container: "avi")
    }

    // MARK: Broken on real media

    @Test("duplicate-frame bloat reads Broken and skips the decode", .timeLimit(.minutes(2)))
    func bloat() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("bloat")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 2 s of 25 fps picture written at 3,000 fps: every real frame is
        // stored 120×, the dup copies are near-empty P-frames.
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_bloat.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: nil,
            size: "160x120", outputArgs: ["-r", "3000"])
        let d = try await VerifyVideoProbe.diagnose(path: path)
        #expect(d.verdict == .broken, "\(d.findings)")
        guard case .duplicateFrameBloat(let factor, _, _, _, let empty)? = d.findings.first else {
            Issue.record("bloat must lead: \(d.findings)"); return
        }
        #expect(factor > 50, "3,000 stored fps vs ~30 real: \(factor)")
        #expect(empty, "x264 stores the duplicates as near-empty frames")
        #expect(d.persistedNote.hasPrefix("Broken video — each frame stored ~"))
        guard case .skipped? = d.decode?.coverage else {
            Issue.record("a proven-broken file must not be decoded end to end: \(String(describing: d.decode))")
            return
        }
    }

    @Test("a truncated mp4 reads Broken — can't be opened", .timeLimit(.minutes(2)))
    func truncated() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("trunc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_whole.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac", videoDuration: 4)
        let data = try Data(contentsOf: URL(fileURLWithPath: whole))
        let cut = dir.appendingPathComponent("test_vv_truncated.mp4")
        try data.prefix(data.count / 2).write(to: cut)
        let d = try await VerifyVideoProbe.diagnose(path: cut.path)
        #expect(d.verdict == .broken)
        guard case .unopenable(let detail)? = d.findings.first else {
            Issue.record("expected unopenable, got \(d.findings)"); return
        }
        #expect(detail.contains("index is missing"), "\(detail)")
        #expect(d.recommendation.hasPrefix("This file can't be played."))
    }

    @Test("corrupt bytes surface as decode errors", .timeLimit(.minutes(2)))
    func corrupt() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_corrupt.ts", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: nil, videoDuration: 4,
            outputArgs: ["-f", "mpegts"])
        // Deterministic damage: 300 pseudo-random bytes every 2,000 across
        // the middle 60% (container headers at the ends stay readable).
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var seed: UInt32 = 42
        var off = bytes.count / 5
        while off < bytes.count * 4 / 5 {
            for i in 0..<300 where off + i < bytes.count {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[off + i] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            off += 2_000
        }
        try Data(bytes).write(to: URL(fileURLWithPath: path))

        let d = try await VerifyVideoProbe.diagnose(path: path)
        #expect(d.verdict != .ok, "\(d.findings)")
        #expect((d.decode?.errorCount ?? 0) > 0)
        #expect(!(d.decode?.sampleErrors.isEmpty ?? true))
        #expect(d.decode?.sampleErrors.allSatisfy { !$0.contains("@ 0x") } ?? false,
                "addresses stripped from the sample lines")
    }

    @Test("picture much longer than sound reads Warning", .timeLimit(.minutes(2)))
    func shortAudio() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("short")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_shortaudio.mov", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], videoDuration: 6, audioDuration: 2)
        let d = try await VerifyVideoProbe.diagnose(path: path)
        #expect(d.verdict == .warning, "\(d.findings)")
        #expect(d.findings.contains { if case .videoVsAudioDuration = $0 { return true }; return false })
        #expect(d.persistedNote.hasPrefix("Video warning — "))
    }

    @Test("a decode budget hit is 'partially checked', not a failure", .timeLimit(.minutes(2)))
    func budget() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_long.mkv", videoCodec: "ffv1", audioCodec: nil,
            size: "1280x720", videoDuration: 20)
        // 10 ms: shorter than ffmpeg's own process start-up, so the budget
        // always fires first (a 20 s 720p ffv1 decodes in < 0.2 s on an M4).
        let d = try await VerifyVideoProbe.diagnose(path: path, decodeBudgetOverride: 0.01)
        guard case .partial(let checked)? = d.decode?.coverage else {
            Issue.record("expected partial coverage, got \(String(describing: d.decode))"); return
        }
        #expect(checked < 20)
        #expect(d.verdict == .ok, "partial is honest, not a problem: \(d.findings)")
        #expect(d.persistedNote.hasPrefix("partially checked"))
        #expect(d.recommendation.contains("again"))
    }

    @Test("progress reaches the caller during the decode", .timeLimit(.minutes(2)))
    func progress() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("progress")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_progress.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: nil, videoDuration: 8)
        let box = ProgressBox()
        _ = try await VerifyVideoProbe.diagnose(path: path, progress: { box.note($0) })
        #expect(box.maximum > 0.9, "last reported fraction \(box.maximum)")
    }

    @Test("an audio-only file gives no verdict", .timeLimit(.minutes(2)))
    func audioOnly() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("audio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_vv_audio.m4a").path
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "sine=d=2", "-c:a", "aac"], output: out)
        await #expect(throws: VideoVerifyProbeError.noVideoStream) {
            _ = try await VerifyVideoProbe.diagnose(path: out)
        }
    }

    @Test("a missing file is a probe failure, never a Broken verdict", .timeLimit(.minutes(1)))
    func missing() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ghost = dir.appendingPathComponent("test_vv_gone.mp4").path
        do {
            _ = try await VerifyVideoProbe.diagnose(path: ghost)
            Issue.record("a vanished file must not produce a verdict")
        } catch VideoVerifyProbeError.probeFailed {
            // expected
        }
    }
}

/// Sendable progress collector for the progress test.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var maxValue: Double = 0
    func note(_ f: Double) { lock.lock(); maxValue = max(maxValue, f); lock.unlock() }
    var maximum: Double { lock.lock(); defer { lock.unlock() }; return maxValue }
}
