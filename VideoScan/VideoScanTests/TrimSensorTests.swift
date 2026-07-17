// TrimSensorTests.swift
// SENSOR dimension for Trim Master (feature-test checklist item 5):
// regression sensors pinning the safety-critical invariants so a future
// change that weakens them breaks LOUDLY.
//
//   (a) ORIGINAL NEVER MODIFIED — dedicated hash oracle on a full
//       real-ffmpeg job (also asserted per-case in the media matrix).
//   (b) TEMP-NAME DISCIPLINE — ffmpeg writes ONLY to the `.vs-partial`
//       sibling; the final name appears solely via the post-verify
//       rename. Pinned three ways: the partial naming convention, a
//       simulated crash (stale partial present → final path absent →
//       next run cleans up and still succeeds), and the mid-run polling
//       in the matrix's cancel test.
//   (c) NON-CLOBBERING PUBLISH — a pre-existing file at the planned
//       final name is NEVER overwritten; the job bumps to "_trimmed 2".
//   (d) THE KEYFRAME HONESTY PROBE — a default-GOP FFV1 (ffmpeg's -g 12)
//       is NOT all-keyframes, and the probe detects that; our -g 1
//       preservation-style FFV1 is. This pins the empirical finding the
//       whole accuracy contract rests on (see TrimEngine.swift header).

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct TrimSensorTests {

    // MARK: - (a) Original byte-identical after a full real job

    @Test("the original file is byte-identical (sha256 + size + mtime) after a full real trim",
          .timeLimit(.minutes(2)))
    func originalUntouchedAfterFullRealTrim() async throws {
        try #require(CleanupTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_orig")
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_sensor.mkv",
            duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
                          model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("real trim did not finish: \(job.state)")
            return
        }
        let after = try CleanupTestMedia.fingerprint(src)
        #expect(after.sha256 == before.sha256,
                "ORIGINAL FILE BYTES CHANGED during trim — this must never happen")
        #expect(after == before,
                "Original's size/mtime changed during trim: \(before) → \(after)")
    }

    // MARK: - (b) Temp-name discipline

    @Test("the partial convention keeps in-flight output out of the final name, same directory")
    func partialNamingConventionPinned() {
        let final = URL(fileURLWithPath: "/Volumes/Tapes/1998/thanksgiving_trimmed.mkv")
        let partial = ReformatJob.partialURL(for: final)
        #expect(partial.lastPathComponent == "thanksgiving_trimmed.vs-partial.mkv")
        #expect(partial.deletingLastPathComponent() == final.deletingLastPathComponent(),
                "Partial must be a SIBLING of the final name — same directory, same volume, atomic rename")
    }

    @Test("a stale partial from a crash is cleaned up; the final path never held it",
          .timeLimit(.minutes(2)))
    func stalePartialFromCrashIsRecovered() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_crash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_crash.mkv",
            duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
                          model: model)

        // Simulate the crash aftermath: a truncated partial exists (a
        // kill -9 mid-copy leaves exactly this), and — the actual
        // invariant — NOTHING at the final path.
        let partial = ReformatJob.partialURL(for: job.outputURL)
        try Data("truncated-by-crash".utf8).write(to: partial)
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path),
                "precondition: the crash left no plausible-looking file at the final name")

        // The next run must clean the debris and still succeed.
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("re-run after crash debris did not finish: \(job.state)")
            return
        }
        let published = try #require(job.publishedURL)
        let outProbe = try CleanupTestMedia.probe(published.path)
        #expect(outProbe.video?.codec_name == "ffv1",
                "published file must be the fresh verified trim, not crash debris")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!entries.contains { $0.contains(".vs-partial") },
                "stale partial not cleaned up: \(entries)")
    }

    // MARK: - (c) Non-clobbering publish

    @Test("a pre-existing file at the planned name is never overwritten",
          .timeLimit(.minutes(2)))
    func publishNeverClobbers() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_clobber")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_clobber.mkv",
            duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")

        // Somebody (a prior trim, the user) already owns the planned name.
        let sentinel = Data("precious-existing-file".utf8)
        let plannedPath = dir.appendingPathComponent("test_trim_clobber_trimmed.mkv")
        try sentinel.write(to: plannedPath)

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
                          model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("trim did not finish: \(job.state)")
            return
        }
        // The sentinel is byte-identical…
        #expect(try Data(contentsOf: plannedPath) == sentinel,
                "EXISTING FILE WAS OVERWRITTEN by a trim publish")
        // …and the trim landed at the bumped name.
        let published = try #require(job.publishedURL)
        #expect(published.lastPathComponent == "test_trim_clobber_trimmed 2.mkv",
                "expected Finder-style bump, got \(published.lastPathComponent)")
    }

    // MARK: - (e) ffmpeg nonzero-exit path (QA MAJOR 3)

    /// End-to-end oracle on the exitCode != 0 branch: the debug input-args
    /// seam injects an invalid input option so ffmpeg dies at input-open.
    /// The failure must leave the world EXACTLY as it was — no partial,
    /// nothing at the final name, source bytes untouched, no phantom
    /// catalog record — and the job must fail with an attributed reason.
    @Test("ffmpeg nonzero exit: partial removed, no final, source untouched, no phantom record",
          .timeLimit(.minutes(2)))
    func ffmpegFailureLeavesNothing() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_exit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_exit.mkv",
            duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 1.0, outSeconds: 4.0),
                          model: model)
        // Force exit != 0: an unknown input format makes ffmpeg fail at
        // input-open, after the argument vector is fully assembled.
        job.debugExtraInputArgs = ["-f", "definitely_not_a_format"]
        let finalName = job.outputURL.lastPathComponent
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("nonzero ffmpeg exit must fail the job, got \(job.state)")
            return
        }
        #expect(message.contains("ffmpeg failed (exit"),
                "the failure must attribute the ffmpeg exit code: \(message)")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!entries.contains { $0.contains(".vs-partial") },
                "partial debris after ffmpeg failure: \(entries)")
        #expect(!entries.contains(finalName),
                "NOTHING may land at the final name on an ffmpeg failure")
        #expect(try CleanupTestMedia.fingerprint(src) == before,
                "source changed during a failed trim")
        #expect(model.records.count == 1, "no phantom catalog record for a failed trim")
        #expect(job.publishedURL == nil)
    }

    // MARK: - (f) Verify-failure path (QA MAJOR 3)

    /// End-to-end oracle on the verification-failure branch, forced
    /// deterministically via a stale catalog duration: the record claims
    /// 100 s but the real file holds 4 s, so a 0→50 s trim validates,
    /// copies everything ffmpeg can find (~4 s), exits 0 — and the
    /// duration check must then catch the 46 s shortfall, delete the
    /// partial, publish nothing, and fail with the honest reason.
    @Test("verification failure: partial removed, no final, source untouched, no phantom record",
          .timeLimit(.minutes(2)))
    func verifyFailureLeavesNothing() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_verifyfail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_verifyfail.mkv",
            duration: 4.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: "pcm_s16le")
        let before = try CleanupTestMedia.fingerprint(src)

        let model = VideoScanModel()
        // Stale catalog: claims 100 s for a 4 s file.
        let record = makeTrimSourceRecord(path: src, durationSeconds: 100.0, videoCodec: "ffv1")
        model.records = [record]
        let job = TrimJob(record: record,
                          range: TrimRange(inSeconds: 0.0, outSeconds: 50.0),
                          model: model)
        let finalName = job.outputURL.lastPathComponent
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("a 46 s duration shortfall must fail verification, got \(job.state)")
            return
        }
        #expect(message.contains("Verification failed"),
                "the row must carry the verification verdict: \(message)")
        #expect(message.contains("original is untouched"))
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!entries.contains { $0.contains(".vs-partial") },
                "partial debris after verify failure: \(entries)")
        #expect(!entries.contains(finalName),
                "an unverified file must NEVER land at the final name")
        #expect(try CleanupTestMedia.fingerprint(src) == before,
                "source changed during a verify-failed trim")
        #expect(model.records.count == 1, "no phantom catalog record for a verify-failed trim")
        #expect(job.publishedURL == nil)
    }

    // MARK: - (d) The keyframe honesty probe (pins the -g finding)

    @Test("default-GOP ffv1 is NOT all-keyframes; -g 1 ffv1 is — the probe tells them apart",
          .timeLimit(.minutes(2)))
    func keyframeProbeDetectsDefaultGOPFFV1() throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("trim_sensor_probe")
        defer { try? FileManager.default.removeItem(at: dir) }

        // ffmpeg's FFV1 default (-g 12): frames between keyframes reuse
        // the range-coder context — NOT independent seek points.
        let defaultGOP = try CleanupTestMedia.generate(
            into: dir, name: "test_probe_default.mkv",
            duration: 3.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", audioCodec: nil)
        let defaultCSV = try TrimTestProbe.keyframeFlagCSV(defaultGOP)
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(csv: defaultCSV) == false,
                "default-GOP ffv1 must be detected as NOT frame-accurate — if this starts passing, re-verify the whole accuracy contract in TrimEngine.swift")

        // Our preservation recipe (-g 1): every frame a seek point.
        let g1 = try CleanupTestMedia.generate(
            into: dir, name: "test_probe_g1.mkv",
            duration: 3.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"],
            audioCodec: nil)
        let g1CSV = try TrimTestProbe.keyframeFlagCSV(g1)
        #expect(TrimKeyframeProbe.allSampledPacketsAreKeyframes(csv: g1CSV) == true,
                "-g 1 ffv1 (the Preservation preset's recipe) must probe as all-keyframes")
    }
}
