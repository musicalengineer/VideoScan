// ArchiveAngelTestbed.swift
// The Archive Angel performance testbed (Rick 2026-09-19: "build a small
// testbed that tries mimicking various AA activities so we can get real
// numbers and find where the dials are for better performance" — after
// robustness). Opt-in: runs only with VIDEOSCAN_ANGEL_TESTBED=1
// (scripts/angel_testbed.py sets it).
//
// What it does: makes synthetic 1080p fixtures across the media matrix
// (mp4/h264+aac, mov/prores+pcm, mkv/ffv1+pcm, mxf/mpeg2+pcm, avi/dv+pcm)
// plus a one-sided-audio clip that exercises Balance — cached, no personal
// media — and runs each through a real production ArchiveAngelJob (one
// file per job, lossless as configured). It records per-step seconds (from
// the plan's StepOutcome.seconds), the job's wall time, the realtime
// factor (media seconds ÷ processing seconds) and the test host's peak
// RSS, and writes report.json + report.md under
// ~/Library/Logs/VideoScan/angel-testbed/<runID>/.
//
// Knobs (environment; xcodebuild needs the TEST_RUNNER_ prefix):
//   VIDEOSCAN_ANGEL_TESTBED=1            enable
//   VIDEOSCAN_ANGEL_TESTBED_SECONDS=30,120   clip lengths (default 30)
//   VIDEOSCAN_ANGEL_TESTBED_LOSSLESS=0   lossless off (default on)
//   VIDEOSCAN_ANGEL_TESTBED_FORMATS=mp4,mov   subset (default all)
//   VIDEOSCAN_ANGEL_TESTBED_RUN_ID=name  (default a timestamp)

import Darwin
import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — performance testbed (opt-in)", .serialized)
@MainActor
struct ArchiveAngelTestbed {
    struct Format: Sendable {
        let key: String
        let ext: String
        let size: String
        let rate: String
        let video: [String]
        let audio: [String]
        var audioFilter: [String] = []
        var catalogCodec: String
    }

    static let formats: [Format] = [
        .init(key: "mp4", ext: "mp4", size: "1920x1080", rate: "30",
              video: ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac", "-ac", "2"],
              catalogCodec: "h264"),
        .init(key: "mov", ext: "mov", size: "1920x1080", rate: "30",
              video: ["-c:v", "prores_ks", "-profile:v", "2"], audio: ["-c:a", "pcm_s16le", "-ac", "2"],
              catalogCodec: "prores"),
        .init(key: "mkv", ext: "mkv", size: "1920x1080", rate: "30",
              video: ["-c:v", "ffv1", "-level", "3"], audio: ["-c:a", "pcm_s16le", "-ac", "2"],
              catalogCodec: "ffv1"),
        .init(key: "mxf", ext: "mxf", size: "1920x1080", rate: "30000/1001",
              video: ["-c:v", "mpeg2video", "-b:v", "25M", "-pix_fmt", "yuv422p"],
              audio: ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"], catalogCodec: "mpeg2video"),
        .init(key: "avi", ext: "avi", size: "720x480", rate: "30000/1001",
              video: ["-c:v", "dvvideo", "-pix_fmt", "yuv411p"], audio: ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"],
              catalogCodec: "dvvideo"),
        // Left channel only — the Angel's Balance step has real work.
        .init(key: "mp4-leftonly", ext: "mp4", size: "1920x1080", rate: "30",
              video: ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"],
              audioFilter: ["-af", "pan=stereo|c0=c0|c1=0*c0"], catalogCodec: "h264"),
    ]

    struct Row: Codable {
        var format: String
        var mediaSeconds: Double
        var sizeBytes: Int64
        var status: String
        var failure: String?
        var stepSeconds: [String: Double] = [:]
        var stepStates: [String: String] = [:]
        var jobSeconds: Double = 0
        var realtimeFactor: Double = 0
        var peakRSSBytes: Int64?
    }

    struct Report: Codable {
        var runID: String
        var machine: String
        var lossless: Bool
        var startedAt: Date
        var rows: [Row] = []
    }

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func csv(_ key: String) -> [String]? {
        env[key].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let mem = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "\(String(cString: model)) · \(ProcessInfo.processInfo.activeProcessorCount) cores · \(mem) GB"
    }

    /// Fixtures are cached across runs (same name = same content).
    static func fixture(_ f: Format, seconds: Int, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("test_bed_\(f.key)_\(seconds)s.\(f.ext)")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let tone = "sine=frequency=440:duration=\(seconds):sample_rate=48000"
        let partial = dir.appendingPathComponent("partial_" + url.lastPathComponent)
        let r = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc2=size=\(f.size):rate=\(f.rate):duration=\(seconds)",
                        "-f", "lavfi", "-i", tone]
                + f.video + f.audio + f.audioFilter + ["-shortest", partial.path],
            deadlineSeconds: 3600)
        guard r.exitCode == 0 else { throw TestbedError.fixture("\(f.key): \(FFmpegEncodeCheck.stderrTail(r.stderr))") }
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }

    enum TestbedError: Error { case fixture(String) }

    @Test("Angel steps timed across the media matrix",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_ANGEL_TESTBED"] == "1"))
    func timeTheMatrix() async throws {
        let fm = FileManager.default
        let runID = Self.env["VIDEOSCAN_ANGEL_TESTBED_RUN_ID"]
            ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let lossless = Self.env["VIDEOSCAN_ANGEL_TESTBED_LOSSLESS"] != "0"
        let lengths = (Self.csv("VIDEOSCAN_ANGEL_TESTBED_SECONDS") ?? ["30"]).compactMap(Int.init)
        let wanted = Set(Self.csv("VIDEOSCAN_ANGEL_TESTBED_FORMATS") ?? Self.formats.map(\.key))
        // codex #1572: an empty or misspelled matrix used to run zero rows
        // and pass. The matrix must be non-empty, known formats, ≥ 8 s clips.
        try #require(!lengths.isEmpty && lengths.allSatisfy { $0 >= 8 },
                     "VIDEOSCAN_ANGEL_TESTBED_SECONDS must be integers ≥ 8: \(Self.env["VIDEOSCAN_ANGEL_TESTBED_SECONDS"] ?? "")")
        let known = Set(Self.formats.map(\.key))
        try #require(!wanted.isEmpty && wanted.isSubset(of: known),
                     "VIDEOSCAN_ANGEL_TESTBED_FORMATS must be a non-empty subset of \(known.sorted()): \(wanted.sorted())")
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan/angel-testbed")
        let out = logs.appendingPathComponent(runID, isDirectory: true)
        let fixtures = logs.appendingPathComponent("fixtures", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)

        var report = Report(runID: runID, machine: Self.machine(), lossless: lossless, startedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        for seconds in lengths {
            for f in Self.formats where wanted.contains(f.key) {
                var row = Row(format: f.key, mediaSeconds: Double(seconds), sizeBytes: 0, status: "not run")
                do {
                    let src = try await Self.fixture(f, seconds: seconds, in: fixtures)
                    row.sizeBytes = ((try? fm.attributesOfItem(atPath: src.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    let work = out.appendingPathComponent("\(f.key)_\(seconds)s", isDirectory: true)
                    let sb = MasterArchiveTestSupport.Sandbox(root: work, sources: work.appendingPathComponent("Sources"),
                                                              archiveVolume: work.appendingPathComponent("Archive"))
                    try fm.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
                    let model = MasterArchiveTestSupport.makeModel(sb)
                    model.scanTargets = []
                    model.previewSweep.stop()
                    model.archiveAngelSweep.stop()
                    model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                                   rootPath: sb.archiveRoot.path, volumeUUID: nil)
                    let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1995", starRating: 2)
                    rec.durationSeconds = Double(max(seconds, 600))   // scorer floor; encoders probe the real file
                    rec.videoCodec = f.catalogCodec
                    rec.audioCodec = f.audio[1]
                    rec.isPlayable = "Yes"
                    model.records = [rec]
                    let buffer = work.appendingPathComponent("Buffer", isDirectory: true)
                    try fm.createDirectory(at: buffer, withIntermediateDirectories: true)
                    // Held for the whole job: the job keeps its center weakly,
                    // and an inline center is gone before preparation starts.
                    let center = MediaFileOperationsCenter()
                    let job = ArchiveAngelJob(model: model, center: center, count: 1,
                                              makeLossless: lossless, bufferRoot: buffer, explicitRecordIDs: [rec.id])
                    let clock = ContinuousClock()
                    let started = clock.now
                    job.start()
                    await job.task?.value
                    withExtendedLifetime(center) {}
                    let elapsed = clock.now - started
                    row.jobSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    row.realtimeFactor = row.jobSeconds > 0 ? Double(seconds) / row.jobSeconds : 0
                    if let entry = job.plan.entries.first {
                        row.status = entry.status.rawValue
                        row.failure = entry.failure
                        for s in entry.steps {
                            row.stepStates[s.kind.rawValue] = s.state.rawValue
                            if let t = s.seconds { row.stepSeconds[s.kind.rawValue] = t }
                            // A done step must have left its file (codex #1572).
                            if s.state == .done, let rel = s.outputRelPath,
                               !fm.fileExists(atPath: URL(fileURLWithPath: job.plan.batchDir).appendingPathComponent(rel).path) {
                                row.stepStates[s.kind.rawValue] = ArchiveAngelPlan.StepState.failed.rawValue
                                row.failure = (row.failure ?? "") + " \(s.kind.rawValue): output missing"
                            }
                        }
                    } else {
                        row.status = "not picked"
                        row.failure = job.plan.log.last
                    }
                } catch {
                    row.status = "error"
                    row.failure = String(describing: error)
                }
                var usage = rusage()
                if getrusage(RUSAGE_SELF, &usage) == 0 { row.peakRSSBytes = Int64(usage.ru_maxrss) }
                report.rows.append(row)
                // Written after every row: a crash or timeout keeps what ran.
                try encoder.encode(report).write(to: out.appendingPathComponent("report.json"), options: .atomic)
                try Self.markdown(report).write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
                appLog.write("Angel testbed \(runID): \(f.key) \(seconds)s — \(row.status), "
                             + String(format: "%.1f s (%.2f× realtime)", row.jobSeconds, row.realtimeFactor))
            }
        }
        #expect(report.rows.count == lengths.count * wanted.count, "every cell of the matrix ran")
        // codex #1572: a row is only green when the row is ready AND no
        // step failed (a failed lossless copy beside a ready original used
        // to pass) AND every done step left a companion in the buffer.
        let failed = report.rows.filter { row in
            row.status != AngelStatus.ready
                || row.stepStates.values.contains(ArchiveAngelPlan.StepState.failed.rawValue)
                || row.stepStates.isEmpty
        }
        #expect(failed.isEmpty, "not ready: \(failed.map { "\($0.format): \($0.status) \($0.stepStates) \($0.failure ?? "")" })")
    }

    enum AngelStatus { static let ready = ArchiveAngelPlan.EntryStatus.ready.rawValue }

    /// The table Rick reads: one row per fixture, seconds per step.
    static func markdown(_ r: Report) -> String {
        let steps = ArchiveAngelPlan.StepKind.allCases
        var s = "# Archive Angel testbed — \(r.runID)\n\n\(r.machine) · lossless \(r.lossless ? "on" : "off")\n\n"
        s += "| format | media | size | " + steps.map { ArchiveAngelStepPresentation.columnTitle($0) }.joined(separator: " | ")
            + " | job | × realtime | peak RSS | status |\n"
        s += "|" + String(repeating: "---|", count: 7 + steps.count) + "\n"
        for row in r.rows {
            let cells = steps.map { k -> String in
                let state = row.stepStates[k.rawValue] ?? "—"
                guard let t = row.stepSeconds[k.rawValue] else { return state }
                return String(format: "%.1f s", t) + (state == "done" ? "" : " (\(state))")
            }
            s += "| \(row.format) | \(Int(row.mediaSeconds)) s | "
                + ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file) + " | "
                + cells.joined(separator: " | ")
                + String(format: " | %.1f s | %.2f× | ", row.jobSeconds, row.realtimeFactor)
                + (row.peakRSSBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—")
                + " | \(row.status)\(row.failure.map { " — \($0)" } ?? "") |\n"
        }
        return s
    }

    @Test func theTableHasOneRowPerFixtureAndMarksUnfinishedSteps() {
        var report = Report(runID: "t", machine: "m", lossless: true, startedAt: Date())
        report.rows = [Row(format: "mov", mediaSeconds: 30, sizeBytes: 1_000_000, status: "ready",
                           stepSeconds: ["verifyAudio": 1.5, "accessCopy": 12.25],
                           stepStates: ["verifyAudio": "done", "balanceAudio": "skipped", "accessCopy": "done",
                                        "losslessCopy": "skipped"],
                           jobSeconds: 15, realtimeFactor: 2)]
        let md = Self.markdown(report)
        #expect(md.contains("| mov | 30 s |"))
        #expect(md.contains("1.5 s | skipped | 12.2 s"), Comment(rawValue: md))
        #expect(md.contains("15.0 s | 2.00× |"))
    }
}
