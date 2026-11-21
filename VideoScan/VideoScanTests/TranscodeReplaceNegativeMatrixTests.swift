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
// · truncated output · and — GH #500, Rick 2026-11-20: "transcode to a temp,
// verify the temp, only when verified could it replace anything" — the
// output's length probe crashing / failing to launch / returning garbage /
// saying "Invalid data" / hanging to its deadline, and the SOURCE's length
// being unreadable. Each of those refuses the Replace, removes the new file,
// and says exactly why in the row and the OUTCOME line.
// A positive control proves the bench can publish and trash at all.
//
// The log (2026-11-21): every row starts its job through the production
// entry, `MediaFileOperationsCenter.startTranscode`, with the bench's
// InMemoryLogSink bound, so the START and OUTCOME lines asserted here are
// the ones the Center really WROTE — stated as expectations (`log.verify`,
// LogSinks+Test.swift; gmock's EXPECT_CALL shape): START once, the exact
// FAILED line once, in that order, never "Transcoded", and no other OUTCOME.
//
// The two rows that were parked RED under `withKnownIssue` are fixed and
// green (Rick 2026-11-21): plain Transcode (no Replace) no longer adopts an
// unmeasurable output (GH #502), and Preservation + Replace runs its
// frame-MD5 proof BEFORE the Replace (GH #501; the full proof matrix is
// TranscodePreservationProofMatrixTests).
//
// Parallel by design (each test binds its own mock and Trash seam).

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore   // ProcessRunner.Result.init for a .custom answer

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
        /// The mock log: `appLog` for everything `run` starts.
        let log = InMemoryLogSink(name: "negmx")
        /// The production Center the job is started through (it writes the
        /// START and OUTCOME lines). Held here so it outlives the job: its
        /// OUTCOME hop holds it weakly.
        let center: MediaFileOperationsCenter
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

    func bench(_ label: String, preset: TranscodePreset = .archival) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox("negmx_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        let srcURL = sb.sources.appendingPathComponent(Self.sourceName)
        _ = try MasterArchiveTestSupport.writeBlob(at: srcURL, bytes: 64 * 1024, seed: 41)   // placeholder: never decoded
        let source = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        source.durationSeconds = 12
        let outDir = sb.root.appendingPathComponent("Edits", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: source, preset: preset)
        _ = try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 42)       // the prior derivative
        model.records = [source, MasterArchiveTestSupport.makeRecord(path: target.path)]
        let fakeTrash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, source: source, target: target, priorSHA: Self.sha(target), fakeTrash: fakeTrash,
                     center: MediaFileOperationsCenter())
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
              sourceProbe: ScriptedExecutor.Behaviour = Self.twelveSeconds,
              outputProbe: ScriptedExecutor.Behaviour = Self.twelveSeconds) throws -> ScriptedExecutor {
        try ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: [Self.sourceName], encode)
            .on("ffprobe", containing: ["format=duration", Self.sourceName], sourceProbe)
            .on("ffprobe", containing: ["format=duration", ".vs-partial."], outputProbe)
            .on("ffprobe", containing: ["-show_streams"], .output(stdout: Self.h264ProbeJSON()))
    }

    /// `stopAt` presses Stop from the publish thread: inside the publish's
    /// FIRST exclusive-rename attempt, before it answers — or right after
    /// the previous file reached the (fake) Trash. The two sides of the
    /// commit point.
    enum StopAt: Sendable { case never, duringFirstRename, afterTrash }

    func run(_ b: Bench, _ mock: ScriptedExecutor, preset: TranscodePreset = .archival, replace: Bool = true,
             stopAt: StopAt = .never, renameFailsAfterTrash: Bool = false,
             whileRunning: (@MainActor (TranscodeJob) async -> Void)? = nil) async -> TranscodeJob {
        let started = Box<TranscodeJob>()
        let trashed = b.trashed, fakeTrash = b.fakeTrash
        // Stop, pressed from a publish thread: the main actor is suspended
        // in the publish, so its queue is free to run the press.
        let stop: @Sendable () -> Void = { DispatchQueue.main.sync { MainActor.assumeIsolated { started.value?.cancel() } } }
        let renames = Box<Bool>()
        let targetPath = b.target.path
        let realRename = ExclusivePublish.renameExclSyscall
        return await mock.scoped {
            await ExclusivePublish.$renameExclSyscall.withValue({ source, destination in
                if stopAt == .duringFirstRename, renames.value == nil {
                    renames.set(true)
                    stop()
                }
                // The disk fails (EIO) exactly when the new file should
                // take the name the previous file just left.
                if renameFailsAfterTrash, !trashed.all.isEmpty, destination == targetPath { return EIO }
                return realRename(source, destination)
            }) {
                await DerivativeOutputPublish.$trashItem.withValue({ url in
                    trashed.add(url.path)
                    let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: dest)
                    if stopAt == .afterTrash { stop() }
                    return dest
                }) {
                    await withAppLog(b.log) {
                        // The production entry: the Center writes START, starts the
                        // job (its Task {} inherits the task-locals) and, when the
                        // job ends, writes the OUTCOME under the scope bound here.
                        let job = b.center.startTranscode(record: b.source, preset: preset, outputURL: b.target,
                                                          model: b.model, replaceExisting: replace)
                        started.set(job)
                        if let whileRunning { await whileRunning(job) }
                        await job.task?.value
                        return job
                    }
                }
            }
        }
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
        // The log of a good Replace: START, the replace notice, one "done" — in that order, and no failure.
        let start = Self.startLine(b), tookTheName = LogLineMatcher.contains("derivative took the name \(b.target.lastPathComponent)")
        let done = LogLineMatcher.hasPrefix("transcode done: \(Self.sourceName) — ")
        await b.log.verify(
            .once(start), .once(tookTheName), .once(done),
            .inOrder(start, tookTheName, done),
            .noOtherLines(matching: Self.anyOutcome),
            waitingUpTo: .seconds(30))
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
        await expectFailedReplaceSaysWhatHappened(b, job)   // codex r2 F4
    }

    /// Codex r2 F4: the stall's cleanup result is reported, not assumed.
    @Test("encode HANGS, the watchdog fires, and the partial cannot be removed: Stalled, and the row says NOT removed with the reason")
    func aStalledReplaceWhoseCleanupFailsSaysNotRemoved() async throws {
        let b = try bench("hang_stall_unremovable")
        let outDir = b.outDir
        defer {
            chmod(outDir.path, 0o755)
            b.sb.cleanup()
        }
        let m = try mock(b, encode: .hang())
        let job = await run(b, m) { job in
            await Self.waitForEncode(m)
            chmod(outDir.path, 0o600)   // no search: the partial can be neither stat'ed nor unlinked
            job.handleStall(phase: "transcode encode", silentFor: 300)
        }
        chmod(outDir.path, 0o755)
        #expect(b.trashed.all.isEmpty)
        #expect(Self.sha(b.target) == b.priorSHA)
        let left = b.partials()
        #expect(left.count == 1, "the bench: the partial is still there: \(left)")
        guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); return }
        #expect(message.hasPrefix("Stalled"), "\(message)")
        #expect(message.contains("The original was not replaced: \(b.target.lastPathComponent) was not moved or changed"), "\(message)")
        #expect(message.contains("the failed new file was NOT removed: could not remove partial "), "\(message)")
        #expect(message.contains("Permission denied"), "\(message)")
        #expect(!message.contains("new file was removed"), "\(message)")
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
        await expectFailedReplaceSaysWhatHappened(b, job)
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
        await expectFailedReplaceSaysWhatHappened(b, job)
    }

    // MARK: - The new file cannot be verified (GH #500)

    enum Unmeasurable: String, CaseIterable, Sendable {
        case crash, launchFailure, garbage, emptyOutput, hang

        /// `{"format": {"dur` — written with escapes so this file's braces
        /// balance (the gauntlet inventory counts them to find suites).
        static let truncatedJSON = "\u{7B}\"format\": \u{7B}\"dur"

        var probe: ScriptedExecutor.Behaviour {
            switch self {
            case .crash: .crash(signal: SIGSEGV, stderr: "")
            case .launchFailure: .launchFailure
            case .garbage: .garbage(stdout: Self.truncatedJSON)
            // What real ffprobe 9.0.2 says for a 20 KB file of zeros.
            case .emptyOutput: .output(stdout: "", stderr: "Invalid data found when processing input\n", exit: 1)
            // A REAL hung child under the real runner's deadline machinery
            // (SIGTERM at the deadline, `timedOut`), with the probe's 60 s
            // deadline shortened to 0.5 s so the row takes half a second.
            case .hang: .custom { request in
                var short = request
                short.deadlineSeconds = 0.5
                return await ScriptedExecutor().on("*", .hang()).run(short)
            }
            }
        }

        /// The specific cause the row and the OUTCOME line must carry:
        /// the tool, its exit code, its own first words.
        var causeWords: [String] {
            switch self {
            case .crash: ["ffprobe stopped with exit code \(SIGSEGV)"]
            case .launchFailure: ["ffprobe could not be started (exit code -1)", "doesn’t exist"]
            case .garbage: ["ffprobe exited 0 but its answer was not a length", Self.truncatedJSON]
            case .emptyOutput: ["ffprobe stopped with exit code 1", "Invalid data found when processing input"]
            case .hang: ["ffprobe did not answer within 60 s and was stopped", "exit code \(SIGTERM)"]
            }
        }
    }

    /// What a Replace refused for want of verification must show the user
    /// and the log (Rick 2026-11-20: "we must fail but fail and record the
    /// error clearly and log it clearly. The user must be told"): the job
    /// is FAILED, never "Transcoded"; the row's line opens with the plain
    /// words and carries the specific cause; the Center's one OUTCOME line
    /// (console, videoscan.log, catalog.log — `terminalSummaryLine`, the
    /// pure function the Center writes from) names the verb, the source,
    /// the cause, that the original was not touched and that the new file
    /// was removed; and nothing on disk or in the catalog changed.
    func expectUnverifiedReplaceRefused(_ b: Bench, _ job: TranscodeJob, _ m: ScriptedExecutor, catalogBefore: [String],
                                        file whose: String, cause: [String],
                                        sourceLocation: SourceLocation = #_sourceLocation) async {
        let plain = "Could not verify the new file — the original was not replaced."
        expectRefused(b, job, catalogBefore: catalogBefore, reason: [plain, whose] + cause, sourceLocation: sourceLocation)
        guard case .failed(let message) = job.state else { return }
        #expect(message.hasPrefix(plain), "the row must open with the plain words: \(message)", sourceLocation: sourceLocation)
        #expect(message.contains("\(b.target.lastPathComponent) was not moved or changed"), "\(message)", sourceLocation: sourceLocation)
        #expect(message.contains("the unverified new file was removed"), "\(message)", sourceLocation: sourceLocation)
        #expect(!message.contains("Transcoded"), sourceLocation: sourceLocation)
        #expect(job.subtitle == message, "the MFO row shows the same sentence: \(job.subtitle)", sourceLocation: sourceLocation)
        #expect(!job.wasRefused, "work was done and failed: the OUTCOME says FAILED", sourceLocation: sourceLocation)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "transcode FAILED: \(Self.sourceName) — \(message)", "OUTCOME: \(outcome ?? "nil")", sourceLocation: sourceLocation)
        for words in cause + ["the original was not replaced", "was not moved or changed", "the unverified new file was removed"] {
            #expect(outcome?.contains(words) == true, "OUTCOME lacks “\(words)”: \(outcome ?? "nil")", sourceLocation: sourceLocation)
        }
        #expect((outcome ?? "").count < 900, "the OUTCOME line is bounded", sourceLocation: sourceLocation)
        // …and that sentence is the line the Center WROTE, once, after START.
        await expectLoggedFailure(b, outcome: "transcode FAILED: \(Self.sourceName) — \(message)", sourceLocation: sourceLocation)
        // Nothing reached the Trash seam's folder; nothing probed the
        // output for the catalog; the encode ran once and was not retried.
        let inTrash = (try? FileManager.default.contentsOfDirectory(atPath: b.fakeTrash.path)) ?? ["unreadable"]
        #expect(inTrash.isEmpty, "\(inTrash)", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty, "the unverified output was probed for the catalog", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffmpeg").count == 1, "\(m.calls)", sourceLocation: sourceLocation)
        // Only the source and the prior file are in their folders.
        let beside = ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? []).sorted()
        #expect(beside == [b.target.lastPathComponent], "left beside the original: \(beside)", sourceLocation: sourceLocation)
    }

    /// GH #500 (was RED on main under `withKnownIssue`): FFmpegEncodeCheck
    /// answered nil ("publish it") whenever a length could not be read, and
    /// with REPLACE that nil also sent the prior file to the Trash and
    /// catalogued the unreadable output as "Transcoded".
    @Test("an output whose length probe crashes / cannot launch / returns garbage / says Invalid data / hangs: Replace refused, new file removed, the cause said",
          arguments: Unmeasurable.allCases)
    func anUnmeasurableOutputIsNeverTrustedWithAReplace(_ kind: Unmeasurable) async throws {
        let b = try bench("unmeasurable_\(kind.rawValue)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: kind.probe)
        let job = await run(b, m)
        await expectUnverifiedReplaceRefused(b, job, m, catalogBefore: before,
                                       file: "the new file's length could not be read", cause: kind.causeWords)
    }

    @Test("the SOURCE's length cannot be read (no container duration): nothing to compare the new file against, so Replace is refused the same way")
    func anUnmeasurableSourceIsNotAVerifiedReplace() async throws {
        let b = try bench("unmeasurable_source"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), sourceProbe: .output(stdout: "N/A\n"))
        let job = await run(b, m)
        await expectUnverifiedReplaceRefused(b, job, m, catalogBefore: before,
                                       file: "the source's length could not be read to compare against",
                                       cause: ["ffprobe exited 0 but its answer was not a length", "“N/A”"])
    }

    @Test("the refusal's cause is bounded: a tool that prints pages is quoted for two lines and 240 characters")
    func theCauseIsBounded() async throws {
        let b = try bench("unmeasurable_flood"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let flood = (0..<400).map { "line \($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n")
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: .output(stdout: "", stderr: flood, exit: 1))
        let job = await run(b, m)
        await expectUnverifiedReplaceRefused(b, job, m, catalogBefore: before,
                                       file: "the new file's length could not be read", cause: ["ffprobe stopped with exit code 1", "line 0 x"])
        guard case .failed(let message) = job.state else { return }
        #expect(!message.contains("line 2 "), "only the first two lines are quoted")
        #expect(message.count < 800, "\(message.count)")
    }

    // MARK: - Codex GH #500 round 1 (five findings, each red first)

    /// A set-once value two tasks share (the probes' barrier).
    final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
        var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
        /// Poll (10 s at most); ignores cancellation on purpose — a probe
        /// that already has its answer returns it whatever the task says.
        func wait() async -> Value? {
            for _ in 0..<2000 {
                if let value { return value }
                try? await Task.sleep(nanoseconds: 5_000_000)
                if Task.isCancelled { await Task.yield() }
            }
            return value
        }
    }

    nonisolated static let twelveSecondsResult = ProcessRunner.Result(stdout: "12.000000\n", stderr: "", exitCode: 0, launched: true)
    nonisolated static let invalidDataResult = ProcessRunner.Result(stdout: "", stderr: "Invalid data found when processing input\n",
                                                        exitCode: 1, launched: true)

    /// Rules 2 and 1 for a row that leaves something at the partial's name
    /// on purpose: nothing trashed, the prior file intact, catalog unchanged.
    func expectOriginalUntouched(_ b: Bench, _ m: ScriptedExecutor, catalogBefore: [String],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(b.trashed.all.isEmpty, "trashed: \(b.trashed.all)", sourceLocation: sourceLocation)
        #expect(Self.sha(b.target) == b.priorSHA, "the prior file changed", sourceLocation: sourceLocation)
        #expect(b.catalogSnapshot() == catalogBefore, "the catalog changed", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty, sourceLocation: sourceLocation)
    }

    /// F5: a Replace whose ENCODE failed also says what became of the
    /// original and of the new file, in the row and in the OUTCOME line.
    func expectFailedReplaceSaysWhatHappened(_ b: Bench, _ job: TranscodeJob,
                                             sourceLocation: SourceLocation = #_sourceLocation) async {
        guard case .failed(let message) = job.state else { return }
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused) ?? ""
        for words in ["The original was not replaced", "\(b.target.lastPathComponent) was not moved or changed",
                      "the failed new file was removed"] {
            #expect(message.contains(words), "the row lacks “\(words)”: \(message)", sourceLocation: sourceLocation)
            #expect(outcome.contains(words), "OUTCOME lacks “\(words)”: \(outcome)", sourceLocation: sourceLocation)
        }
        #expect(job.subtitle == message, sourceLocation: sourceLocation)
        await expectLoggedFailure(b, outcome: outcome, preset: job.preset, sourceLocation: sourceLocation)
    }

    /// F1 (P0): while the output is probed, the reserved partial is moved
    /// aside and ANOTHER file is renamed onto its pathname. The refusal's
    /// cleanup must remove only the file this run reserved (device + inode)
    /// — never whatever has its name — and must say so, with the path.
    @Test("F1: a different file put at the new file's name during verification is never removed by the cleanup")
    func aFileSubstitutedAtTheNewFilesNameIsNeverRemovedByTheCleanup() async throws {
        let b = try bench("substituted"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let other = b.sb.sources.appendingPathComponent("test_other_family_tape.mov")
        _ = try MasterArchiveTestSupport.writeBlob(at: other, bytes: 30_000, seed: 77)
        let otherSHA = Self.sha(other)
        let aside = b.sb.root.appendingPathComponent("test_moved_aside.bin")
        let partialAt = Box<URL>()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: .custom { request in
            let partial = URL(fileURLWithPath: request.arguments.last ?? "")
            try? FileManager.default.moveItem(at: partial, to: aside)
            try? FileManager.default.moveItem(at: other, to: partial)
            partialAt.set(partial)
            return Self.invalidDataResult
        })
        let job = await run(b, m)
        let partial = try #require(partialAt.value)
        #expect(Self.sha(partial) == otherSHA, "the substituted file was deleted or changed")
        expectOriginalUntouched(b, m, catalogBefore: before)
        guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); return }
        #expect(message.hasPrefix("Could not verify the new file — the original was not replaced."), "\(message)")
        #expect(message.contains("the unverified new file was NOT removed: a different file is at \(partial.path) — left untouched"), "\(message)")
        #expect(!message.contains("new file was removed"), "\(message)")
    }

    /// F2 (P0): the output probe measures file A; while the source probe is
    /// still out, B (over 10 KB, never measured) is put at A's pathname.
    /// A's length must not vouch for B: nothing trashed, nothing published.
    @Test("F2: a new file swapped while it was being verified is never published — the lengths read belong to another file")
    func aNewFileSwappedDuringVerificationIsNeverPublished() async throws {
        let b = try bench("swapped"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let measured = Box<URL>()
        let swapped = Data(repeating: 0x42, count: 20_000)
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)),
                         sourceProbe: .custom { _ in
                             // Barrier: only after the output was measured.
                             if let partial = await measured.wait() {
                                 try? swapped.write(to: partial, options: .atomic)   // a NEW file (new inode) at the name
                             }
                             return Self.twelveSecondsResult
                         },
                         outputProbe: .custom { request in
                             measured.set(URL(fileURLWithPath: request.arguments.last ?? ""))
                             return Self.twelveSecondsResult
                         })
        let job = await run(b, m)
        let partial = try #require(measured.value)
        expectOriginalUntouched(b, m, catalogBefore: before)
        guard case .failed(let message) = job.state else { Issue.record("an unverified file was published: \(job.state)"); return }
        #expect(message.hasPrefix("Could not verify the new file — the original was not replaced."), "\(message)")
        #expect(message.contains("Cause: the new file changed while it was being verified"), "\(message)")
        // B is not the file this run reserved: left where it is, and said.
        #expect((try? Data(contentsOf: partial)) == swapped)
        #expect(message.contains("NOT removed: a different file is at \(partial.path) — left untouched"), "\(message)")
    }

    /// F3 (P1): both probes answer, and Stop lands before the job resumes
    /// from them. A Stop is a Stop: cancelled, nothing trashed or published.
    @Test("F3: Stop after the probes answered but before the publish ends Cancelled; nothing trashed, nothing catalogued")
    func stopAfterTheProbesAnsweredNeverPublishes() async throws {
        let b = try bench("stop_after_gate"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let probing = Box<Bool>(), release = Box<Bool>()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), sourceProbe: .custom { _ in
            probing.set(true)
            _ = await release.wait()
            return Self.twelveSecondsResult   // a good answer, already in hand when Stop was pressed
        })
        let job = await run(b, m) { job in
            _ = await probing.wait()
            job.cancel()
            release.set(true)
        }
        expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
    }

    /// Codex r2 F3, before the COMMIT POINT (the Trash move): Stop is
    /// pressed while the publish's first rename attempt is still out — the
    /// name is taken, nothing has been replaced yet. It is still a Stop.
    @Test("r2 F3: Stop inside the publish, before the previous file is trashed, ends Cancelled; zero Trash calls, catalog unchanged")
    func stopBeforeTheReplaceBeginsCancels() async throws {
        let b = try bench("stop_before_commit"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)))
        let job = await run(b, m, stopAt: .duringFirstRename)
        expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
    }

    /// …and after it: the previous file is already in the Trash when Stop
    /// arrives. A replace cannot be half-undone, so it completes, the job
    /// ends Finished (never a Cancelled that hides a replace), and the
    /// summary says the Stop came too late.
    @Test("r2 F3: Stop after the previous file was trashed finishes the replace and says the Stop arrived too late")
    func stopAfterTheReplaceBeganFinishesAndSaysSo() async throws {
        let b = try bench("stop_after_commit"); defer { b.sb.cleanup() }
        let m = try mock(b, encode: .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        let job = await run(b, m, stopAt: .afterTrash)
        guard case .finished(let summary) = job.state else { Issue.record("a completed replace was reported as \(job.state)"); return }
        #expect(summary.contains("The previous file is in the Trash."), "\(summary)")
        #expect(summary.contains("Stop arrived after the replace had begun, so it was completed."), "\(summary)")
        #expect(job.subtitle == summary)
        #expect(b.trashed.all == [b.target.path])
        #expect(Self.sha(b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)) == b.priorSHA)
        #expect(Self.sha(b.target) != b.priorSHA, "the new derivative took the name")
        #expect(b.model.records.filter { $0.fullPath == b.target.path }.first?.derivedFrom == b.source.id,
                "the catalog matches the disk: the derivative is recorded")
    }

    /// Codex r3 (P1) — the MIXED STATE: the previous file is in the Trash
    /// and then the new file cannot take its name (EIO). The job is FAILED
    /// and says where both files are and how to put the original back —
    /// and a Stop pressed after the commit point must not turn that into a
    /// bare "Cancelled" that hides it.
    @Test("r3: the rename fails after the previous file was trashed: FAILED, naming the Trash location and the kept new file — with or without a late Stop",
          arguments: [StopAt.never, .afterTrash])
    func aReplaceThatFailsAfterTheTrashSaysWhereBothFilesAre(_ stopAt: StopAt) async throws {
        let b = try bench("mixed_\(stopAt)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let encoded = Data(repeating: 0x5A, count: 20_000)
        let m = try mock(b, encode: .writeOutputFile(encoded))
        let job = await run(b, m, stopAt: stopAt, renameFailsAfterTrash: true)

        // On disk: the original in the (fake) Trash, the encode kept, the name empty.
        let inTrash = b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)
        #expect(b.trashed.all == [b.target.path])
        #expect(Self.sha(inTrash) == b.priorSHA, "the original must survive in the Trash")
        let kept = ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? []).filter { $0.contains(".vs-kept.") }
        #expect(kept.count == 1, "\(kept)")
        let keptURL = b.outDir.appendingPathComponent(kept.first ?? "missing")
        #expect((try? Data(contentsOf: keptURL)) == encoded, "the encode must survive")
        #expect(!FileManager.default.fileExists(atPath: b.target.path))
        #expect(b.partials().isEmpty)
        #expect(b.catalogSnapshot() == before, "nothing was catalogued for a replace that did not finish")

        guard case .failed(let message) = job.state else { Issue.record("a half-done replace was reported as \(job.state)"); return }
        #expect(message.hasPrefix("The replace was NOT completed"), "\(message)")
        #expect(message.contains("Input/output error"), "the cause: \(message)")
        #expect(message.contains("The original \(b.target.lastPathComponent) is in the Trash at \(inTrash.path)"), "\(message)")
        #expect(message.contains("move it back to \(b.outDir.path) to restore it"), "\(message)")
        #expect(message.contains("The new file is kept at \(keptURL.path)"), "\(message)")
        #expect(!message.contains(".vs-partial."), "no stale location: \(message)")
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "transcode FAILED: \(Self.sourceName) — \(message)")
        #expect(job.subtitle == message)
        // The log of the mixed state: START, the kept-encode notice, then the one FAILED line that says where both files are.
        let start = Self.startLine(b), notPublished = LogLineMatcher.contains("finished but not published")
        let failed = LogLineMatcher.equals("transcode FAILED: \(Self.sourceName) — \(message)")
        await b.log.verify(
            .once(start), .once(notPublished), .once(failed),
            .inOrder(start, notPublished, failed),
            .never(.contains("took the name")),
            .noOtherLines(matching: Self.anyOutcome),
            waitingUpTo: .seconds(30))
    }

    /// F4 (P2): the cleanup's own result is what the message reports. The
    /// folder loses its search permission while the output is probed, so
    /// the partial can be neither removed nor even seen — "not there" must
    /// not be read as "removed".
    @Test("F4: a new file the cleanup could not remove is never reported as removed; the message gives the reason and the path")
    func aNewFileThatCannotBeRemovedIsNeverReportedRemoved() async throws {
        let b = try bench("unremovable")
        let outDir = b.outDir
        defer {
            chmod(outDir.path, 0o755)
            b.sb.cleanup()
        }
        let partialAt = Box<URL>()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: .custom { request in
            partialAt.set(URL(fileURLWithPath: request.arguments.last ?? ""))
            chmod(outDir.path, 0o600)   // no search: lstat and unlink both fail with EACCES
            return Self.invalidDataResult
        })
        let job = await run(b, m)
        chmod(outDir.path, 0o755)
        let partial = try #require(partialAt.value)
        #expect(FileManager.default.fileExists(atPath: partial.path), "the bench: the partial is still there")
        #expect(b.trashed.all.isEmpty)
        #expect(Self.sha(b.target) == b.priorSHA)
        guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); return }
        #expect(message.contains("new file was NOT removed: could not remove partial \(partial.path): Permission denied"), "\(message)")
        #expect(!message.contains("new file was removed"), "\(message)")
        #expect(message.localizedCaseInsensitiveContains("the original was not replaced"), "\(message)")
    }

    /// F4, the sentence itself: removed / already gone / not removed.
    @Test("F4: the disposition sentence says removed only when the cleanup said so")
    func theDispositionSentenceReportsTheCleanupsOwnResult() {
        typealias J = TranscodeJob
        #expect(J.unverifiedReplaceMessage(cause: "c", original: "a.mov", cleanup: .removed)
                == "Could not verify the new file — the original was not replaced. Cause: c. a.mov was not moved or changed; the unverified new file was removed.")
        #expect(J.unverifiedReplaceMessage(cause: "c", original: "a.mov", cleanup: .alreadyGone)
                == "Could not verify the new file — the original was not replaced. Cause: c. a.mov was not moved or changed; the unverified new file was no longer there to remove.")
        #expect(J.unverifiedReplaceMessage(cause: "c", original: "a.mov", cleanup: .notRemoved("could not remove partial /x/p: Permission denied (errno 13)"))
                == "Could not verify the new file — the original was not replaced. Cause: c. a.mov was not moved or changed; the unverified new file was NOT removed: could not remove partial /x/p: Permission denied (errno 13).")
        // The too-late Stop: "after the replace had begun" only when a
        // replace happened; otherwise no claim about when Stop arrived
        // (codex r3 residual: it may have landed before a publish beside).
        #expect(J.lateStopNote(replaced: true) == " Stop arrived after the replace had begun, so it was completed.")
        #expect(J.lateStopNote(replaced: false) == " Stop was pressed too late to cancel: the new file was published and kept.")
        #expect(J.failedReplaceMessage(failure: "Ffmpeg stopped with exit code 1", original: "a.mov", cleanup: .removed)
                == "Ffmpeg stopped with exit code 1. The original was not replaced: a.mov was not moved or changed; the failed new file was removed.")
    }

    /// F2, the second check: the stamp the gate verified must still be the
    /// file at the partial's name IMMEDIATELY before the publish. Driven on
    /// the real publish function: a swap after the gate throws, and the
    /// Trash step is never called; the unswapped file publishes.
    @Test("F2: the publish refuses a new file that is no longer the verified one — nothing trashed")
    func thePublishRefusesAFileThatIsNotTheVerifiedOne() async throws {
        let b = try bench("publish_identity"); defer { b.sb.cleanup() }
        let partial = try DerivativeOutputPublish.reservePartial(for: b.target)
        defer { PartialFileNaming.unregisterLive(partial) }
        try Data(repeating: 0x5A, count: 20_000).write(to: partial)
        let verified = try #require(PartialFileNaming.fileStamp(partial.path))
        let trashed = b.trashed
        let trash: @Sendable (URL) throws -> URL? = { url in trashed.add(url.path); return nil }

        // Same inode, different bytes (size) → not the verified state.
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 10))
        try handle.close()
        await #expect(throws: TranscodeJob.ChangedSinceVerified.self) {
            _ = try await TranscodeJob.publishVerified(partial: partial.path, final: b.target, policy: .replaceViaTrash,
                                                       archiveCheck: nil, trash: trash, verified: verified)
        }
        // A different file (new inode) of the SAME size.
        try Data(repeating: 0x42, count: 20_000).write(to: partial, options: .atomic)
        await #expect(throws: TranscodeJob.ChangedSinceVerified.self) {
            _ = try await TranscodeJob.publishVerified(partial: partial.path, final: b.target, policy: .replaceViaTrash,
                                                       archiveCheck: nil, trash: trash, verified: verified)
        }
        #expect(b.trashed.all.isEmpty, "\(b.trashed.all)")
        #expect(Self.sha(b.target) == b.priorSHA)
        #expect(FileManager.default.fileExists(atPath: partial.path), "the unverified file is left for the caller")
        // And the job hands the gate's stamp to exactly this function.
        let source = try SourceTree.appSource(named: "TranscodeJob.swift")
        #expect(source.contains("guard let publishNote = await publish(partialURL, verified: verified) else { return }"))
        #expect(source.contains("try await Self.publishVerified("))
        #expect(!source.contains("DerivativeOutputPublish.publish("), "the job publishes only through publishVerified")
    }

    // MARK: - GH #502: without Replace, an unverified output is not adopted either

    /// What a plain Transcode (no Replace) whose new file could not be
    /// verified must show: FAILED, never "Transcoded"; the same sentence
    /// family as #500 minus "the original was not replaced" (nothing was
    /// going to be replaced); the new file removed; nothing published
    /// beside the existing file; nothing adopted into the catalog.
    func expectUnverifiedNotPublished(_ b: Bench, _ job: TranscodeJob, _ m: ScriptedExecutor, catalogBefore: [String],
                                      file whose: String, cause: [String],
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        let plain = "Could not verify the new file — nothing was published or added to the catalog."
        expectRefused(b, job, catalogBefore: catalogBefore, reason: [plain, whose] + cause, sourceLocation: sourceLocation)
        guard case .failed(let message) = job.state else { return }
        #expect(message.hasPrefix(plain), "the row must open with the plain words: \(message)", sourceLocation: sourceLocation)
        #expect(message.hasSuffix("The unverified new file was removed."), "\(message)", sourceLocation: sourceLocation)
        #expect(!message.contains("not replaced") && !message.contains("Transcoded"), "\(message)", sourceLocation: sourceLocation)
        #expect(job.subtitle == message, sourceLocation: sourceLocation)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "transcode FAILED: \(Self.sourceName) — \(message)", "OUTCOME: \(outcome ?? "nil")", sourceLocation: sourceLocation)
        #expect((outcome ?? "").count < 900, "the OUTCOME line is bounded", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty, "the unverified output was probed for the catalog", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffmpeg").count == 1, "\(m.calls)", sourceLocation: sourceLocation)
        let beside = ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? []).sorted()
        #expect(beside == [b.target.lastPathComponent], "published or left beside the existing file: \(beside)", sourceLocation: sourceLocation)
    }

    /// GH #502 (was RED on main under `withKnownIssue` as
    /// `aPlainTranscodeStillAdoptsAnUnmeasurableOutput`): without Replace an
    /// output ffprobe could not read was published beside the existing
    /// file, reported "Transcoded" and adopted into the catalog.
    @Test("plain Transcode (no Replace): an output whose length probe crashes / cannot launch / returns garbage / says Invalid data / hangs is FAILED, removed, never catalogued",
          arguments: Unmeasurable.allCases)
    func aPlainTranscodeNeverAdoptsAnUnmeasurableOutput(_ kind: Unmeasurable) async throws {
        let b = try bench("plain_unmeasurable_\(kind.rawValue)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: kind.probe)
        let job = await run(b, m, replace: false)
        expectUnverifiedNotPublished(b, job, m, catalogBefore: before,
                                     file: "the new file's length could not be read", cause: kind.causeWords)
    }

    @Test("plain Transcode (no Replace): the SOURCE's length cannot be read — nothing to compare against, so the output is not adopted")
    func aPlainTranscodeWithAnUnmeasurableSourceIsNotAdopted() async throws {
        let b = try bench("plain_unmeasurable_source"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), sourceProbe: .output(stdout: "N/A\n"))
        let job = await run(b, m, replace: false)
        expectUnverifiedNotPublished(b, job, m, catalogBefore: before,
                                     file: "the source's length could not be read to compare against",
                                     cause: ["ffprobe exited 0 but its answer was not a length", "“N/A”"])
    }

    /// GH #502, "related, untested": without Replace a Stop during the
    /// output probes could still publish (a cancelled probe read as
    /// "unmeasured", which was a pass).
    @Test("plain Transcode (no Replace): Stop while the output is being probed ends Cancelled; nothing published, nothing catalogued")
    func stopDuringTheProbesOfAPlainTranscodeNeverPublishes() async throws {
        let b = try bench("plain_stop_probes"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let probing = Box<Bool>(), release = Box<Bool>()
        let m = try mock(b, encode: .writeOutputFile(Data(count: 20_000)), outputProbe: .custom { _ in
            probing.set(true)
            _ = await release.wait()
            return Self.twelveSecondsResult   // a good answer, in hand when Stop was pressed
        })
        let job = await run(b, m, replace: false) { job in
            _ = await probing.wait()
            job.cancel()
            release.set(true)
        }
        expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
        let beside = ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? []).sorted()
        #expect(beside == [b.target.lastPathComponent], "\(beside)")
    }

    @Test("control (no Replace): a verified output is published BESIDE the existing file, which is untouched, and is catalogued")
    func controlAPlainTranscodePublishesBeside() async throws {
        let b = try bench("plain_ok"); defer { b.sb.cleanup() }
        let m = try mock(b, encode: .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        let job = await run(b, m, replace: false)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("Transcoded → "), "\(summary)")
        #expect(summary.contains("Kept the existing \(b.target.lastPathComponent)"), "\(summary)")
        #expect(b.trashed.all.isEmpty && Self.sha(b.target) == b.priorSHA)
        #expect(job.publishedURL != b.target && FileManager.default.fileExists(atPath: job.publishedURL.path))
        #expect(b.model.records.first { $0.fullPath == job.publishedURL.path }?.derivedFrom == b.source.id)
        #expect(b.partials().isEmpty)
    }

    // MARK: - GH #501: Preservation proves lossless BEFORE the Replace

    /// GH #501 (was RED on main under `withKnownIssue` as
    /// `preservationReplaceProvesLosslessOnlyAfterTheReplace`): the
    /// bit-exact proof ran against the PUBLISHED file, after the prior
    /// master went to the Trash. The full matrix is
    /// TranscodePreservationProofMatrixTests; this is the original row.
    @Test("Preservation + Replace: a master that fails its frame-MD5 proof never replaces — the prior master is untouched, the failed one removed")
    func preservationReplaceProvesLosslessBeforeTheReplace() async throws {
        let b = try bench("preservation_order", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: ["framemd5", Self.sourceName], .output(stdout: "0,          0,          0,        1,   115200, 11111111111111111111111111111111\n"))
            .on("ffmpeg", containing: ["framemd5"], .output(stdout: "0,          0,          0,        1,   115200, 22222222222222222222222222222222\n"))
            .on("ffmpeg", containing: [Self.sourceName], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
            .on("ffprobe", containing: ["format=duration"], Self.twelveSeconds)
        let job = await run(b, m, preset: .preservation)
        expectRefused(b, job, catalogBefore: before,
                      reason: ["Lossless verification FAILED", "11111111111111111111111111111111", "22222222222222222222222222222222"])
        await expectFailedReplaceSaysWhatHappened(b, job)
    }
}

// MARK: - The log half of a row (what the Center wrote)

extension TranscodeReplaceNegativeMatrixTests {

    /// The Center's START line for a row's job.
    static func startLine(_ b: Bench, preset: TranscodePreset = .archival) -> LogLineMatcher {
        .equals("transcode: \(sourceName) — \(preset.rawValue) → \(b.target.lastPathComponent)")
    }

    /// Any OUTCOME-shaped transcode line (for "no OTHER outcome was written").
    static let anyOutcome = LogLineMatcher.matching(#/^transcode (done|FAILED|refused|cancelled): /#, label: "a transcode OUTCOME line")

    /// The log half of a failed row, as expectations on what the Center
    /// wrote: START once, exactly `outcome` once and after it, never a
    /// success claim, and no second OUTCOME. Waits (bounded) for the
    /// OUTCOME, written one main-actor turn after the job's task ends.
    func expectLoggedFailure(_ b: Bench, outcome: String, preset: TranscodePreset = .archival,
                             sourceLocation: SourceLocation = #_sourceLocation) async {
        let start = Self.startLine(b, preset: preset)
        await b.log.verify(
            .once(start),
            .once(.equals(outcome)),
            .inOrder(start, .equals(outcome)),
            .never(.contains("Transcoded")),
            .never(.contains("took the name")),
            .noOtherLines(matching: Self.anyOutcome),
            waitingUpTo: .seconds(30), sourceLocation: sourceLocation)
    }
}
