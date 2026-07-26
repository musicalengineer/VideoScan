// VerifyAudioMediaMatrixTests.swift
// MEDIA MATRIX dimension (feature-test checklist item 3) for Verify
// Audio (GH #128): the checklist containers run through a FULL
// VerifyAudioProbe.diagnose pass (real ffprobe + real astats levels),
// plus one REAL RebuildAudioJob round-trip:
//
//   mp4  / h264 + aac        — lossy family
//   mov  / prores + pcm      — the archival QuickTime family
//   mkv  / ffv1 + pcm        — Rick's archival-master recipe
//   mxf  / mpeg2 + pcm       — the Avid-adjacent container
//   avi  / dv + pcm          — camcorder captures
//
// Healthy fixtures use TRUE-STEREO tone pairs (decorrelated 440/987 Hz,
// the BalanceAudioTestSupport convention) so "All is well" is a real
// verdict, not an accident of mono synthesis. Negative diagnoses (the
// #125 short-audio class, silence, no-audio, surround) are synthesized
// per-case. Fixtures are tiny (2–10 s, `test_` prefix, temp dirs).
//
// The rebuild round-trip pins the repair contract end-to-end: video
// stream COPIED (codec unchanged), audio re-encoded to pcm_s16le,
// output `<stem>_RepairedAudio.mov` beside the source, source bytes
// untouched, provenance stamped machine-classified on BOTH records.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Fixture generation

enum VerifyAudioTestMedia {

    static var toolsAvailable: Bool { CleanupTestMedia.toolsAvailable }

    static func makeScratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_verify_\(label)_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Decorrelated stereo — classifies trueStereo, so a healthy fixture
    /// yields zero findings.
    static let trueStereoExpr = "0.5*sin(440*2*PI*t)|0.5*sin(987*2*PI*t)"
    static let silentExpr = "0|0"
    static let surround51Expr = Array(repeating: "0.5*sin(440*2*PI*t)", count: 6)
        .joined(separator: "|")

    /// One synthetic fixture: testsrc video + aevalsrc audio with full
    /// per-case control (video codec/geometry, audio codec, expression
    /// set, independent audio duration for the #125 mismatch case).
    @discardableResult
    static func generate(into dir: URL,
                         name: String,
                         videoCodec: String,
                         extraVideoArgs: [String] = [],
                         audioCodec: String?,
                         audioExpr: String = trueStereoExpr,
                         size: String = "320x240",
                         rate: String = "25",
                         videoDuration: Double = 2.0,
                         audioDuration: Double? = nil) throws -> String {
        let out = dir.appendingPathComponent(name).path
        var args: [String] = [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(videoDuration):size=\(size):rate=\(rate)",
        ]
        if let audioCodec {
            let d = audioDuration ?? videoDuration
            args += ["-f", "lavfi",
                     "-i", "aevalsrc=\(audioExpr):s=48000:d=\(d)",
                     "-map", "0:v:0", "-map", "1:a:0",
                     "-c:v", videoCodec] + extraVideoArgs
            args += ["-c:a", audioCodec]
        } else {
            args += ["-c:v", videoCodec] + extraVideoArgs + ["-an"]
        }
        try CleanupTestMedia.runFFmpeg(args, output: out)
        return out
    }
}

// MARK: - Matrix: healthy diagnosis across the checklist containers

@Suite("VerifyAudio — media matrix", .serialized)
@MainActor
struct VerifyAudioMediaMatrixTests {

    /// One checklist row: generate + diagnose + assert "All is well"
    /// with the container's expected tech readout.
    private func diagnoseHealthy(name: String,
                                 videoCodec: String,
                                 extraVideoArgs: [String] = [],
                                 audioCodec: String,
                                 expectAudioCodec: String,
                                 expectBitDepth: Int?,
                                 expectContainerContains: String,
                                 size: String = "320x240",
                                 rate: String = "25") async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: name,
            videoCodec: videoCodec, extraVideoArgs: extraVideoArgs,
            audioCodec: audioCodec, size: size, rate: rate)

        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.isHealthy, "\(name): expected All is well, got \(d.findings)")
        #expect(d.persistedStatus == "ok")
        #expect(d.persistedNote == "")
        #expect(d.shape.audioStreams == 1)
        #expect(d.shape.audioCodec == expectAudioCodec)
        #expect(d.shape.audioChannels == 2)
        #expect(d.shape.audioSampleRateHz == 48000)
        #expect(d.shape.audioBitDepth == expectBitDepth,
                "\(name): bit depth readout — got \(String(describing: d.shape.audioBitDepth))")
        #expect(d.shape.containerFormat.contains(expectContainerContains))
        #expect(d.balanceAnalysis?.classification == .trueStereo,
                "\(name): levels pass must run and classify the stereo tone pair")
    }

    @Test("mp4/h264+aac diagnoses healthy", .timeLimit(.minutes(2)))
    func mp4H264Aac() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        try await diagnoseHealthy(name: "test_verify_matrix.mp4",
                                  videoCodec: "libx264",
                                  extraVideoArgs: ["-preset", "ultrafast"],
                                  audioCodec: "aac",
                                  expectAudioCodec: "aac",
                                  expectBitDepth: nil,   // lossy: never guess
                                  expectContainerContains: "mp4")
    }

    @Test("mov/prores+pcm diagnoses healthy", .timeLimit(.minutes(2)))
    func movProresPcm() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        try await diagnoseHealthy(name: "test_verify_matrix.mov",
                                  videoCodec: "prores",
                                  audioCodec: "pcm_s16le",
                                  expectAudioCodec: "pcm_s16le",
                                  expectBitDepth: 16,
                                  expectContainerContains: "mov")
    }

    @Test("mkv/ffv1+pcm diagnoses healthy", .timeLimit(.minutes(2)))
    func mkvFfv1Pcm() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        try await diagnoseHealthy(name: "test_verify_matrix.mkv",
                                  videoCodec: "ffv1",
                                  audioCodec: "pcm_s16le",
                                  expectAudioCodec: "pcm_s16le",
                                  expectBitDepth: 16,
                                  expectContainerContains: "matroska")
    }

    @Test("mxf/mpeg2+pcm diagnoses healthy", .timeLimit(.minutes(2)))
    func mxfMpeg2Pcm() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        try await diagnoseHealthy(name: "test_verify_matrix.mxf",
                                  videoCodec: "mpeg2video",
                                  extraVideoArgs: ["-g", "15"],
                                  audioCodec: "pcm_s16le",
                                  expectAudioCodec: "pcm_s16le",
                                  expectBitDepth: 16,
                                  expectContainerContains: "mxf",
                                  size: "720x576", rate: "25")
    }

    @Test("avi/dv+pcm diagnoses healthy", .timeLimit(.minutes(2)))
    func aviDvPcm() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        // DV requires legal NTSC geometry + 4:1:1 (TrimMediaMatrix rule).
        try await diagnoseHealthy(name: "test_verify_matrix.avi",
                                  videoCodec: "dvvideo",
                                  extraVideoArgs: ["-pix_fmt", "yuv411p"],
                                  audioCodec: "pcm_s16le",
                                  expectAudioCodec: "pcm_s16le",
                                  expectBitDepth: 16,
                                  expectContainerContains: "avi",
                                  size: "720x480", rate: "30000/1001")
    }

    // MARK: Negative diagnoses on real media

    @Test("the #125 class: audio much shorter than video → damaged", .timeLimit(.minutes(2)))
    func shortAudioFlagsDurationMismatch() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("mismatch")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 10 s of picture, 2 s of perfectly good stereo — the wrong-
        // audio shape Rick hit on the Christmas 2010 video.
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_shortaudio.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le",
            videoDuration: 10.0, audioDuration: 2.0)

        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.findings.count == 1)
        guard case .durationMismatch(let audio, let video)? = d.findings.first else {
            Issue.record("expected durationMismatch, got \(d.findings)")
            return
        }
        #expect(audio < 3.5 && video > 9.0,
                "probed durations off: audio \(audio)s video \(video)s")
        #expect(d.persistedStatus == "damaged")
        // Standardized batch-find shape (Manager 2026-07-24): damaged
        // notes lead with "Damaged audio — ", then the cause.
        #expect(d.persistedNote.hasPrefix("Damaged audio — audio shorter than video"))
    }

    @Test("silent track reported honestly, not damaged", .timeLimit(.minutes(2)))
    func silentAudioReported() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("silent")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_silent.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le",
            audioExpr: VerifyAudioTestMedia.silentExpr)

        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.findings == [.silentAudio])
        #expect(d.persistedStatus == "ok")
        #expect(d.persistedNote == "silent audio")
    }

    @Test("no audio stream → honest finding, points at Find Matching Audio", .timeLimit(.minutes(2)))
    func noAudioReported() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("noaudio")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_videoonly.mp4",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: nil)

        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.findings == [.noAudioStream])
        #expect(d.persistedStatus == "ok")
        #expect(d.persistedNote == "no audio stream")
        #expect(d.balanceAnalysis == nil, "no audio → no levels pass")
    }

    @Test("5.1 surround reported, never offered a balance", .timeLimit(.minutes(2)))
    func surroundReported() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("surround")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_surround.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le",
            audioExpr: VerifyAudioTestMedia.surround51Expr)

        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.findings == [.surround(channels: 6)])
        #expect(d.persistedStatus == "ok")
    }

    // MARK: Negative — a failed probe is an ERROR, never a verdict

    @Test("garbage bytes: diagnose THROWS — a failed probe can never persist a verdict",
          .timeLimit(.minutes(2)))
    func garbageFileThrowsInsteadOfDiagnosing() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("garbage")
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("test_verify_garbage.mov").path
        try Data("this is a text file cosplaying as a movie".utf8)
            .write(to: URL(fileURLWithPath: garbage))

        // The sheet persists ONLY from the success branch, so the
        // testable half of "failed diagnosis leaves the verdict fields
        // untouched" is: garbage must THROW (probeFailed), never come
        // back as a plausible diagnosis (e.g. a bogus "no audio stream"
        // verdict that would then be persisted as truth).
        let record = VideoRecord()
        record.fullPath = garbage
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(path: garbage)
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed? = thrown else {
            Issue.record("garbage input must throw probeFailed, got \(String(describing: thrown))")
            return
        }
        // And the record's verdict fields were never written.
        #expect(record.audioVerifyStatus == "")
        #expect(record.audioVerifyNote == "")
        #expect(record.audioVerifyDate == nil)
    }

    // MARK: QA F1 — a transient I/O failure must never persist "damaged"

    /// Shared analyze-failure injection: what AudioBalanceProbe.analyze
    /// throws for EVERY nonzero ffmpeg exit — undecodable codec and
    /// mid-decode I/O death look identical from the caller.
    private static let analyzeThrows: VerifyAudioProbe.AnalyzeStep = { _ in
        throw AudioBalanceProbeError.probeFailed(
            "ffmpeg astats pass on audio stream 0 exited with status 1")
    }

    @Test("QA F1: analyze fails + source vanished (real recheck) → diagnosis THROWS, no damage verdict",
          .timeLimit(.minutes(2)))
    func analyzeFailureWithVanishedSourceThrows() async throws {
        // Pre-QA behavior: ANY analyze failure became the undecodable-
        // codec damage finding — a healthy file whose volume died
        // mid-astats went permanently red into the notes:damaged
        // batch-DELETE set. (True red-run impractical: the analyze/
        // recheck seams did not exist before the fix; the failure mode
        // is pinned instead by the reachable-source test below, which
        // preserves the old conversion when the evidence supports it.)
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("io_vanish")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_io_vanish.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le")

        // The injected analyze step simulates the drive dying MID-pass:
        // it removes the file (what an eject/unmount looks like to the
        // next stat) and throws exactly what the real analyze throws.
        // The PRODUCTION recheck (sourceStillProbeable) then runs and
        // must report unreachable.
        let vanishAndThrow: VerifyAudioProbe.AnalyzeStep = { p in
            try? FileManager.default.removeItem(atPath: p)
            throw AudioBalanceProbeError.probeFailed(
                "ffmpeg astats pass on audio stream 0 exited with status 1")
        }
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(path: path,
                                                    analyzeOverride: vanishAndThrow)
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed(let detail)? = thrown else {
            Issue.record("expected probeFailed (diagnosis failure, nothing persisted), got \(String(describing: thrown))")
            return
        }
        #expect(detail.contains("no verdict was recorded"),
                "the failure message must say no verdict was recorded: \(detail)")
    }

    @Test("QA F1: analyze fails + mount stalled (injected recheck) → diagnosis THROWS",
          .timeLimit(.minutes(2)))
    func analyzeFailureWithStalledMountThrows() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("io_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_io_stall.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le")

        // A stalled SMB mount can keep stat-ing while every read hangs —
        // the injected recheck models "no longer probeable" without a
        // real network volume.
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(
                path: path,
                analyzeOverride: Self.analyzeThrows,
                sourceRecheckOverride: { _ in false })
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed? = thrown else {
            Issue.record("expected probeFailed, got \(String(describing: thrown))")
            return
        }
    }

    @Test("QA F1: analyze fails + source STILL probeable (real recheck) → undecodable damage stands",
          .timeLimit(.minutes(2)))
    func analyzeFailureWithReachableSourceIsCodecDamage() async throws {
        // The counterpart guard: when the file is still there and still
        // shape-probeable, the evidence points at the codec — the
        // damage finding must SURVIVE the QA F1 fix, or truly broken
        // audio would stop being flagged.
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("io_reachable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_io_reachable.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le")

        let d = try await VerifyAudioProbe.diagnose(path: path,
                                                    analyzeOverride: Self.analyzeThrows)
        #expect(d.findings == [.unsupportedCodec(codec: "pcm_s16le", decodable: false)])
        #expect(d.persistedStatus == "damaged")
        #expect(d.persistedNote.hasPrefix("Damaged audio — undecodable audio"))
        #expect(d.balanceAnalysis == nil)
    }

    // MARK: GH #136 — a levels-pass TIMEOUT must never persist "damaged"

    @Test("GH #136: levels pass times out on a reachable file → diagnosis THROWS, no damage language, nothing persisted",
          .timeLimit(.minutes(2)))
    func analyzeTimeoutThrowsInsteadOfDamageVerdict() async throws {
        // The Cape-1992 bug: a healthy 63.7 GB mkv blew the fixed 300 s
        // astats deadline; the killed ffmpeg surfaced as probeFailed, the
        // QA F1 recheck found the file (correctly) still reachable, and
        // the diagnosis persisted "Damaged audio — undecodable audio
        // (aac)" — a wrong verdict feeding the notes:damaged batch-DELETE
        // flow. Post-fix: the timeout is a DISTINCT error; even with the
        // source demonstrably reachable (recheck forced true), diagnose
        // must throw a diagnosis failure, never produce a verdict.
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("timeout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_timeout.mkv",
            videoCodec: "ffv1",
            audioCodec: "aac")

        let timeoutThrow: VerifyAudioProbe.AnalyzeStep = { _ in
            throw AudioBalanceProbeError.timedOut(afterSeconds: 300)
        }
        let record = VideoRecord()
        record.fullPath = path
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(
                path: path,
                analyzeOverride: timeoutThrow,
                sourceRecheckOverride: { _ in true })   // reachable — the trap case
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed(let detail)? = thrown else {
            Issue.record("timeout must throw a diagnosis failure, got \(String(describing: thrown))")
            return
        }
        // Honest, friendly, and free of codec-damage language.
        #expect(detail.contains("ran out of time"),
                "message must say the check ran out of time: \(detail)")
        #expect(detail.contains("no verdict was recorded"),
                "message must promise nothing was recorded: \(detail)")
        let lower = detail.lowercased()
        #expect(!lower.contains("undecodable") && !lower.contains("codec")
                && !lower.contains("damaged") && !lower.contains("deadline")
                && !lower.contains("exit"),
                "no damage/jargon language in a timeout message: \(detail)")
        // And the record's verdict fields were never written.
        #expect(record.audioVerifyStatus == "")
        #expect(record.audioVerifyNote == "")
        #expect(record.audioVerifyDate == nil)
    }

    @Test("GH #136: timeout bypasses the reachability recheck — the recheck must not even run",
          .timeLimit(.minutes(2)))
    func analyzeTimeoutNeverConsultsReachability() async throws {
        // The recheck exists to arbitrate probeFailed (I/O vs codec).
        // For a timeout there is nothing to arbitrate — if the recheck
        // ran and the volume happened to hiccup, a timeout could morph
        // into the unreachable message, muddying the honest "too large"
        // story. Pin: the recheck closure is never invoked.
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("timeout_norecheck")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_timeout_norecheck.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le")

        let recheckRan = LockedFlagBox()
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(
                path: path,
                analyzeOverride: { _ in
                    throw AudioBalanceProbeError.timedOut(afterSeconds: 653)
                },
                sourceRecheckOverride: { _ in
                    recheckRan.set()
                    return false
                })
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed? = thrown else {
            Issue.record("expected probeFailed, got \(String(describing: thrown))")
            return
        }
        #expect(!recheckRan.isSet, "timeout must not trigger the reachability recheck")
    }

    @Test("GH #136 (QA MINOR-2): SHAPE-probe timeout inside analyze → diagnose throws, no damage verdict, recheck not consulted",
          .timeLimit(.minutes(2)))
    func shapeProbeTimeoutThrowsWithoutDamageVerdict() async throws {
        // AudioBalanceProbe.analyze's 60 s ffprobe shape probe now throws
        // .timedOut(afterSeconds: 60) when the runner's deadline killed
        // ffprobe (previously a generic probeFailed — which reached the
        // reachability recheck and, on a stalled-then-recovered mount,
        // could still mint a damage verdict from a runner kill). Pin the
        // whole diagnose-level contract for that error shape.
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("timeout_shape")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_timeout_shape.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "pcm_s16le")

        let recheckRan = LockedFlagBox()
        var thrown: Error?
        do {
            _ = try await VerifyAudioProbe.diagnose(
                path: path,
                analyzeOverride: { _ in
                    // Exactly what the shape-probe guard throws post-fix.
                    throw AudioBalanceProbeError.timedOut(afterSeconds: 60)
                },
                sourceRecheckOverride: { _ in
                    recheckRan.set()
                    return true   // "recovered mount" — the trap case
                })
        } catch {
            thrown = error
        }
        guard case AudioVerifyProbeError.probeFailed(let detail)? = thrown else {
            Issue.record("shape-probe timeout must throw a diagnosis failure, got \(String(describing: thrown))")
            return
        }
        #expect(!recheckRan.isSet,
                "shape-probe timeout must not trigger the reachability recheck")
        let lower = detail.lowercased()
        #expect(!lower.contains("undecodable") && !lower.contains("codec")
                && !lower.contains("damaged"),
                "no damage language for a runner kill: \(detail)")
        #expect(detail.contains("no verdict was recorded"),
                "message must promise nothing was recorded: \(detail)")
    }
}

/// Minimal thread-safe flag for @Sendable test closures.
private final class LockedFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Rebuild Audio Track — real round-trip

@Suite("VerifyAudio — rebuild round-trip", .serialized)
@MainActor
struct RebuildAudioJobRoundTripTests {

    private func partialDebris(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".vs-partial") }
    }

    /// Generate a fixture, diagnose it for the real shape, and build the
    /// record+model pair a rebuild job needs.
    private func makeFixture(in dir: URL, name: String = "test_verify_rebuild.mp4")
        async throws -> (record: VideoRecord, shape: AudioVerifyShape, model: VideoScanModel) {
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: name,
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "aac", videoDuration: 4.0)
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(
            path: path,
            durationSeconds: d.shape.containerDurationSeconds,
            audioCodec: d.shape.audioCodec)
        model.records = [record]
        return (record, d.shape, model)
    }

    @Test("rebuild: video copied, audio → pcm_s16le, lands beside source, source untouched",
          .timeLimit(.minutes(2)))
    func rebuildRoundTrip() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let before = try CleanupTestMedia.fingerprint(record.fullPath)

        let job = RebuildAudioJob(record: record,
                                  reason: "invalid codec (aac stand-in)",
                                  shape: shape, model: model)
        job.start()
        await job.task?.value

        guard case .finished(let summary) = job.state else {
            Issue.record("job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        #expect(summary.contains("Original untouched"))

        // Placement contract: <stem>_RepairedAudio.mov BESIDE the source.
        let published = try #require(job.publishedURL)
        #expect(published.lastPathComponent == "test_verify_rebuild_RepairedAudio.mov")
        #expect(published.deletingLastPathComponent()
                == URL(fileURLWithPath: record.fullPath).deletingLastPathComponent())

        // THE hash oracle: source bytes + mtime byte-identical.
        #expect(try CleanupTestMedia.fingerprint(record.fullPath) == before,
                "SOURCE FILE CHANGED during rebuild — must never happen")

        // Output contract, verified independently of the job's own
        // verification: copied h264 picture + exactly one pcm_s16le track.
        let out = try CleanupTestMedia.probe(published.path)
        #expect(out.video?.codec_name == "h264", "video must be STREAM-COPIED")
        #expect(out.audio?.codec_name == "pcm_s16le")
        #expect(abs(out.durationSeconds - 4.0) <= RebuildAudioFix.durationToleranceSeconds + 0.5)
        #expect(partialDebris(in: dir).isEmpty)

        // Catalog insertion + provenance.
        let derived = try #require(model.records.first { $0.fullPath == published.path })
        #expect(derived.derivedFrom == record.id)
        #expect(derived.derivationKind == "rebuildAudio")

        // File Journey stamps on BOTH records, and — the lock-step
        // sensor with PRODUCTION-written strings — both notes classify
        // machine end to end (nothing would migrate to userNotes).
        #expect(record.notes.contains("Verify Audio "))
        #expect(record.notes.contains(published.lastPathComponent))
        #expect(derived.notes.contains("Verify Audio "))
        #expect(derived.notes.contains("invalid codec (aac stand-in)"))
        #expect(UserNotesMigration.migrate(notes: record.notes, userNotes: "") == nil,
                "the job's REAL source stamp must classify machine: '\(record.notes)'")
        #expect(UserNotesMigration.migrate(notes: derived.notes, userNotes: "") == nil,
                "the job's REAL derived stamp must classify machine: '\(derived.notes)'")
    }

    @Test("second rebuild uniquifies to '_RepairedAudio 2.mov' — never clobbers",
          .timeLimit(.minutes(3)))
    func rerunUniquifies() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_unique")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let first = RebuildAudioJob(record: record, reason: "test", shape: shape, model: model)
        first.start()
        await first.task?.value
        guard case .finished = first.state else {
            Issue.record("first job did not finish: \(first.state)")
            return
        }
        let second = RebuildAudioJob(record: record, reason: "test", shape: shape, model: model)
        second.start()
        await second.task?.value
        guard case .finished = second.state else {
            Issue.record("second job did not finish: \(second.state)")
            return
        }
        #expect(second.publishedURL?.lastPathComponent
                == "test_verify_rebuild_RepairedAudio 2.mov")
        #expect(FileManager.default.fileExists(
            atPath: first.publishedURL?.path ?? ""), "first output must survive the second run")
    }

    @Test("QA F2: truncated rebuilt audio FAILS verification — nothing promoted, nothing cataloged",
          .timeLimit(.minutes(2)))
    func truncatedAudioFailsVerification() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_truncated")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 6 s of picture, 2 s of audio. After the rebuild the picture is
        // stream-copied FULL LENGTH while the re-encoded audio ends at
        // 2 s — byte-for-byte what a mid-decode death on damaged source
        // audio leaves behind (ffmpeg can exit 0 for it). CONTAINER
        // duration is the longest track (6 s), matching the source, so
        // the pre-QA shape+container verification PASSED this truncated
        // repair — this test was verified RED against that behavior
        // before RebuildAudioFix.truncatedAudioMismatch existed
        // (QA finding 2, 2026-07-24).
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_verify_truncated.mp4",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "aac", videoDuration: 6.0, audioDuration: 2.0)
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(
            path: path, durationSeconds: d.shape.containerDurationSeconds,
            audioCodec: d.shape.audioCodec)
        model.records = [record]

        let job = RebuildAudioJob(record: record, reason: "test",
                                  shape: d.shape, model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("truncated repair must FAIL verification, got \(job.state)")
            return
        }
        #expect(message.contains("Verification failed"),
                "failure must be the verification gate, got: \(message)")
        // The truncated repair must leave NO trace: nothing promoted,
        // no partial debris, no catalog insertion, no journey stamps.
        #expect(job.publishedURL == nil)
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(model.records.count == 1, "no catalog insertion for a failed repair")
        #expect(record.notes.isEmpty, "a failed rebuild must not stamp the source record")
    }

    @Test("ffmpeg failure leaves nothing — no partial, nothing at the final path",
          .timeLimit(.minutes(2)))
    func renderFailureLeavesNothing() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_fail")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let job = RebuildAudioJob(record: record, reason: "test", shape: shape,
                                  model: model, ffmpegPathOverride: "/usr/bin/false")
        job.start()
        await job.task?.value

        guard case .failed = job.state else {
            Issue.record("expected failed, got \(job.state)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(record.notes.isEmpty, "a failed rebuild must not stamp the source record")
    }

    @Test("cancel leaves nothing at the final path and no partial debris",
          .timeLimit(.minutes(2)))
    func cancelLeavesNothing() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let job = RebuildAudioJob(record: record, reason: "test", shape: shape, model: model)
        job.start()
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "expected cancelled, got \(job.state)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    // regression: GH #129 — cancel() before start() must not invoke ffmpeg.
    @Test("cancel before start never begins a rebuild render",
          .timeLimit(.minutes(2)))
    func cancelBeforeStartSkipsRender() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_cancel_before_start")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let marker = dir.appendingPathComponent("renderer_was_invoked")
        let renderer = dir.appendingPathComponent("witness-renderer.sh")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 1\n"
            .write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: renderer.path)

        let job = RebuildAudioJob(record: record, reason: "test", shape: shape,
                                  model: model, ffmpegPathOverride: renderer.path)
        job.cancel()
        job.start()
        await job.task?.value

        #expect(job.state == .cancelled, "expected cancelled, got \(job.state)")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "a pre-start cancellation must stop before invoking the renderer")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    @Test("duplicate dispatch against the same record is refused at the MFO layer",
          .timeLimit(.minutes(2)))
    func doubleDispatchRefused() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_dupe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, shape, model) = try await makeFixture(in: dir)
        let center = MediaFileOperationsCenter()
        let first = center.startRebuildAudio(record: record, reason: "test",
                                             shape: shape, model: model)
        let second = center.startRebuildAudio(record: record, reason: "test",
                                              shape: shape, model: model)
        #expect(first != nil)
        #expect(second == nil, "duplicate active dispatch must be refused")
        await first?.task?.value
        // Terminal → a new dispatch is allowed again.
        let third = center.startRebuildAudio(record: record, reason: "test",
                                             shape: shape, model: model)
        #expect(third != nil)
        await third?.task?.value
    }
}
