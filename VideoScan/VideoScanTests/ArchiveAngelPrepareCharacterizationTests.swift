// ArchiveAngelPrepareCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/angel-prepare, 2026-11-08): pins what
// `ArchiveAngelJob.prepare(index:record:entryDir:position:total:)` records
// for one file — every step's state, note, output and companion link, the
// entry's status, and the job's own log lines — across the branches of its
// four steps, on real (tiny, synthetic) media, so splitting it into its
// steps (verify audio → balanced audio → access copy → lossless copy) can be
// shown to change nothing. The golden was recorded on the unchanged code.
//
// Scenarios (one batch each, explicit picks, Debug, ffmpeg from Homebrew):
//   clean        h264/aac stereo (the same tone both sides), lossless off
//   videoOnly    no audio track (verify and balance skipped as such)
//   verified     sound already checked this launch (the cached diagnosis)
//   oneSided     sound on the left only → Balance Audio runs, the access copy
//                is cut from the balanced companion
//   mono         one-channel sound → Balance Audio runs (mono)
//   reuse        a catalogued Balance Audio output linked to the original →
//                reused, never re-balanced
//   nominated    a same-name `_balanced` file NOT linked → named in Review,
//                never used
//   losslessRisk lossless on, an at-risk format → FFV1 preservation copy
//   losslessFine lossless on, a preservation-safe format → not needed
//   noCenter     the operations center went away → "cannot prepare"
//
// Normalized: step timings and the batch folder's timestamp; paths are the
// last component. Re-record only on purpose: delete the golden, run twice.
// Re-recorded 2026-11-11 on main's unsplit prepare (before the merge of the split):
// the `verified` scenario only — its fixture now runs the real sound check.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveAngelJob.prepare — characterization (real media, golden)", .serialized)
@MainActor
struct ArchiveAngelPrepareCharacterizationTests {
    static let ffmpeg = ToolLocator.ffmpegPath

    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ArchiveAngel/prepare.golden.txt")
    }

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
        model.archiveAngel.sweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    /// A 4-second clip. `audio` = ffmpeg args for the sound (nil = none).
    private func clip(_ name: String, in dir: URL, audio: [String]? = ["-c:a", "aac", "-ac", "2"],
                      audioFilter: [String] = []) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        var args = ["-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4"]
        if audio != nil { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=4"] }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] + audioFilter + (audio ?? ["-an"]) + ["-shortest", url.path]
        let r = await ProcessRunner.runProcess(executable: Self.ffmpeg, arguments: args, deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture \(name): \(r.stderr)")
        return url
    }

    private func record(_ url: URL, codec: String = "h264", streamType: StreamType = .videoAndAudio) -> VideoRecord {
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, streamType: streamType, userDate: "1995", starRating: 2)
        r.durationSeconds = 600
        r.videoCodec = codec
        r.audioCodec = streamType == .videoOnly ? "" : "aac"
        r.isPlayable = "Yes"
        return r
    }

    /// The job, end to end, over `records` (explicit picks).
    private func run(_ b: Bench, _ records: [VideoRecord], picks: [VideoRecord]? = nil,
                     lossless: Bool = false) async -> ArchiveAngelJob {
        b.model.records = records
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: (picks ?? records).count,
                                  makeLossless: lossless, bufferRoot: b.buffer,
                                  explicitRecordIDs: (picks ?? records).map(\.id))
        job.start()
        await job.task?.value
        return job
    }

    static func normalize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"\(\d+\.\d+ s\)"#, with: "(t s)", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\(\d+\.\d+ s, [^)]*\)"#, with: "(t s, size)", options: .regularExpression)
        out = out.replacingOccurrences(of: #"batch-\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d"#, with: "batch-T", options: .regularExpression)
        out = out.replacingOccurrences(of: #"/[^ ]*/"#, with: "…/", options: .regularExpression)
        return out
    }

    /// What prepare left for each entry, plus the job's log lines about it.
    static func describe(_ name: String, _ job: ArchiveAngelJob) -> [String] {
        var lines = ["== \(name): job \(Self.state(job))"]
        for e in job.plan.entries {
            lines.append("entry \(e.filename) status \(e.status) failure \(e.failure.map(normalize) ?? "-")"
                         + " nomination \(e.balancedNomination.map { ($0 as NSString).lastPathComponent } ?? "-")")
            for s in e.steps {
                lines.append("  step \(s.kind) \(s.state) | \(normalize(s.note)) | out \(s.outputRelPath.map { ($0 as NSString).lastPathComponent } ?? "-")"
                             + " | rec \(s.recordID == nil ? "-" : "yes") | existing \(s.existingPath.map { ($0 as NSString).lastPathComponent } ?? "-")")
            }
        }
        for l in job.plan.log where l.contains("Archive Angel") && !l.contains("Archive Angel: picked") {
            lines.append("  log \(normalize(l))")
        }
        return lines
    }

    static func state(_ job: ArchiveAngelJob) -> String {
        switch job.state {
        case .finished: return "finished"
        case .failed(let m): return "failed(\(normalize(m)))"
        case .cancelled: return "cancelled"
        default: return "\(job.state)"
        }
    }

    // MARK: scenarios

    private func clean() async throws -> [String] {
        let b = try bench("prepchar_clean"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_clean.mp4", in: b.sb.sources)
        return Self.describe("clean", await run(b, [record(a)]))
    }

    private func mono() async throws -> [String] {
        let b = try bench("prepchar_mono"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_mono.mp4", in: b.sb.sources, audio: ["-c:a", "aac", "-ac", "1"])
        return Self.describe("mono", await run(b, [record(a)]))
    }

    private func videoOnly() async throws -> [String] {
        let b = try bench("prepchar_vo"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_silent.mp4", in: b.sb.sources, audio: nil)
        return Self.describe("videoOnly", await run(b, [record(a, streamType: .videoOnly)]))
    }

    private func verified() async throws -> [String] {
        let b = try bench("prepchar_verified"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_verified.mp4", in: b.sb.sources)
        let rec = record(a)
        b.model.records = [rec]
        // The REAL probe (merge of 2026-11-11): since #467/#468 a diagnosis with no
        // measurement is "not checked" and stores nothing, so an injected empty one
        // no longer reaches the "Already verified" branch. A measured verify does.
        let vj = try #require(b.center.startVerifyAudio(record: rec, model: b.model))
        await vj.task?.value
        try #require(rec.audioVerifyStatus == "ok", "the fixture's own verify must store ok: '\(rec.audioVerifyStatus)'")
        return Self.describe("verified (status \(rec.audioVerifyStatus))", await run(b, [rec]))
    }

    private func oneSided() async throws -> [String] {
        let b = try bench("prepchar_onesided"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_left.mov", in: b.sb.sources, audio: ["-c:a", "aac", "-ac", "2"],
                               audioFilter: ["-af", "pan=stereo|c0=c0|c1=0*c0"])
        return Self.describe("oneSided", await run(b, [record(a)]))
    }

    private func reuse() async throws -> [String] {
        let b = try bench("prepchar_reuse"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_reuse.mp4", in: b.sb.sources)
        let bal = try await clip("test_pc_reuse_balanced.mp4", in: b.sb.sources)
        let orig = record(a)
        let copy = record(bal)
        copy.derivedFrom = orig.id
        copy.derivationKind = BalanceAudioFix.derivationKind
        return Self.describe("reuse", await run(b, [orig, copy], picks: [orig]))
    }

    private func nominated() async throws -> [String] {
        let b = try bench("prepchar_nominated"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_nom.mp4", in: b.sb.sources)
        let bal = try await clip("test_pc_nom_balanced.mp4", in: b.sb.sources)
        let orig = record(a)
        return Self.describe("nominated", await run(b, [orig, record(bal)], picks: [orig]))
    }

    private func lossless(_ codec: String, _ name: String) async throws -> [String] {
        let b = try bench("prepchar_\(name)"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_\(name).mp4", in: b.sb.sources)
        return Self.describe(name, await run(b, [record(a, codec: codec)], lossless: true))
    }

    /// The operations center goes away as soon as the job starts (the job
    /// holds it weakly): nothing may be marked ready.
    private func noCenter() async throws -> [String] {
        let b = try bench("prepchar_nocenter"); defer { b.sb.cleanup() }
        let a = try await clip("test_pc_nocenter.mp4", in: b.sb.sources)
        let rec = record(a)
        b.model.records = [rec]
        let job = ArchiveAngelJob(model: b.model, center: MediaFileOperationsCenter(), count: 1, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: [rec.id])   // center released at once
        job.start()
        await job.task?.value
        return Self.describe("noCenter", job)
    }

    /// Merge review 2026-11-11: the golden records the access copy's NOTE, not
    /// what it was cut from — "let accessSource = rec" passed every Angel suite.
    /// The catalogued access copy is derived from the balanced companion when
    /// Balance Audio made one, and from the original when it did not.
    @Test func theAccessCopyIsCutFromTheBalancedCompanionWhenThereIsOne() async throws {
        func accessSource(_ label: String, _ name: String, filter: [String]) async throws -> (source: UUID?, balanced: UUID?, original: UUID) {
            let b = try bench(label); defer { b.sb.cleanup() }
            let a = try await clip(name, in: b.sb.sources, audio: ["-c:a", "aac", "-ac", "2"], audioFilter: filter)
            let rec = record(a)
            let job = await run(b, [rec])
            let steps = try #require(job.plan.entries.first).steps
            let accessID = try #require(steps.first { $0.kind == .accessCopy }?.recordID, "no access copy catalogued (\(label))")
            let access = try #require(b.model.records.first { $0.id == accessID })
            return (access.derivedFrom, steps.first { $0.kind == .balanceAudio }?.recordID, rec.id)
        }
        let oneSided = try await accessSource("prepchar_src_left", "test_pc_src_left.mov", filter: ["-af", "pan=stereo|c0=c0|c1=0*c0"])
        let balanced = try #require(oneSided.balanced, "Balance Audio made no companion for one-sided sound")
        #expect(oneSided.source == balanced, "the access copy was not cut from the balanced companion")
        #expect(oneSided.source != oneSided.original)
        let clean = try await accessSource("prepchar_src_clean", "test_pc_src_clean.mp4", filter: [])
        #expect(clean.balanced == nil)
        #expect(clean.source == clean.original, "with no balanced companion the access copy is cut from the original")
    }

    @Test func everyScenarioRecordsAsBefore() async throws {
        var lines: [String] = []
        lines += try await clean()
        lines += try await mono()
        lines += try await videoOnly()
        lines += try await verified()
        lines += try await oneSided()
        lines += try await reuse()
        lines += try await nominated()
        lines += try await lossless("dvvideo", "losslessRisk")
        lines += try await lossless("h264", "losslessFine")
        lines += try await noCenter()
        let url = Self.goldenURL
        guard let golden = try? String(contentsOf: url, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            Issue.record("golden recorded at \(url.path) — run again to compare")
            return
        }
        let expected = golden.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(expected.count == lines.count, "line count \(lines.count) vs golden \(expected.count)")
        for (got, want) in zip(lines, expected) where got != want {
            Issue.record("changed:\n  was: \(want)\n  now: \(got)")
        }
    }
}
