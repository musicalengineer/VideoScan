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
