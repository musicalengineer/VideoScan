// EraJobRetryReviewTests.swift — review tests for fix/era-unrippable-retry-loop
// (Fable review 2026-11-04). Each test is RED on the branch as reviewed and
// names the line it pins. Synthetic media (ffmpeg lavfi) only.
//
//   ISOLATION  a TOOL that is broken for every file (ffmpeg on disk and
//              executable, so SubprocessEnvironment.mediaTools accepts it, but
//              failing on every rip) must not spend a decodable file's three
//              tries and give it up for good.
//   LOGIC      a plan that holds only clips past their cap is HELD after run 1
//              (zero progress) and never reaches try 3: the header's "every
//              planned file reaches a verdict in a bounded number of runs" does
//              not hold for it.
//   TRUTH      OUTCOME's "retried next run (generation errors or frames that
//              would not rip)" now also counts timeouts and worker deaths.
//   SCALE      recording one try rewrites every entry (O(n) per unit).

import Foundation
import Testing
@testable import VideoScanCore

enum RetryReview {
    /// Convergence.setup with a worker environment the test controls (VS_FFMPEG_PATH).
    static func setup(_ fixture: StoreFixture, root: URL, jobID: JobID, factory: String, clipTimeout: Duration,
                      environment: [String: String]) throws -> EraJob.Setup {
        var worker = ClipWorkerFixture.configuration(factory, clipTimeout: clipTimeout)
        worker.environment = try SubprocessEnvironment.mediaTools(inheriting: environment)
        return EraJob.Setup(jobID: jobID, catalogURL: fixture.url, stateRoot: root, worker: worker)
    }

    @discardableResult
    static func runJob(_ fixture: StoreFixture, root: URL, factory: String, clipTimeout: Duration, environment: [String: String],
                       log: LogLines = LogLines()) async throws -> String {
        let jobFactory = EraTestFactory { id in
            // swiftlint:disable:next force_try
            try! Self.setup(fixture, root: root, jobID: id, factory: factory, clipTimeout: clipTimeout, environment: environment)
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

    /// An `ffmpeg` that is on disk and executable (mediaTools accepts it) but
    /// decodes nothing: the shape of a Homebrew upgrade that broke a dylib.
    static func brokenFFmpeg(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\necho 'dyld[4242]: Library not loaded: @rpath/libavcodec.62.dylib' >&2\nexit 134\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

@Suite("EraJob — retry-limit review (Fable 2026-11-04)", .serialized)
struct EraJobRetryReviewTests {

    @Test("RED: a tool broken for every file must not give up decodable files — EraJob.swift:229-233 counts a systemic rip failure as a try",
          .timeLimit(.minutes(3)))
    func aBrokenRipperDoesNotGiveUpDecodableFiles() async throws {
        let dir = try BackgroundFixtures.scratch("era-broken-ffmpeg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ff = try MediaMatrix.ffmpeg()
        let good = dir.appendingPathComponent("h264.mp4")
        try MediaMatrix.run(ff, ["-nostdin", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=4",
                                 "-c:v", "libx264", "-pix_fmt", "yuv420p", good.path])
        let broken = try RetryReview.brokenFFmpeg(in: dir.appendingPathComponent("bin", isDirectory: true))
        var environment = ProcessInfo.processInfo.environment
        environment[FFmpegLocator.ffmpegEnvVar] = broken.path

        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: good.path, duration: 4)])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        // Three runs' worth of attempts: each is refused before any unit (EraCanary at START).
        for _ in 0..<EraAttemptStore.maxTries {
            do {
                _ = try EraJob(try RetryReview.setup(fixture, root: root, jobID: JobID(), factory: "make_real_rip_service",
                                                     clipTimeout: .seconds(60), environment: environment))
                Issue.record("a broken ffmpeg must refuse the job")
            } catch let refusal as Refusal {
                #expect(refusal.words.contains("cannot make a 2 s synthetic clip") && refusal.words.contains("Library not loaded"), "\(refusal.words)")
            }
        }
        let lines = try Convergence.lines(root, 1)
        let reasons = lines.map { Convergence.evidence($0)["reason"] as? String ?? $0.field }
        #expect(!lines.contains { $0.field == "era.none" },
                "a decodable file was given up for good because the TOOL was broken, not the file: \(reasons)")
        #expect(try Convergence.planned(fixture, root: root) == [EraFixture.hex(1)], "it must be planned again once ffmpeg works")
    }

    @Test("RED: a plan of only clips past their cap never reaches try 3 — JobSupervisor.swift:706 holds the kind after run 1 (zero progress) and EraJob.swift:222 re-throws below the limit; the plan size never changes, so the hold never releases",
          .timeLimit(.minutes(2)))
    func aPlanOfOnlyTimeoutsStillReachesAVerdict() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/hang.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
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
            try! Convergence.setup(fixture, root: root, jobID: id, clipTimeout: .seconds(2))
        }
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration(),
                                       schedule: schedule)
        await supervisor.start()
        // Three tries at a 2 s cap plus three worker spawns: well inside 45 s when nothing holds.
        let settled = await BackgroundFixtures.waitUntil(.seconds(45)) {
            let status = await supervisor.status(processIdentifier: 1, startedAt: Date())
            let idle = status.jobs.allSatisfy { !$0.state.isActive }
            return status.planned?["era"] == 0 && idle
        }
        await supervisor.abandonForTest()
        await factory.closeWorkers()
        #expect(settled, "the one file never reached a verdict: \(log.lines.filter { $0.hasPrefix("OUTCOME") || $0.contains("held") })")
        #expect(try Convergence.lines(root, 1).map(\.field) == ["era.none"], "given up after \(EraAttemptStore.maxTries) tries")
        #expect(try EraAttemptStore(stateRoot: root).tries(digest: EraFixture.hex(1), signer: Convergence.signer) == 0)
    }

    @Test("RED: OUTCOME counts a clip past its cap and a worker death as 'retried next run (generation errors or frames that would not rip)' — EraJob.swift:248, 385, 412")
    func theOutcomeDoesNotCallATimeoutAGenerationError() async throws {
        let fixture = try await EraFixture.catalog([
            EraFixture.File(n: 1, path: "/synthetic/1970/hang.mov"), EraFixture.File(n: 2, path: "/synthetic/1971/die.mov"),
        ])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let outcome = try await Convergence.runJob(fixture, root: root, clipTimeout: .seconds(2))
        #expect(outcome.contains("1 timeout, 1 worker death"), "\(outcome)")
        #expect(outcome.contains("tried again next run: 0 frames would not decode, 0 model never answered, 2 timeout or worker death"), "\(outcome)")
        // The sentence, where it appears, must be true: nothing here was a generation error or a frame that would not rip.
        if let range = outcome.range(of: " retried next run (generation errors or frames that would not rip)") {
            let n = Int(outcome[..<range.lowerBound].split(separator: " ").last ?? "")
            #expect(n == 0, "a timeout and a death are reported as generation errors / rip failures: \(outcome)")
        }
    }

    @Test("SCALE: recording one try must not rewrite every entry — EraAttempts.swift:76-89 publish the whole map per record (O(n) per unit, O(n²) per run)")
    func recordingATryDoesNotRewriteEveryEntry() throws {
        let clock = ContinuousClock()
        let empty = try EraAttemptStore(stateRoot: try EraFixture.stateRoot())
        let small = try clock.measure {
            for i in 0..<100 { try empty.record(digest: EraFixture.hex(i), signer: "s", reason: "frames would not decode", at: 1) }
        }
        // 20,000 files without a verdict (a volume of Avid essences at the 100k bar), written directly.
        let root = try EraFixture.stateRoot()
        let url = EraAttemptStore.url(stateRoot: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var seeded = ""
        for i in 0..<20_000 { seeded += "{\"k\":\"s \(EraFixture.hex(1_000_000 + i))\",\"t\":1,\"r\":\"frames would not decode\",\"a\":1}\n" }
        try Data(seeded.utf8).write(to: url)
        let loaded = try EraAttemptStore(stateRoot: root)
        #expect(loaded.tries(digest: EraFixture.hex(1_000_000), signer: "s") == 1, "the seed was read")
        let large = try clock.measure {
            for i in 0..<100 { try loaded.record(digest: EraFixture.hex(i), signer: "s", reason: "frames would not decode", at: 1) }
        }
        print("EraAttemptStore: 100 records on an empty store \(small); on 20,000 entries \(large)")
        #expect(large < small * 4, "a try's cost grows with the number of files waiting: \(small) → \(large)")
    }
}
