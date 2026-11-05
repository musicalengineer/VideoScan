// EraJobConvergenceTests.swift — every file the era job plans reaches a
// verdict in a bounded number of runs; the helper's schedule SETTLES.
//
// REGRESSION (Rick 2026-11-04, background.log 18:37–18:50): 402 of 523 files
// (Avid MXF essences, QuickTime reference movies, .m4p) never rip a frame.
// "Frames that would not rip" was retry-next-run with NO limit, so every job
// re-planned the same 402, forever, at full speed — and nothing said why.
//
//   LOGIC      a file whose frames never rip / whose windows the model never
//              answers / that times out / that kills the worker is tried
//              EraAttemptStore.maxTries (3) times, then given up with ONE
//              era.none line naming the reason and the tries; a file that
//              recovers before the limit gets its era and its tries are cleared.
//   ISOLATION  a try is not counted when the file went away mid-analysis;
//              tries are per signer; a torn attempts file refuses the job in
//              words (fail closed: never a silent give-up, never a silent loop).
//   TRUTH      a give-up is never an era: its value is "none", its evidence
//              says "gave up after 3 tries: <why>", with ffmpeg's own words
//              when a frame would not rip.
//   SCALE/E2E  the REAL supervisor + schedule over a mixed catalog (good,
//              blank, stamp, rip failure, generation error, hang, death,
//              flaky) settles: plan size 0, no job active, no file analyzed
//              more than 3 times.
//   MEDIA      real files made by ffmpeg (mp4/h264, mov/prores, mkv/ffv1+pcm,
//              mxf/mpeg2, avi/dv) through bench.py's REAL ClipService and
//              frame ripper with a fake model: the good ones get an era, the
//              undecodable ones (truncated mov, garbage bytes) are given up
//              with ffmpeg's words; the next plan is empty.
// Synthetic digests; no family media.

import Foundation
import Testing
@testable import VideoScanCore

enum Convergence {
    static let signer = SeatedApproach.eraA2.signer

    static func setup(_ fixture: StoreFixture, root: URL, jobID: JobID = JobID(), factory: String = "make_service",
                      clipTimeout: Duration = .seconds(20), log: URL? = nil,
                      readable: @escaping @Sendable (String) -> Bool = { _ in true }) throws -> EraJob.Setup {
        var worker = ClipWorkerFixture.configuration(factory, clipTimeout: clipTimeout, log: log)
        // The production door for the worker's PATH (ffmpeg/ffprobe found as under launchd).
        worker.environment = try SubprocessEnvironment.mediaTools(inheriting: worker.environment ?? ProcessInfo.processInfo.environment)
        if let log { worker.environment?["FAKE_CLIP_LOG"] = log.path }
        return EraJob.Setup(jobID: jobID, catalogURL: fixture.url, stateRoot: root, worker: worker, isReadable: readable)
    }

    /// One whole job through the real supervisor (what one scheduled run does); its OUTCOME line.
    @discardableResult
    static func runJob(_ fixture: StoreFixture, root: URL, factory: String = "make_service", clipTimeout: Duration = .seconds(20),
                       clipLog: URL? = nil, log: LogLines = LogLines()) async throws -> String {
        let jobFactory = EraTestFactory { id in
            // swiftlint:disable:next force_try
            try! Self.setup(fixture, root: root, jobID: id, factory: factory, clipTimeout: clipTimeout, log: clipLog)
        }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: jobFactory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        guard case .accepted = await supervisor.enqueue(JobRequest(kind: .era, lane: "model", requestedBy: "test")) else {
            Issue.record("enqueue refused"); return ""
        }
        await supervisor.drain()
        await jobFactory.closeWorkers()
        return log.lines.last { $0.hasPrefix("OUTCOME era") } ?? ""
    }

    /// The digests the next job would plan (the production planner).
    static func planned(_ fixture: StoreFixture, root: URL) throws -> [String] {
        let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        return try EraPlanner.plan(catalogURL: fixture.url, journal: journal, signer: signer, limit: nil, jobID: JobID(),
                                   isReadable: { _ in true }).units.map(\.digest)
    }

    static func evidence(_ line: ObservationLine) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.evidenceJSON.utf8))) as? [String: Any] ?? [:]
    }

    static func lines(_ root: URL, _ n: Int) throws -> [ObservationLine] {
        try EraFixture.lines(root).filter { $0.subjectID == EraFixture.hex(n) }
    }
}

@Suite("EraJob — every planned file reaches a verdict", .serialized)
struct EraJobConvergenceTests {

    /// The 2026-11-04 loop, as a test: three runs, then one give-up line, then nothing to plan.
    @Test("RED→GREEN: frames that never rip are given up on the third try, with the reason — not re-planned forever")
    func framesThatNeverRipAreGivenUp() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/ripfail.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        for run in 1..<EraAttemptStore.maxTries {
            let outcome = try await Convergence.runJob(fixture, root: root)
            #expect(try EraFixture.lines(root).isEmpty, "run \(run): not a verdict yet")
            #expect(try Convergence.planned(fixture, root: root) == [EraFixture.hex(1)], "run \(run): tried again next run")
            #expect(outcome.contains("tried again next run: 1 frames would not decode"), "run \(run): \(outcome)")
        }
        let last = try await Convergence.runJob(fixture, root: root)
        let lines = try Convergence.lines(root, 1)
        #expect(lines.map(\.field) == ["era.none"], "exactly one give-up line, never an era")
        #expect(lines.first?.value == "none")
        let evidence = Convergence.evidence(try #require(lines.first))
        #expect(evidence["gaveUp"] as? Bool == true)
        #expect(evidence["tries"] as? Int == EraAttemptStore.maxTries)
        #expect((evidence["reason"] as? String)?.hasPrefix("gave up after 3 tries: ") == true, "\(evidence)")
        #expect((evidence["reason"] as? String)?.contains("would not decode") == true, "\(evidence)")
        #expect(last.contains("1 given up at the 3-try limit"), "\(last)")
        #expect(try Convergence.planned(fixture, root: root).isEmpty, "the fourth plan is empty: the loop is over")
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: Convergence.signer) == 0,
                "a given-up file's tries are cleared (its era.none caches it)")
    }

    @Test("RED→GREEN: windows the model never answers are given up on the third try")
    func generationErrorsAreGivenUp() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/generr.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        for _ in 0..<EraAttemptStore.maxTries { try await Convergence.runJob(fixture, root: root) }
        let lines = try Convergence.lines(root, 1)
        #expect(lines.map(\.field) == ["era.none"])
        let reason = Convergence.evidence(try #require(lines.first))["reason"] as? String ?? ""
        #expect(reason.contains("never answered") && reason.contains("GenerationTimeout"), "\(reason)")
        #expect(try Convergence.planned(fixture, root: root).isEmpty)
    }

    @Test("RED→GREEN: a clip past its cap and a worker death fail their unit twice, then are given up — the job never loops on them")
    func timeoutsAndDeathsAreGivenUp() async throws {
        let fixture = try await EraFixture.catalog([
            EraFixture.File(n: 1, path: "/synthetic/1970/hang.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/die.mov"),
        ])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try await Convergence.runJob(fixture, root: root, clipTimeout: .seconds(2))
        #expect(first.contains("1 timeout, 1 worker death"), "\(first)")
        _ = try await Convergence.runJob(fixture, root: root, clipTimeout: .seconds(2))
        let third = try await Convergence.runJob(fixture, root: root, clipTimeout: .seconds(2))
        #expect(third.contains("2 given up at the 3-try limit"), "\(third)")
        let reasons = try EraFixture.lines(root).filter { $0.field == "era.none" }
            .map { Convergence.evidence($0)["reason"] as? String ?? "" }.sorted()
        #expect(reasons.count == 2)
        #expect(reasons.contains { $0.contains("past its cap") }, "\(reasons)")
        #expect(reasons.contains { $0.contains("worker died") }, "\(reasons)")
        #expect(try Convergence.planned(fixture, root: root).isEmpty)
    }

    @Test("a file that recovers before the limit gets its era, no give-up, and its tries are cleared")
    func aFileThatRecoversGetsItsEra() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/flaky.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let clipLog = ClipWorkerFixture.temporaryFile("flaky")
        defer { try? FileManager.default.removeItem(at: clipLog) }
        for _ in 0..<EraAttemptStore.maxTries { try await Convergence.runJob(fixture, root: root, clipLog: clipLog) }
        let lines = try Convergence.lines(root, 1)
        #expect(lines.filter { $0.field == "era.fused" }.map(\.value) == ["1991-1995"], "\(lines.map(\.field))")
        #expect(!lines.contains { $0.field == "era.none" })
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: Convergence.signer) == 0)
    }

    @Test("ISOLATION: a try is not counted when the file went away while the model looked")
    func aVanishedFileIsNotATry() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/ripfail.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let calls = ReadableCalls()
        let job = try EraJob(try Convergence.setup(fixture, root: root, readable: { _ in calls.next() <= 2 }))   // plan + pre-check
        await #expect(throws: Refusal.self) { _ = try await job.runUnit(0) }
        await job.end()
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: Convergence.signer) == 0)
        #expect(try EraFixture.lines(root).isEmpty)
    }

    @Test("ISOLATION: tries are per signer — another prompt revision's tries do not give this one up")
    func triesArePerSigner() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/ripfail.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let store = try EraAttemptStore(stateRoot: root)
        for _ in 0..<5 { _ = try store.record(digest: EraFixture.hex(1), signer: "machine:other@r9", reason: "old", at: 1) }
        try await Convergence.runJob(fixture, root: root)
        #expect(try EraFixture.lines(root).isEmpty, "one try by this signer is not three")
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: Convergence.signer) == 1)
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: "machine:other@r9") == 5)
    }

    @Test("ISOLATION: a torn attempts file refuses the job in words, naming the file — never a silent give-up or loop")
    func aTornAttemptsFileRefusesTheJob() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/ripfail.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let url = EraAttemptStore.url(stateRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A bad line in the MIDDLE (a torn tail alone is a crash mid-append, tolerated — next test).
        try Data("{ not json\n{\"k\":\"s d\",\"t\":1,\"r\":\"x\",\"a\":1}\n".utf8).write(to: url)
        do {
            _ = try EraJob(try Convergence.setup(fixture, root: root))
            Issue.record("a torn attempts file must refuse the job")
        } catch let refusal as Refusal {
            #expect(refusal.words.contains(url.path), "\(refusal.words)")
        }
    }

    @Test("ISOLATION: a torn LAST line (a crash mid-append) costs one try, never the job; the log is compacted")
    func aTornTailIsOneLostTry() throws {
        let root = try EraFixture.stateRoot()
        let url = EraAttemptStore.url(stateRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"k\":\"s \(EraFixture.hex(1))\",\"t\":2,\"r\":\"x\",\"a\":1}\n{\"k\":\"s \(EraFixture.hex(1))\",\"t\":3".utf8).write(to: url)
        let store = try EraAttemptStore(stateRoot: root)
        #expect(store.tries(digest: EraFixture.hex(1), signer: "s") == 2, "the torn third try is lost: the give-up comes one run later")
        #expect((try String(contentsOf: url, encoding: .utf8)).hasSuffix("\n"), "compacted: no torn tail left for the next append")
        #expect(try store.record(digest: EraFixture.hex(1), signer: "s", reason: "y", at: 2) == 3)
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: "s") == 3)
    }

    @Test("ISOLATION: a model that answers nothing — not even the synthetic clip — is the worker, not the files: nothing counted, the job stops",
          .timeLimit(.minutes(2)))
    func aDeadModelCountsNothingAgainstTheFiles() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/b.mov"),
                                                    EraFixture.File(n: 3, path: "/synthetic/1972/c.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let log = LogLines()
        let factory = EraTestFactory { id in
            // swiftlint:disable:next force_try
            var setup = try! Convergence.setup(fixture, root: root, jobID: id, clipTimeout: .seconds(2))
            setup.worker.environment?["FAKE_ALL_HANG"] = "1"
            setup.note = { log.write($0) }
            return setup
        }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        _ = await supervisor.enqueue(JobRequest(kind: .era, lane: "model", requestedBy: "test"))
        await supervisor.drain()
        await factory.closeWorkers()
        for n in 1...3 {
            #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(n), signer: Convergence.signer) == 0, "file \(n)")
        }
        #expect(try EraFixture.lines(root).isEmpty)
        #expect(log.lines.contains { $0.contains("did not answer a 2 s synthetic clip") }, "\(log.lines)")
        let outcome = log.lines.last { $0.hasPrefix("OUTCOME era") } ?? ""
        #expect(outcome.contains("failed"), "the job ends failed, so the kind holds: \(outcome)")
    }

    @Test("TRUTH: the tool check says why when ffmpeg can no longer rip the synthetic clip")
    func theToolCheckSaysWhy() throws {
        let root = try EraFixture.stateRoot()
        let environment = try SubprocessEnvironment.mediaTools(inheriting: ProcessInfo.processInfo.environment)
        let canary = try EraCanary(environment: environment, stateRoot: root)
        #expect(canary.toolWorks(environment: environment) == nil)
        try FileManager.default.removeItem(at: canary.clip)
        let why = canary.toolWorks(environment: environment)
        #expect(why?.isEmpty == false, "ffmpeg's words, not a bare false")
    }

    @Test("COMPAT: the attempts file round-trips and an absent file is no tries")
    func attemptsRoundTrip() throws {
        let root = try EraFixture.stateRoot()
        let store = try EraAttemptStore(stateRoot: root)
        #expect(store.tries(digest: EraFixture.hex(1), signer: "s") == 0)
        #expect(try store.record(digest: EraFixture.hex(1), signer: "s", reason: "r1", at: 10) == 1)
        #expect(try store.record(digest: EraFixture.hex(1), signer: "s", reason: "r2", at: 11) == 2)
        let again = try EraAttemptStore(stateRoot: root)
        #expect(again.tries(digest: EraFixture.hex(1), signer: "s") == 2)
        try again.clear(digest: EraFixture.hex(1), signer: "s")
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: "s") == 0)
    }

    /// The end-to-end shape of the bug: the helper's own schedule over a mixed
    /// catalog must SETTLE — plan 0, nothing active — with no file analyzed
    /// more than three times.
    @Test("RED→GREEN E2E: the helper's schedule settles a mixed catalog — plan 0, idle, ≤ 3 analyses per file", .timeLimit(.minutes(3)))
    func theScheduleSettles() async throws {
        let names = ["a.mov", "blank.mov", "stamp.mov", "ripfail.mov", "generr.mov", "hang.mov", "die.mov", "flaky.mov"]
        let files = names.enumerated().map { i, name in EraFixture.File(n: i + 1, path: "/synthetic/\(1970 + i)/\(name)") }
        let fixture = try await EraFixture.catalog(files)
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let clipLog = ClipWorkerFixture.temporaryFile("settle")
        defer { try? FileManager.default.removeItem(at: clipLog) }
        let catalog = fixture.url
        let era = JobSchedule.Kind(kind: .era, planSize: {
            let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
            return try EraPlanner.plan(catalogURL: catalog, journal: journal, signer: Convergence.signer, limit: nil, jobID: JobID(),
                                       isReadable: { _ in true }).units.count
        }, makeRequest: { JobRequest(kind: .era, lane: "model", requestedBy: "schedule") })
        var schedule = JobSchedule(kinds: [era], generation: { 1 }, buildID: "test", holds: ScheduleHoldStore.beside(stateRoot: root))
        schedule.planInterval = .milliseconds(50)
        schedule.pollInterval = .milliseconds(20)
        let log = LogLines()
        let factory = EraTestFactory { id in
            // swiftlint:disable:next force_try
            try! Convergence.setup(fixture, root: root, jobID: id, clipTimeout: .seconds(2), log: clipLog)
        }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration(),
                                       schedule: schedule)
        await supervisor.start()
        let settled = await BackgroundFixtures.waitUntil(.seconds(150)) {
            let status = await supervisor.status(processIdentifier: 1, startedAt: Date())
            let idle = status.jobs.allSatisfy { !$0.state.isActive }
            return status.planned?["era"] == 0 && idle
        }
        await supervisor.abandonForTest()
        await factory.closeWorkers()
        #expect(settled, "the schedule never settled: \(log.lines.filter { $0.hasPrefix("OUTCOME") || $0.hasPrefix("START") })")
        let analyses = Dictionary(grouping: ClipWorkerFixture.lines(clipLog).filter { $0.hasPrefix("analyze ") }, by: { $0 }).mapValues(\.count)
        #expect(analyses.values.allSatisfy { $0 <= EraAttemptStore.maxTries }, "\(analyses)")
        let verdicts = Dictionary(grouping: try EraFixture.lines(root), by: \.subjectID)
            .mapValues { lines in lines.contains { $0.field == "era.fused" } ? "era" : lines.contains { $0.field == "era.none" } ? "none" : "?" }
        let expected = ["a.mov": "era", "blank.mov": "none", "stamp.mov": "era", "ripfail.mov": "none", "generr.mov": "none",
                        "hang.mov": "none", "die.mov": "none", "flaky.mov": "era"]
        for (i, name) in names.enumerated() {
            #expect(verdicts[EraFixture.hex(i + 1)] == expected[name], "\(name): \(verdicts[EraFixture.hex(i + 1)] ?? "no verdict")")
        }
        #expect(!log.lines.contains { $0.contains("held after a failure") }, "a settled schedule holds nothing")
        #expect(!log.lines.contains { $0.hasPrefix("OUTCOME era") && $0.contains("failed:") && $0.contains("— failed") }, "no job ended failed")
    }
}

// MARK: - Real media through bench.py's real ripper (fake model)

enum MediaMatrix {
    struct Made { var name: String; var url: URL; var duration: Double; var good: Bool }

    static func ffmpeg() throws -> String {
        try #require(FFmpegLocator.ffmpegIsAvailable(), "ffmpeg is required for the media matrix (Brewfile)")
        return FFmpegLocator.ffmpegPath
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let words = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 { throw Refusal("ffmpeg \(args.joined(separator: " ")) failed: \(words.suffix(400))") }
    }

    /// Four-second synthetic test patterns (no family media), plus two files that will not decode.
    static func make(in dir: URL) throws -> [Made] {
        let ff = try ffmpeg()
        let src = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4"]
        let dvsrc = ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000"]
        let good: [(String, [String])] = [
            ("h264.mp4", src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]),
            ("prores.mov", src + ["-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
            ("ffv1.mkv", src + ["-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            ("mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc=size=720x576:rate=25:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000",
                           "-c:v", "mpeg2video", "-b:v", "8M", "-c:a", "pcm_s16le"]),
            ("dv.avi", dvsrc + ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"]),
        ]
        var out: [Made] = []
        for (name, args) in good {
            let url = dir.appendingPathComponent(name)
            try run(ff, ["-nostdin", "-y", "-loglevel", "error"] + args + ["-shortest", url.path])
            out.append(Made(name: name, url: url, duration: 4, good: true))
        }
        // A QuickTime whose index promises 4 s but whose media is gone (the reference-movie shape).
        let whole = dir.appendingPathComponent("whole.mov")
        try run(ff, ["-nostdin", "-y", "-loglevel", "error"] + src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", whole.path])
        let data = try Data(contentsOf: whole)
        let truncated = dir.appendingPathComponent("truncated.mov")
        try data.prefix(min(data.count, 6_000)).write(to: truncated)
        try FileManager.default.removeItem(at: whole)
        out.append(Made(name: "truncated.mov", url: truncated, duration: 4, good: false))
        // Garbage that the catalog once probed as 30 s of video.
        let garbage = dir.appendingPathComponent("garbage.mov")
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }).write(to: garbage)
        out.append(Made(name: "garbage.mov", url: garbage, duration: 30, good: false))
        return out
    }
}

@Suite("EraJob — real frames from real files (media matrix)", .serialized)
struct EraJobMediaMatrixTests {

    @Test("MEDIA: every container's good file gets an era; undecodable files are given up with ffmpeg's words; the next plan is empty",
          .timeLimit(.minutes(3)))
    func theMediaMatrixSettles() async throws {
        let dir = try BackgroundFixtures.scratch("era-media")
        defer { try? FileManager.default.removeItem(at: dir) }
        let made = try MediaMatrix.make(in: dir)
        let fixture = try await EraFixture.catalog(made.enumerated().map { i, m in
            EraFixture.File(n: i + 1, path: m.url.path, duration: m.duration)
        })
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        var outcomes: [String] = []
        for _ in 0..<EraAttemptStore.maxTries {
            outcomes.append(try await Convergence.runJob(fixture, root: root, factory: "make_real_rip_service", clipTimeout: .seconds(60)))
        }
        for (i, m) in made.enumerated() {
            let lines = try Convergence.lines(root, i + 1)
            if m.good {
                #expect(lines.filter { $0.field == "era.fused" }.map(\.value) == ["1990-1995"], "\(m.name): \(lines.map(\.field)) — \(outcomes)")
            } else {
                let none = lines.filter { $0.field == "era.none" }
                #expect(none.count == 1 && lines.count == 1, "\(m.name): \(lines.map(\.field))")
                let reason = none.first.map { Convergence.evidence($0)["reason"] as? String ?? "" } ?? ""
                #expect(reason.hasPrefix("gave up after 3 tries: ") && reason.contains("would not decode"), "\(m.name): \(reason)")
                #expect(reason.contains("ffmpeg:"), "\(m.name): ffmpeg's own words are kept: \(reason)")
            }
        }
        #expect(try Convergence.planned(fixture, root: root).isEmpty, "\(outcomes)")
    }
}
