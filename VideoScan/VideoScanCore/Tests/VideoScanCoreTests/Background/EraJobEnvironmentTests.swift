// EraJobEnvironmentTests.swift — the era job under launchd's environment
// (bug 2026-11-03, M5 Ultra background.log 20:05–20:49: job 76A5CC1E ran 523
// units under the launchd-started helper and every one failed "the worker
// raised FileNotFoundError: [Errno 2] No such file or directory: 'ffmpeg'";
// OUTCOME "0 run · 0 skipped · 523 failed … 523 other").
//   REGRESSION  the worker the factory builds, started with launchd's minimal
//               PATH (/usr/bin:/bin:/usr/sbin:/sbin), finds ffprobe and ffmpeg
//               — the fake service shells out to both by bare name, exactly
//               as bench.py does.
//   REGRESSION  fail fast: the first units all failing with the same worker
//               error stop the job — failed, the error named once, the
//               remaining units never tried, the queue file gone.
//   RETRY       units that failed write nothing, so the next plan holds them all.
//   ISOLATION   no ffmpeg on the Mac → the job is refused at plan/START in
//               words that name the tool and every place looked; never per unit.
// Synthetic digests and paths only; the fake ClipService (no model).

import Foundation
import Testing
@testable import VideoScanCore

enum EraEnvironmentFixture {
    /// What launchd hands a user agent: no Homebrew on PATH (`launchctl print gui/<uid>` → PATH).
    static let launchdPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
    static var launchd: [String: String] {
        ["PATH": launchdPATH, "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
    }

    /// A model folder the factory accepts (config.json present); the fake service never reads it.
    static func modelDir() throws -> URL {
        let dir = try BackgroundFixtures.scratch("era-model")
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        return dir
    }

    /// An era request whose worker is the repo's bench.py on the fixture interpreter.
    static func request(model: URL, id: JobID = JobID()) -> JobRequest {
        JobRequest(id: id, kind: .era, lane: "model",
                   parameters: [EraJob.repoPathKey: ClipWorkerFixture.repo.path, EraJob.pythonKey: ClipWorkerFixture.python.path,
                                EraJob.modelDirKey: model.path],
                   requestedBy: "test")
    }

    /// The factory's own Setup for `environment` (the helper's inherited one),
    /// with only the ClipService swapped for the fake: same interpreter, same
    /// bench.py, same environment the production path built.
    static func productionSetup(_ fixture: StoreFixture, root: URL, model: URL, environment: [String: String],
                                id: JobID = JobID(), log: URL? = nil) throws -> EraJob.Setup {
        var setup = try EraJob.setup(for: request(model: model, id: id), stateRoot: root, catalogURL: fixture.url,
                                     backoff: nil, environment: environment)
        setup.worker.factory = ClipWorkerFixture.factory()
        setup.isReadable = { _ in true }                     // synthetic paths
        if let log { setup.worker.environment?["FAKE_CLIP_LOG"] = log.path }
        return setup
    }
}

@Suite("EraJob — under launchd's environment (2026-11-03)", .serialized)
struct EraJobEnvironmentTests {

    /// Red on main 6f2934a8: the worker inherited the helper's PATH and the
    /// fake's `ffprobe -version` raised FileNotFoundError, as bench.py did.
    @Test func underLaunchdsMinimalPATHTheWorkerFindsFFprobeAndFFmpeg() async throws {
        try #require(FFmpegLocator.ffmpegIsAvailable(), "ffmpeg is a dev prerequisite (Brewfile)")
        // Not vacuous: neither tool may be on launchd's PATH itself.
        for dir in EraEnvironmentFixture.launchdPATH.split(separator: ":") {
            for tool in ["ffmpeg", "ffprobe"] {
                try #require(!FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)"), "\(dir)/\(tool) exists — this test proves nothing here")
            }
        }
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/tools.mov")])
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let job = try EraJob(EraEnvironmentFixture.productionSetup(fixture, root: root, model: try EraEnvironmentFixture.modelDir(),
                                                                   environment: EraEnvironmentFixture.launchd))
        try #require(job.unitCount == 1)
        do {
            #expect(try await job.runUnit(0) == .done)
        } catch {
            Issue.record("the unit failed under launchd's PATH: \(error)")
        }
        await job.end()
        #expect(Set(try EraFixture.lines(root).map(\.subjectID)) == [EraFixture.hex(1)], "the unit wrote its lines")
    }

    /// Red on main 6f2934a8: "finished: 0 run · 0 skipped · 7 failed", seven
    /// clips tried, seven failure lines, the queue file removed as "finished".
    @Test func theFirstUnitsFailingWithTheSameWorkerErrorStopTheJobAndSayItOnce() async throws {
        let n = 7
        let fixture = try await EraFixture.catalog((1...n).map { EraFixture.File(n: $0, path: "/synthetic/19\(70 + $0)/boom.mov") })
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let clips = ClipWorkerFixture.temporaryFile("era-boom")
        defer { try? FileManager.default.removeItem(at: clips) }
        let log = LogLines()
        let queue = InMemoryJobQueueStore()
        let supervisor = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(),
                                       factory: EraTestFactory { EraFixture.setup(fixture, root: root, jobID: $0, log: clips) },
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        let request = JobRequest(kind: .era, lane: "model", requestedBy: "test")
        _ = await supervisor.enqueue(request)
        await supervisor.drain()
        let words = "the worker raised RuntimeError: deliberate"
        let outcome = log.lines.first { $0.hasPrefix("OUTCOME era") } ?? ""
        #expect(outcome.contains("failed:") && outcome.contains(words), "OUTCOME names the error: \(outcome)")
        #expect(outcome.contains("0 run · 0 skipped · 5 failed"), "\(outcome)")
        #expect(ClipWorkerFixture.lines(clips).filter { $0.hasPrefix("analyze") }.count == 5, "units 5 and 6 were never tried")
        #expect(log.lines.filter { $0.contains(words) && !$0.hasPrefix("OUTCOME") }.count == 1, "the error's words are logged once: \(log.lines)")
        let state = await supervisor.snapshot(request.id)?.state
        guard case .failed(let reason)? = state else { Issue.record("the job is \(String(describing: state)), not failed"); return }
        #expect(reason.contains(words))
        #expect(queue.list().requests.isEmpty, "the queue file goes: the app's next recount queues a fresh job")
    }

    /// Confirms (green on main too): a failed unit writes nothing, so every
    /// one of the failed units is planned again by the next job.
    @Test func unitsThatFailedAreAllPlannedAgain() async throws {
        let fixture = try await EraFixture.catalog((1...3).map { EraFixture.File(n: $0, path: "/synthetic/19\(70 + $0)/boom.mov") })
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let first = try EraJob(EraFixture.setup(fixture, root: root))
        for i in 0..<first.unitCount {
            await #expect(throws: PythonClipWorkerError.self) { _ = try await first.runUnit(i) }
        }
        await first.end()
        #expect(try EraFixture.lines(root).isEmpty, "a failed unit writes no journal line")
        let second = try EraJob(EraFixture.setup(fixture, root: root))
        #expect(Set(second.plan.units.map(\.digest)) == Set((1...3).map(EraFixture.hex)), "every failed file comes back")
        #expect(second.plan.cached == 0)
        await second.end()
    }
}

@Suite("Background menu bar item — a failed job says so (2026-11-03)")
struct BackgroundMenuFailedJobTests {

    /// Red on main 6f2934a8: a failed job left the menu with no line at all.
    @Test func aFailedEraJobIsShownWithItsReasonUntilAnotherOfItsKindStarts() {
        var failed = BackgroundMenuPresentationTests.job(.failed(reason: "5 units in a row failed: the worker raised X"), done: 5, total: 523)
        failed.finishedAt = Date()
        let p = BackgroundMenuPresentation.from(BackgroundMenuPresentationTests.status(.full, [failed]))
        #expect(p.jobs.map(\.words) == ["Machine era (8B) — 5 of 523 · failed: 5 units in a row failed: the worker raised X"])
        #expect(p.jobs.allSatisfy { !$0.canPause && !$0.canResume })
        #expect(p.icon == .idle)
        #expect(p.tooltip.contains("failed: 5 units in a row failed"), "\(p.tooltip)")
        // A newer job of the same kind replaces it.
        var newer = BackgroundMenuPresentationTests.job(.running, done: 1, total: 518)
        newer.startedAt = Date().addingTimeInterval(60)
        let q = BackgroundMenuPresentation.from(BackgroundMenuPresentationTests.status(.full, [failed, newer]))
        #expect(q.jobs.map(\.words) == ["Machine era (8B) — 1 of 518 · running"])
    }
}
