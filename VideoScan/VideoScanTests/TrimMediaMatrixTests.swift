// TrimMediaMatrixTests.swift
// MEDIA MATRIX dimension for Trim Master (feature-test checklist item 3)
// — the heart of this feature. Full REAL TrimJob runs (real ffmpeg, real
// ffprobe verification, real publish) against synthetic fixtures across
// the checklist containers:
//
//   ffv1(-g 1)+pcm / mkv   — Rick's archival-master recipe: cut must be
//                            EXACTLY frame-accurate (packet-count oracle)
//   prores+pcm    / mov    — intra: frame-accurate
//   dv+pcm        / avi    — intra: frame-accurate
//   h264(GOP 50)+aac / mp4 — long-GOP: keyframe snap asserted HONESTLY
//                            (starts at/earlier than asked, bounded by
//                            one GOP — never drops wanted content)
//   mpeg2(GOP 15)+pcm / mxf — long-GOP in the Avid-adjacent container
//
// Every positive case also runs the source-never-modified hash oracle
// (SHA-256 + size + mtime — the checklist's sensor at matrix scale).
// Negative cases: in ≥ out, out > duration, missing source, audio-only
// record, cancel mid-copy (throttled via the -readrate test seam) — each
// must leave NO partial and NOTHING at the final path.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct TrimMediaMatrixTests {

    // MARK: - Shared driver

    /// Generate a fixture, trim it with a REAL TrimJob, assert the
    /// invariants every faithful stream-copy trim must satisfy, and
    /// return (job, source packet count, output packet count).
    @discardableResult
    private func runTrim(dir: URL,
                         fixture: String,
                         range: TrimRange,
                         expectVideoCodec: String) async throws -> (job: TrimJob, outPackets: Int) {
        let before = try CleanupTestMedia.fingerprint(fixture)

        let model = VideoScanModel()
        let probe = try CleanupTestMedia.probe(fixture)
        let record = makeTrimSourceRecord(path: fixture,
                                          durationSeconds: probe.durationSeconds,
                                          videoCodec: expectVideoCodec)
        model.records = [record]

        let job = TrimJob(record: record, range: range, model: model)
        job.start()
        await job.task?.value

        guard case .finished(let summary) = job.state else {
            throw TrimMatrixFailure.jobDidNotFinish(String(describing: job.state))
        }
        #expect(summary.contains("Verified"),
                "the row summary must surface the verification verdict")
        #expect(summary.contains("Original untouched"))

        // THE sensor, at matrix scale: source bytes + mtime identical.
        let after = try CleanupTestMedia.fingerprint(fixture)
        #expect(after == before,
                "SOURCE FILE CHANGED during trim of \(fixture) — this must never happen")

        // Output invariants: exists at the published name, codec
        // unchanged, both streams carried, no partial debris.
        let published = try #require(job.publishedURL)
        #expect(FileManager.default.fileExists(atPath: published.path))
        let outProbe = try CleanupTestMedia.probe(published.path)
        #expect(outProbe.video?.codec_name == expectVideoCodec,
                "stream copy must not change the video codec")
        #expect(outProbe.audio != nil, "-map 0 must carry the audio stream")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!entries.contains { $0.contains(".vs-partial") },
                "partial debris left behind: \(entries)")

        let outPackets = try TrimTestProbe.videoPacketCount(published.path)
        return (job, outPackets)
    }

    private enum TrimMatrixFailure: Error {
        case jobDidNotFinish(String)
    }

    // MARK: - ffv1+pcm / mkv (the archival-master case)

    @Test("ffv1 -g1 / mkv: frame-accurate lossless cut — exact packet count",
          .timeLimit(.minutes(2)))
    func ffv1MKVFrameAccurate() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_ffv1")
        defer { try? FileManager.default.removeItem(at: dir) }

        // -g 1 matches the app's own Preservation preset (every frame a
        // seek point) — see TranscodeJob+Args.
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_master.mkv",
            duration: 10.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        let (job, outPackets) = try await runTrim(
            dir: dir, fixture: src,
            range: TrimRange(inSeconds: 2.0, outSeconds: 5.0),
            expectVideoCodec: "ffv1")

        // Frame-exactness: 3 s at 25 fps = exactly 75 frames.
        #expect(outPackets == 75,
                "intra cut must be frame-accurate: expected 75 frames, got \(outPackets)")
        let published = try #require(job.publishedURL)
        #expect(published.pathExtension == "mkv",
                "container preserved — a trimmed MKV master stays an MKV")
        let outProbe = try CleanupTestMedia.probe(published.path)
        #expect(abs(outProbe.durationSeconds - 3.0) < 0.75)
    }

    // MARK: - prores / mov

    @Test("prores / mov: frame-accurate cut", .timeLimit(.minutes(2)))
    func proresMOVFrameAccurate() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_prores")
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_edit.mov",
            duration: 8.0, size: "320x240", rate: "25",
            videoCodec: "prores",
            audioCodec: "pcm_s16le")

        let (_, outPackets) = try await runTrim(
            dir: dir, fixture: src,
            range: TrimRange(inSeconds: 2.0, outSeconds: 5.0),
            expectVideoCodec: "prores")
        #expect(outPackets == 75, "prores is intra — expected 75 frames, got \(outPackets)")
    }

    // MARK: - dv / avi

    @Test("dv / avi: frame-accurate cut", .timeLimit(.minutes(2)))
    func dvAVIFrameAccurate() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_dv")
        defer { try? FileManager.default.removeItem(at: dir) }

        // DV requires legal NTSC geometry + 4:1:1.
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_camcorder.avi",
            duration: 6.0, size: "720x480", rate: "30000/1001",
            videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p"],
            audioCodec: "pcm_s16le")

        let (_, outPackets) = try await runTrim(
            dir: dir, fixture: src,
            range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
            expectVideoCodec: "dvvideo")
        // 3 s at 29.97 fps = 90 frames (89.91 → ffmpeg emits 90).
        #expect(outPackets == 90, "dv is intra — expected 90 frames, got \(outPackets)")
    }

    // MARK: - h264 / mp4 (long-GOP: the HONEST keyframe snap)

    @Test("h264 / mp4: keyframe snap asserted honestly — never drops wanted content",
          .timeLimit(.minutes(2)))
    func h264MP4KeyframeSnap() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_h264")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Keyframe every 50 frames = 2 s GOP; asking for in=3.0 forces a
        // snap back to the keyframe at 2.0.
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_gop.mp4",
            duration: 10.0, size: "320x240", rate: "25",
            videoCodec: "libx264",
            extraVideoArgs: ["-g", "50", "-keyint_min", "50", "-sc_threshold", "0"],
            audioCodec: "aac")

        let (_, outPackets) = try await runTrim(
            dir: dir, fixture: src,
            range: TrimRange(inSeconds: 3.0, outSeconds: 6.0),
            expectVideoCodec: "h264")

        // The honest contract: EVERYTHING the user asked for is present
        // (≥ 75 frames), plus at most ~one GOP of extra lead-in (≤ 75 +
        // 50, with a couple frames of muxer slack). A cut that DROPPED
        // requested frames (output seeking's failure mode) lands under 75
        // and fails here.
        #expect(outPackets >= 75,
                "long-GOP trim dropped requested frames: \(outPackets) < 75 — the snap must err toward KEEPING content")
        #expect(outPackets <= 75 + 50 + 5,
                "long-GOP trim kept more than one GOP of extra lead-in: \(outPackets)")
    }

    // MARK: - mpeg2 / mxf

    @Test("mpeg2 / mxf: stream-copy trim in the Avid-adjacent container",
          .timeLimit(.minutes(2)))
    func mpeg2MXFTrims() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_mxf")
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_essence.mxf",
            duration: 6.0, size: "720x576", rate: "25",
            videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15"],
            audioCodec: "pcm_s16le")

        let (job, outPackets) = try await runTrim(
            dir: dir, fixture: src,
            range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
            expectVideoCodec: "mpeg2video")
        let published = try #require(job.publishedURL)
        #expect(published.pathExtension == "mxf")
        // 15-frame GOP at 25 fps = 0.6 s snap window.
        #expect(outPackets >= 75 && outPackets <= 75 + 15 + 5,
                "mxf long-GOP cut outside the honest snap window: \(outPackets)")
    }

    // MARK: - ffv1 large-GOP + probed-false verdict (MAJOR 1, end-to-end)

    /// The wasteful-discard scenario QA flagged: an intra-NAMED file
    /// whose packets are not actually all seek points (here: FFV1 with a
    /// 1.2 s GOP — any third-party capture tool's default-ish output).
    /// The cut snaps back ~1.1 s, which is OVER the 0.75 s intra
    /// tolerance — before the probe verdict was plumbed through, this
    /// completed copy was verify-FAILED and deleted. With probedIntra =
    /// false the tolerance widens, the trim publishes, and the summary
    /// wording is honestly "keyframe-aligned".
    @Test("ffv1 large-GOP probed false: honest snap publishes instead of false-failing",
          .timeLimit(.minutes(2)))
    func ffv1LargeGOPProbedFalsePublishes() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_gop_ffv1")
        defer { try? FileManager.default.removeItem(at: dir) }

        // -g 30 at 25 fps = 1.2 s between seek points.
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_thirdparty.mkv",
            duration: 8.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "30"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        // The probe verdict the sheet would compute for this file.
        let csv = try TrimTestProbe.keyframeFlagCSV(src)
        let probed = TrimKeyframeProbe.allSampledPacketsAreKeyframes(csv: csv)
        #expect(probed == false, "fixture must probe as NOT all-keyframes")

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 8.0, videoCodec: "ffv1")
        model.records = [record]
        // in = 2.3 lands mid-GOP: the copy snaps back to the seek point
        // at 1.2 s (~1.1 s overshoot > 0.75 s intra tolerance).
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 2.3, outSeconds: 5.3),
                          model: model,
                          probedIntra: probed)

        #expect(job.accuracySummaryWord == "keyframe-aligned",
                "the finished row must not claim frame accuracy for a keyframe-snapped file")

        job.start()
        await job.task?.value

        guard case .finished(let summary) = job.state else {
            Issue.record("probed-false trim must publish (widened tolerance), got \(job.state)")
            return
        }
        #expect(summary.contains("Verified"))
        #expect(try CleanupTestMedia.fingerprint(src) == before)
        let published = try #require(job.publishedURL)
        // Everything asked for is present (the snap errs toward keeping).
        let outPackets = try TrimTestProbe.videoPacketCount(published.path)
        #expect(outPackets >= 75,
                "snap must never drop requested frames: \(outPackets) < 75")
    }

    // MARK: - Negative: invalid ranges write NOTHING

    @Test("in ≥ out is rejected before anything touches disk")
    func rejectsInNotBeforeOut() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_neg_range")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_neg.mkv",
            duration: 4.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 4.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 3.0, outSeconds: 3.0),
                          model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("in==out must fail, got \(job.state)")
            return
        }
        #expect(message.contains("start point"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["test_trim_neg.mkv"],
                "an invalid range must write NOTHING: \(entries)")
        #expect(try CleanupTestMedia.fingerprint(src) == before)
        #expect(model.records.count == 1, "no phantom catalog record")
    }

    @Test("out beyond the source duration is rejected before anything touches disk")
    func rejectsOutBeyondDuration() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_neg_dur")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_neg2.mkv",
            duration: 4.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 4.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 30.0),
                          model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("out>duration must fail, got \(job.state)")
            return
        }
        #expect(message.contains("past the end"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["test_trim_neg2.mkv"])
    }

    @Test("missing source fails loudly")
    func rejectsMissingSource() async throws {
        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: "/nonexistent/tape.mkv",
                                          durationSeconds: 100, videoCodec: "ffv1")
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1, outSeconds: 5),
                          model: model)
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else {
            Issue.record("missing source must fail, got \(job.state)")
            return
        }
        #expect(message.contains("missing"))
    }

    @Test("audio-only records are rejected — trim needs a video stream")
    func rejectsAudioOnly() async throws {
        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: "/tmp/whatever.wav",
                                          durationSeconds: 100, videoCodec: "",
                                          streamType: .audioOnly)
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1, outSeconds: 5),
                          model: model)
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else {
            Issue.record("audio-only must fail, got \(job.state)")
            return
        }
        #expect(message.contains("video stream"))
    }

    // MARK: - Negative: cancel mid-copy

    @Test("cancel mid-trim: ffmpeg killed, partial removed, NOTHING at the final path, source untouched",
          .timeLimit(.minutes(2)))
    func cancelMidTrimLeavesNothing() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_cancel.mkv",
            duration: 8.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 8.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 7.0),
                          model: model)
        // Test seam: throttle the input read to half realtime so the 6 s
        // cut takes ~12 s — a cancel at 1.5 s deterministically lands
        // mid-copy.
        job.debugExtraInputArgs = ["-readrate", "0.5"]
        let finalName = job.outputURL.lastPathComponent
        job.start()

        // While the copy runs, the FINAL name must never exist (partials
        // only). Poll for 1.5 s, then cancel.
        var sawFinalMidRun = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if entries.contains(finalName) { sawFinalMidRun = true }
        }
        job.cancel()
        await job.task?.value

        #expect(!sawFinalMidRun,
                "\(finalName) existed DURING the copy — temp-name discipline broken")
        #expect(job.state == .cancelled, "expected .cancelled, got \(job.state)")

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["test_trim_cancel.mkv"],
                "cancel must leave ONLY the source: \(entries)")
        #expect(try CleanupTestMedia.fingerprint(src) == before,
                "source changed during a cancelled trim")
        #expect(model.records.count == 1, "no catalog record for a cancelled trim")
    }
}
