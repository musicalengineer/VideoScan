// ArchiveAngelWholeJobTests.swift
// Whole Archive Angel jobs on real (tiny, synthetic) media, with failures
// injected mid-batch (2026-09-19 robustness pass — Rick: "First Robustness
// then Performance"; every action tested and logged). Each test runs the
// production ArchiveAngelJob end to end in a sandbox: pick → prepare →
// settle, on 4-second clips made here with ffmpeg (test_ prefix). Nothing
// touches Rick's media, buffer or catalog.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — whole jobs on real media, failures injected", .serialized)
@MainActor
struct ArchiveAngelWholeJobTests {
    static let ffmpeg = ToolLocator.ffmpegPath

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let center: MediaFileOperationsCenter
        let buffer: URL
    }

    private func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngelSweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    /// A 4-second clip (test pattern + tone). `ext`/`codec` pick the format.
    private func clip(_ name: String, in dir: URL, videoCodec: [String] = ["-c:v", "libx264", "-pix_fmt", "yuv420p"],
                      audioCodec: [String] = ["-c:a", "aac"]) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let r = await ProcessRunner.runProcess(
            executable: Self.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=4"]
                + videoCodec + audioCodec + ["-shortest", url.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture \(name): \(r.stderr)")
        return url
    }

    /// A catalog record the Angel will pick: rated, dated, playable, and
    /// long enough on paper for the scorer (the file itself is 4 s; every
    /// length check in the encoders probes the real file).
    private func record(_ url: URL, codec: String = "h264") -> VideoRecord {
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "1995", starRating: 2)
        r.durationSeconds = 600
        r.videoCodec = codec
        r.audioCodec = "aac"
        r.isPlayable = "Yes"
        return r
    }

    private func run(_ b: Bench, _ records: [VideoRecord]) async -> ArchiveAngelJob {
        b.model.records = records
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: records.count, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: records.map(\.id))
        job.start()
        await job.task?.value
        return job
    }

    @Test func aCleanBatchPreparesEveryFileAndTimesEveryStep() async throws {
        let b = try bench("wholejob_ok"); defer { b.sb.cleanup() }
        let a = try await clip("test_wj_a.mp4", in: b.sb.sources)
        let job = await run(b, [record(a)])
        guard case .finished = job.state else { Issue.record("\(job.state) — \(job.plan.log.suffix(5))"); return }
        let entry = try #require(job.plan.entries.first)
        #expect(entry.status == .ready, "\(entry.status) \(entry.failure ?? "")")
        let access = try #require(entry.steps.first { $0.kind == .accessCopy })
        #expect(access.state == .done)
        #expect((access.seconds ?? 0) > 0, "per-step timing recorded")
        // Durable: the plan on disk carries the timings too.
        let onDisk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
        #expect(onDisk.entries.first?.steps.first { $0.kind == .accessCopy }?.seconds != nil)
        // And every step left a log line in the batch's own log.
        #expect(job.plan.log.contains { $0.contains("access copy: done") }, "\(job.plan.log)")
    }

    @Test func aSourceThatVanishesIsNamedAndTheBatchGoesOn() async throws {
        let b = try bench("wholejob_vanish"); defer { b.sb.cleanup() }
        let a = try await clip("test_wj_keep.mp4", in: b.sb.sources)
        let gone = try await clip("test_wj_gone.mp4", in: b.sb.sources)
        let recs = [record(a), record(gone)]
        try FileManager.default.removeItem(at: gone)   // unplugged before its turn
        let job = await run(b, recs)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let byName = Dictionary(uniqueKeysWithValues: job.plan.entries.map { ($0.filename, $0) })
        #expect(byName["test_wj_keep.mp4"]?.status == .ready)
        let lost = try #require(byName["test_wj_gone.mp4"], "picked: explicit picks do not check the disk")
        #expect(lost.status == .failed)
        #expect(lost.failure?.contains("isn't at") == true, "\(lost.failure ?? "")")
        #expect(job.plan.log.contains { $0.contains("test_wj_gone.mp4 — not prepared") }, "logged, not silent")
    }

    @Test func ffmpegFailingOnOneFileFailsThatStepOnly() async throws {
        let b = try bench("wholejob_boom"); defer { b.sb.cleanup() }
        let ok = try await clip("test_wj_fine.mp4", in: b.sb.sources)
        let boom = try await clip("test_wj_boom.mp4", in: b.sb.sources)
        // Pass-through fake: fails only for test_wj_boom (see FFmpegEncodeCheckTests).
        let fake = b.sb.root.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        case "$*" in *-i*test_wj_boom.mp4*) ;; *) exec "\(Self.ffmpeg)" "$@" ;; esac
        for out; do :; done
        head -c 20000 /dev/zero > "$out"
        echo "Error while decoding stream #0:0: Invalid data found when processing input" >&2
        exit 69
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)
        defer { unsetenv(ToolLocator.ffmpegEnvVar) }
        let job = await run(b, [record(ok), record(boom)])
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let byName = Dictionary(uniqueKeysWithValues: job.plan.entries.map { ($0.filename, $0) })
        #expect(byName["test_wj_fine.mp4"]?.steps.first { $0.kind == .accessCopy }?.state == .done)
        let failed = try #require(byName["test_wj_boom.mp4"]?.steps.first { $0.kind == .accessCopy })
        #expect(failed.state == .failed, "a failed encode was reported \(failed.state)")
        #expect(failed.note.contains("exit code 69"), "\(failed.note)")
    }

    /// Audit #5 end to end: the disk fills after the first saves — the job
    /// fails with the reason, stops, and never reports "N ready".
    @Test func aPlanSaveFailingMidBatchStopsTheBatchAndIsNeverReportedAsSuccess() async throws {
        let b = try bench("wholejob_diskfull"); defer { b.sb.cleanup() }
        let x = try await clip("test_wj_x.mp4", in: b.sb.sources)
        let y = try await clip("test_wj_y.mp4", in: b.sb.sources)
        ArchiveAngelPlanWriter.injectedFailure = (batchNameContains: b.buffer.path, afterWrites: 3)
        defer { ArchiveAngelPlanWriter.injectedFailure = nil }
        let job = await run(b, [record(x), record(y)])
        guard case .failed(let reason) = job.state else {
            Issue.record("a failed plan save ended as \(job.state)"); return
        }
        #expect(reason.contains("Could not write plan.json"), "\(reason)")
        #expect(job.plan.entries.filter { $0.status == .preparing || $0.status == .pending }.count >= 1,
                "the batch stopped rather than preparing everything")
    }
}
