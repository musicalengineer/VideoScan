// TranscodeReplaceNegativeMatrixTests.swift — the negative matrix for one
// data-risk verb whose engine shells out: Transcode with REPLACE, which sends
// the file already at the output name to the Trash once a new derivative is
// published (TranscodeJob → FFmpegEncodeCheck → DerivativeOutputPublish).
// Rick 2026-11-20: "my mock command-exec could return errors and pretend to
// hang … which allowed for catching lots of negative test cases".
//
// Every row drives the production TranscodeJob with ffmpeg and ffprobe
// answered by a ScriptedExecutor (CommandExecutor seam) — no real media, no
// real tool: the source is placeholder bytes and the "prior" derivative a
// seeded blob. The Trash is the TaskLocal seam (never the user's Trash).
// Strict mocks: a command no rule names is a test failure.
//
// What every failure row must show (rules 1 and 2):
//   • the job ends failed/cancelled with the RIGHT reason;
//   • the prior file is untouched (same SHA-256) and nothing went to the Trash;
//   • no partial is left beside the output;
//   • the catalog is unchanged — no record for an output nobody verified.
//
// Rows: encode hang + Stop · encode hang + the stall watchdog · encode crash ·
// nonzero exit with a plausible file · launch failure · exit 0 but no output
// · and the output's length probe crashing / failing to launch / returning
// garbage — the last three are RED (see `anUnmeasurableOutputIsNeverTrustedWithAReplace`).
// A positive control proves the bench can publish and trash at all.
//
// Parallel by design (each test binds its own mock and Trash seam).

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VideoScan

@Suite("Transcode Replace — negative matrix through a scripted ffmpeg/ffprobe", .timeLimit(.minutes(1)))
@MainActor
struct TranscodeReplaceNegativeMatrixTests {

    static let sourceName = "test_negmx_tape.mov"

    final class TrashLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord
        let target: URL
        let priorSHA: String
        let fakeTrash: URL
        let trashed = TrashLog()
        var outDir: URL { target.deletingLastPathComponent() }

        /// What the catalog says, for "nothing new was recorded".
        @MainActor func catalogSnapshot() -> [String] {
            model.records.map { "\($0.fullPath)|\($0.durationSeconds)|\($0.videoCodec)|\($0.derivedFrom?.uuidString ?? "-")" }.sorted()
        }

        func partials() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).filter { $0.contains(".vs-partial.") }
        }
    }

    static func sha(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox("negmx_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        let srcURL = sb.sources.appendingPathComponent(Self.sourceName)
        _ = try MasterArchiveTestSupport.writeBlob(at: srcURL, bytes: 64 * 1024, seed: 41)   // placeholder: never decoded
        let source = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        source.durationSeconds = 12
        let outDir = sb.root.appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: source, preset: .archival)
        _ = try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 42)       // the prior derivative
        model.records = [source, MasterArchiveTestSupport.makeRecord(path: target.path)]
        let fakeTrash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, source: source, target: target, priorSHA: Self.sha(target), fakeTrash: fakeTrash)
    }

    /// ffprobe's answer for a 12 s file (`-show_entries format=duration`, nokey).
    static let twelveSeconds = ScriptedExecutor.Behaviour.output(stdout: "12.000000\n")

    /// The recorded real-ffprobe JSON for mp4/h264 (Core's checked-in
    /// fixture) — what the catalog step's full probe of a good output says.
    static func h264ProbeJSON() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../VideoScanCore/Tests/VideoScanCoreTests/Fixtures/ffprobe/h264.mp4.json").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Strict script: the encode, the two length probes, the catalog's full
    /// probe of a published output — anything else is a failure.
    func mock(_ b: Bench, encode: ScriptedExecutor.Behaviour,
              outputProbe: ScriptedExecutor.Behaviour = Self.twelveSeconds) throws -> ScriptedExecutor {
        try ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: [Self.sourceName], encode)
            .on("ffprobe", containing: ["format=duration", Self.sourceName], Self.twelveSeconds)
            .on("ffprobe", containing: ["format=duration", ".vs-partial."], outputProbe)
            .on("ffprobe", containing: ["-show_streams"], .output(stdout: Self.h264ProbeJSON()))
    }

    func run(_ b: Bench, _ mock: ScriptedExecutor,
             whileRunning: (@MainActor (TranscodeJob) async -> Void)? = nil) async -> TranscodeJob {
        let job = TranscodeJob(record: b.source, preset: .archival, outputURL: b.target, model: b.model, replaceExisting: true)
        let trashed = b.trashed, fakeTrash = b.fakeTrash
        await mock.scoped {
            await DerivativeOutputPublish.$trashItem.withValue({ url in
                trashed.add(url.path)
                let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }) {
                job.start()   // the job's Task {} inherits both task-locals
                if let whileRunning { await whileRunning(job) }
                await job.task?.value
            }
        }
        return job
    }

    /// The four invariants every refusal row shares.
    func expectRefused(_ b: Bench, _ job: TranscodeJob, catalogBefore: [String], reason wanted: [String],
                       cancelled: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        switch job.state {
        case .failed(let reason) where !cancelled:
            #expect(wanted.allSatisfy { reason.contains($0) }, "reason: \(reason)", sourceLocation: sourceLocation)
        case .cancelled where cancelled:
            break
        default:
            Issue.record("expected \(cancelled ? "cancelled" : "failed"), got \(job.state)", sourceLocation: sourceLocation)
        }
        #expect(b.trashed.all.isEmpty, "the prior file was sent to the Trash: \(b.trashed.all)", sourceLocation: sourceLocation)
        #expect(Self.sha(b.target) == b.priorSHA, "the prior file at the output name changed", sourceLocation: sourceLocation)
        #expect(b.partials().isEmpty, "a partial was left behind: \(b.partials())", sourceLocation: sourceLocation)
        #expect(b.catalogSnapshot() == catalogBefore, "the catalog recorded something for an unverified output", sourceLocation: sourceLocation)
    }

    /// Poll until the encode has been launched (the mock has seen it).
    static func waitForEncode(_ mock: ScriptedExecutor) async {
        for _ in 0..<200 where mock.calls(to: "ffmpeg").isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)   // the real child is up
    }

    // MARK: - Control

    @Test("control: a good encode publishes, the prior file goes to the (fake) Trash once with its bytes intact")
    func controlAGoodEncodeReplaces() async throws {
        let b = try bench("ok"); defer { b.sb.cleanup() }
        let m = try mock(b, encode: .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        let job = await run(b, m)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(b.trashed.all == [b.target.path])
        #expect(Self.sha(b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)) == b.priorSHA)
        #expect(Self.sha(b.target) != b.priorSHA, "the new derivative took the name")
        #expect(m.calls(to: "ffprobe", containing: ["format=duration"]).count == 2, "source and output both measured: \(m.calls)")
    }

    // MARK: - The encode fails

    @Test("encode HANGS, user presses Stop: cancelled through the real SIGTERM path; nothing trashed")
    func encodeHangThenStop() async throws {
        let b = try bench("hang_stop"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .hang(stderr: "frame=   12 fps=0.0\n"))
        let started = ContinuousClock.now
        let job = await run(b, m) { job in
            await Self.waitForEncode(m)
            job.cancel()
        }
        #expect(ContinuousClock.now - started < .seconds(10), "Stop did not stop the hung encode")
        expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
    }

    @Test("encode HANGS, the stall watchdog fires: failed as Stalled (never Cancelled); nothing trashed")
    func encodeHangThenWatchdog() async throws {
        let b = try bench("hang_stall"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .hang())
        let job = await run(b, m) { job in
            await Self.waitForEncode(m)
            job.handleStall(phase: "transcode encode", silentFor: 300)   // what StallMonitor calls after 5 min of silence
        }
        expectRefused(b, job, catalogBefore: before, reason: ["Stalled", "transcode encode"])
    }

    @Test("encode CRASHES (SIGSEGV) after writing part of a file: failed with the signal; nothing trashed")
    func encodeCrash() async throws {
        let b = try bench("crash"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .custom { request in
            if let out = request.arguments.last { try? Data(count: 30_000).write(to: URL(fileURLWithPath: out)) }
            return ProcessRunner.Result(stdout: "", stderr: "", exitCode: SIGSEGV, launched: true)
        })
        let job = await run(b, m)
        expectRefused(b, job, catalogBefore: before, reason: ["exit code \(SIGSEGV)"])
    }

    @Test("encode exits NONZERO with a plausible 20 KB file (disk full): failed with ffmpeg's words; nothing trashed")
    func encodeNonzeroExit() async throws {
        let b = try bench("nonzero"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000),
                                                     stderr: "frame=  300\n[out#0/mov @ 0x1] Error writing trailer: No space left on device\n",
                                                     exit: 228))
        let job = await run(b, m)
        expectRefused(b, job, catalogBefore: before, reason: ["exit code 228", "No space left on device"])
    }

    @Test("ffmpeg cannot be LAUNCHED: failed with the launch error; nothing trashed, nothing probed")
    func encodeLaunchFailure() async throws {
        let b = try bench("launch"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .launchFailure)
        let job = await run(b, m)
        expectRefused(b, job, catalogBefore: before, reason: ["exit code -1", "doesn’t exist"])
    }

    @Test("encode exits 0 but writes NOTHING: 'no output file'; nothing trashed")
    func encodeMissingOutput() async throws {
        let b = try bench("nooutput"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .output(stderr: "progress=end\n"))
        let job = await run(b, m)
        expectRefused(b, job, catalogBefore: before, reason: ["no output file"])
    }

    @Test("encode exits 0 and writes 2 s of a 12 s tape: 'stopped early'; nothing trashed")
    func encodeTruncated() async throws {
        let b = try bench("short"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: .output(stdout: "2.000000\n"))
        let job = await run(b, m)
        expectRefused(b, job, catalogBefore: before, reason: ["stopped early", "0:02", "0:12"])
    }

    // MARK: - The output cannot be measured (RED)

    enum Unmeasurable: String, CaseIterable, Sendable { case crash, launchFailure, garbage, emptyOutput }

    /// RED (2026-11-20, not fixed — data-risk path, reported for review):
    /// FFmpegEncodeCheck.verdict returns nil ("publish it") whenever either
    /// length cannot be read, by design ("a check that cannot measure must
    /// not invent a verdict"). With REPLACE that nil also authorises the
    /// Trash: an encode that exits 0 but leaves a file ffprobe cannot read
    /// (crash, garbage, no ffprobe) is published as "Transcoded", the
    /// prior file goes to the Trash and the unreadable output is adopted
    /// into the catalog. Real ffprobe on a 20 KB file of zeros takes this
    /// path too. Expected: an output nobody could measure is never grounds
    /// to remove the prior file or to record a derivative (rules 1, 2:
    /// refuse rather than guess). `withKnownIssue` keeps the lane green and
    /// turns red the day the fix lands, so the marker is then removed.
    @Test("RED: an output whose length probe crashes / cannot launch / returns garbage never trashes the prior file",
          arguments: Unmeasurable.allCases)
    func anUnmeasurableOutputIsNeverTrustedWithAReplace(_ kind: Unmeasurable) async throws {
        let b = try bench("unmeasurable_\(kind.rawValue)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let probe: ScriptedExecutor.Behaviour = switch kind {
        case .crash: .crash(signal: SIGSEGV, stderr: "")
        case .launchFailure: .launchFailure
        case .garbage: .garbage(stdout: "{\"format\": {\"dur")
        case .emptyOutput: .output(stdout: "", stderr: "Invalid data found when processing input\n", exit: 1)
        }
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: probe)
        let job = await run(b, m)
        withKnownIssue("RED: FFmpegEncodeCheck treats an unmeasurable output as a pass, and Replace then trashes the prior file") {
            if case .finished = job.state { Issue.record("an unmeasured output was published as \(job.state)") }
            #expect(b.trashed.all.isEmpty, "the prior file was trashed on an output nobody measured: \(b.trashed.all)")
            #expect(Self.sha(b.target) == b.priorSHA, "the prior file was replaced by an unmeasured output")
            #expect(b.catalogSnapshot() == before, "an unmeasured output was adopted into the catalog")
        }
    }
}
