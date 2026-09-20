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
        /// The Balance step must DO work on this fixture (one-sided audio).
        var expectsBalance: Bool = false

        /// The steps a green row must have completed (`.done`), for this
        /// fixture and the run's lossless setting. Verify and the access
        /// copy always; the lossless copy when it is on; Balance when the
        /// fixture's audio is one-sided.
        func expectedDoneSteps(lossless: Bool) -> [ArchiveAngelPlan.StepKind] {
            var steps: [ArchiveAngelPlan.StepKind] = [.verifyAudio, .accessCopy]
            if lossless { steps.append(.losslessCopy) }
            if expectsBalance { steps.append(.balanceAudio) }
            return steps
        }
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
              audioFilter: ["-af", "pan=stereo|c0=c0|c1=0*c0"], catalogCodec: "h264", expectsBalance: true),
    ]

    struct Row: Codable {
        var format: String
        var mediaSeconds: Double
        var sizeBytes: Int64
        var status: String
        var failure: String?
        /// The JOB's terminal state ("finished" / "failed: …" / "cancelled"):
        /// a ready row under a failed job — the final plan save failed —
        /// is not green (codex review 2026-09-20, test integrity).
        var jobState: String = "not run"
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

    enum TestbedError: Error, Equatable { case fixture(String), badLength(String) }

    @Test("Angel steps timed across the media matrix",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_ANGEL_TESTBED"] == "1"))
    func timeTheMatrix() async throws {
        let fm = FileManager.default
        let runID = Self.env["VIDEOSCAN_ANGEL_TESTBED_RUN_ID"]
            ?? ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let lossless = Self.env["VIDEOSCAN_ANGEL_TESTBED_LOSSLESS"] != "0"
        let lengthTokens = Self.csv("VIDEOSCAN_ANGEL_TESTBED_SECONDS") ?? ["30"]
        let lengths = try Self.parseLengths(lengthTokens)
        let wanted = Set(Self.csv("VIDEOSCAN_ANGEL_TESTBED_FORMATS") ?? Self.formats.map(\.key))
        // codex #1572: an empty or misspelled matrix used to run zero rows
        // and pass. The matrix must be non-empty, known formats, ≥ 8 s clips.
        try #require(!lengths.isEmpty, "VIDEOSCAN_ANGEL_TESTBED_SECONDS is empty")
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
                    row.jobState = Self.stateText(job.state)
                    if let entry = job.plan.entries.first {
                        row.status = entry.status.rawValue
                        row.failure = entry.failure
                        for s in entry.steps {
                            row.stepStates[s.kind.rawValue] = s.state.rawValue
                            if let t = s.seconds { row.stepSeconds[s.kind.rawValue] = t }
                            // A done step must have left a real, nonempty file
                            // (codex #1572; review 2026-09-20: not a symlink, not
                            // empty, and never "done" with no output at all).
                            if s.state == .done,
                               let why = Self.outputProblem(s, batchDir: job.plan.batchDir, fm: fm) {
                                row.stepStates[s.kind.rawValue] = ArchiveAngelPlan.StepState.failed.rawValue
                                row.failure = (row.failure ?? "") + " \(s.kind.rawValue): \(why)"
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
        // codex #1572 + review 2026-09-20: a row is only green when the JOB
        // finished, the row is ready, EVERY expected step is done (a
        // skipped access copy or a pending lossless copy is not a pass),
        // no step failed, and every done step left a real companion.
        let byKey = Dictionary(uniqueKeysWithValues: Self.formats.map { ($0.key, $0) })
        let failed = report.rows.filter { row in
            guard let f = byKey[row.format] else { return true }
            return Self.rowProblem(row, expected: f.expectedDoneSteps(lossless: lossless)) != nil
        }
        let reasons = failed.map { row -> String in
            let why = byKey[row.format].map { Self.rowProblem(row, expected: $0.expectedDoneSteps(lossless: lossless)) ?? "" } ?? "unknown format"
            return "\(row.format): \(why) — job \(row.jobState), row \(row.status) \(row.stepStates) \(row.failure ?? "")"
        }
        #expect(failed.isEmpty, "not green: \(reasons)")
    }

    enum AngelStatus { static let ready = ArchiveAngelPlan.EntryStatus.ready.rawValue }

    /// Why a row is not green, or nil. Pure, so the rule itself is tested.
    static func rowProblem(_ row: Row, expected: [ArchiveAngelPlan.StepKind]) -> String? {
        if row.jobState != "finished" { return "job \(row.jobState)" }
        if row.status != AngelStatus.ready { return "row \(row.status)" }
        if row.stepStates.isEmpty { return "no steps recorded" }
        let failedSteps = row.stepStates.filter { $0.value == ArchiveAngelPlan.StepState.failed.rawValue }.keys.sorted()
        if !failedSteps.isEmpty { return "failed: \(failedSteps.joined(separator: ", "))" }
        let notDone = expected.filter { row.stepStates[$0.rawValue] != ArchiveAngelPlan.StepState.done.rawValue }
        if !notDone.isEmpty {
            return "expected done but " + notDone.map { "\($0.rawValue)=\(row.stepStates[$0.rawValue] ?? "absent")" }.joined(separator: ", ")
        }
        return nil
    }

    /// Why a done step's output is not acceptable, or nil. Verify leaves
    /// no file; every other done step must name a nonempty REGULAR file.
    static func outputProblem(_ step: ArchiveAngelPlan.StepOutcome, batchDir: String, fm: FileManager) -> String? {
        guard step.kind != .verifyAudio else { return nil }
        guard let rel = step.outputRelPath, !rel.isEmpty else { return "done with no output path" }
        let path = URL(fileURLWithPath: batchDir).appendingPathComponent(rel).path
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return "output missing" }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else { return "output is not a regular file" }
        guard ((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { return "output is empty" }
        return nil
    }

    static func stateText(_ state: MediaFileOperationState) -> String {
        switch state {
        case .finished: return "finished"
        case .failed(let message): return "failed: \(message)"
        case .cancelled: return "cancelled"
        case .cancelling: return "cancelling"
        case .running: return "running"
        }
    }

    /// Every token must be an integer ≥ 8; one bad token rejects the whole
    /// list (review 2026-09-20: `compactMap` used to drop it silently).
    static func parseLengths(_ tokens: [String]) throws -> [Int] {
        var out: [Int] = []
        for t in tokens {
            guard let n = Int(t), n >= 8 else { throw TestbedError.badLength(t) }
            out.append(n)
        }
        return out
    }

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

    @Test("a duration list with one bad token is rejected whole — never silently thinned")
    func badDurationTokenRejectsTheList() throws {
        #expect(try Self.parseLengths(["30", "120"]) == [30, 120])
        #expect(throws: TestbedError.badLength("abc")) { try Self.parseLengths(["30", "abc", "120"]) }
        #expect(throws: TestbedError.badLength("4")) { try Self.parseLengths(["4", "30"]) }
        #expect(throws: TestbedError.badLength("")) { try Self.parseLengths([""]) }
    }

    @Test("green needs a finished job, a ready row, every expected step done, nothing failed")
    func greenRuleIsStrict() {
        let expected: [ArchiveAngelPlan.StepKind] = [.verifyAudio, .accessCopy, .losslessCopy]
        var row = Row(format: "mov", mediaSeconds: 30, sizeBytes: 1, status: "ready", jobState: "finished",
                      stepStates: ["verifyAudio": "done", "balanceAudio": "skipped", "accessCopy": "done", "losslessCopy": "done"])
        #expect(Self.rowProblem(row, expected: expected) == nil)
        row.jobState = "failed: Could not write plan.json"
        #expect(Self.rowProblem(row, expected: expected)?.hasPrefix("job failed") == true, "a ready row under a failed job is red")
        row.jobState = "finished"; row.stepStates["accessCopy"] = "skipped"
        #expect(Self.rowProblem(row, expected: expected)?.contains("accessCopy=skipped") == true, "a skipped expected step is red")
        row.stepStates["accessCopy"] = "done"; row.stepStates["losslessCopy"] = "pending"
        #expect(Self.rowProblem(row, expected: expected)?.contains("losslessCopy=pending") == true)
        row.stepStates["losslessCopy"] = "done"; row.stepStates.removeValue(forKey: "verifyAudio")
        #expect(Self.rowProblem(row, expected: expected)?.contains("verifyAudio=absent") == true)
        row.stepStates["verifyAudio"] = "done"; row.status = "failed"
        #expect(Self.rowProblem(row, expected: expected) == "row failed")
        row.status = "ready"; row.stepStates["balanceAudio"] = "failed"
        #expect(Self.rowProblem(row, expected: expected) == "failed: balanceAudio")
        #expect(Self.rowProblem(Row(format: "x", mediaSeconds: 1, sizeBytes: 1, status: "ready", jobState: "finished"), expected: []) == "no steps recorded")
        #expect(Self.formats.first { $0.key == "mp4-leftonly" }?.expectedDoneSteps(lossless: false).contains(.balanceAudio) == true)
        #expect(Self.formats.first { $0.key == "mp4" }?.expectedDoneSteps(lossless: true) == [.verifyAudio, .accessCopy, .losslessCopy])
    }

    @Test("a done step's output must be a nonempty regular file — not missing, empty or a symlink")
    func outputRuleRejectsEmptyAndSymlinks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("test_angel_testbed_out_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        try Data(count: 10).write(to: dir.appendingPathComponent("real.mov"))
        try Data().write(to: dir.appendingPathComponent("empty.mov"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("alias.mov"), withDestinationURL: dir.appendingPathComponent("real.mov"))
        func step(_ kind: ArchiveAngelPlan.StepKind, _ out: String?) -> ArchiveAngelPlan.StepOutcome {
            ArchiveAngelPlan.StepOutcome(kind: kind, state: .done, note: "", outputRelPath: out)
        }
        #expect(Self.outputProblem(step(.accessCopy, "real.mov"), batchDir: dir.path, fm: fm) == nil)
        #expect(Self.outputProblem(step(.verifyAudio, nil), batchDir: dir.path, fm: fm) == nil, "verify leaves no file")
        #expect(Self.outputProblem(step(.accessCopy, nil), batchDir: dir.path, fm: fm) == "done with no output path")
        #expect(Self.outputProblem(step(.accessCopy, "empty.mov"), batchDir: dir.path, fm: fm) == "output is empty")
        #expect(Self.outputProblem(step(.accessCopy, "alias.mov"), batchDir: dir.path, fm: fm) == "output is not a regular file")
        #expect(Self.outputProblem(step(.losslessCopy, "gone.mov"), batchDir: dir.path, fm: fm) == "output missing")
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
