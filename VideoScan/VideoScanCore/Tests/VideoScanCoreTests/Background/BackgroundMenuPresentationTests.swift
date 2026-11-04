// BackgroundMenuPresentationTests.swift — the menu bar item's words and glyph
// (Rick 2026-11-03). LOGIC: every service state → icon, headline, job lines;
// TRUTH: the numbers are the snapshot's, never invented.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Background menu bar item — words and glyph from the service status")
struct BackgroundMenuPresentationTests {
    static func job(_ state: JobRunState, done: Int = 1_203, total: Int = 4_709) -> JobProgressSnapshot {
        JobProgressSnapshot(id: JobID(), kind: .era, lane: "model", title: "Machine era (8B)", subtitle: "",
                            completedUnits: done, totalUnits: total, skippedUnits: 0, failedUnits: 0,
                            state: state, startedAt: Date(), finishedAt: nil)
    }
    static func status(_ backoff: BackoffState, _ jobs: [JobProgressSnapshot]) -> ServiceStatus {
        ServiceStatus(processIdentifier: 4242, startedAt: Date(), backoff: backoff, jobs: jobs, idleSeconds: 3)
    }

    @Test("idle: outline glyph, 'idle', no job lines; a finished job is not shown")
    func idle() {
        let p = BackgroundMenuPresentation.from(Self.status(.trickle, [Self.job(.finished)]))
        #expect(p.icon == .idle)
        #expect(p.headline == "VideoScan Background — idle")
        #expect(p.jobs.isEmpty)
        #expect(p.tooltip == "VideoScan Background — idle, nothing queued")
    }

    @Test("working: filled glyph, the backoff in plain words, the snapshot's own numbers, Pause offered")
    func working() {
        let p = BackgroundMenuPresentation.from(Self.status(.trickle, [Self.job(.running)]))
        #expect(p.icon == .working)
        #expect(p.headline == "VideoScan Background — gently (you're at the Mac)")
        #expect(p.jobs.map(\.words) == ["Machine era (8B) — 1,203 of 4,709 · running"])
        #expect(p.jobs[0].canPause && !p.jobs[0].canResume)
        #expect(p.tooltip.contains("1,203 of 4,709"))
        let away = BackgroundMenuPresentation.from(Self.status(.full, [Self.job(.running)]))
        #expect(away.headline == "VideoScan Background — full speed (you're away)")
    }

    @Test("paused: by the user (every active job paused) or by the service (thermal) — pause glyph, Resume offered")
    func paused() {
        let user = BackgroundMenuPresentation.from(Self.status(.trickle, [Self.job(.paused(reason: "by you"))]))
        #expect(user.icon == .paused)
        #expect(user.jobs[0].canResume && !user.jobs[0].canPause)
        #expect(user.jobs[0].words.hasSuffix("paused (by you)"))
        let thermal = BackgroundMenuPresentation.from(Self.status(.paused(reason: "thermal"), [Self.job(.running)]))
        #expect(thermal.icon == .paused)
        #expect(thermal.headline == "VideoScan Background — paused (thermal)")
    }

    @Test("an unknown total says what is known, never a made-up denominator")
    func unknownTotal() {
        let p = BackgroundMenuPresentation.from(Self.status(.full, [Self.job(.running, done: 12, total: 0)]))
        #expect(p.jobs[0].words == "Machine era (8B) — 12 done · running")
    }
}

// MARK: - Reviewer reds (fresh-eyes review of 3c5d5e6f, 2026-11-03), lifted
// from the review-1103 worktree (doubles renamed: BackgroundWaitingTruthTests
// has its own DeferringJob).

/// A job whose every unit defers — EraJob while Backoff says trickle and the
/// model is not loaded (EraJob.swift:174).
struct ReviewDeferringJob: BackgroundJob {
    let title = "Machine era (8B)"
    let unitCount = 3
    func runUnit(_ index: Int) async throws -> UnitOutcome { .deferred(reason: EraJob.deferWords) }
}

struct ReviewDeferringFactory: JobFactory {
    static let kind = JobKind(rawValue: "review-deferring")
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { ReviewDeferringJob() }
}

@Suite("Background menu bar item — reviewer reds (2026-11-03)")
struct BackgroundMenuPresentationReviewTests {

    @Test("TRUE: an era job waiting for Rick to step away is not 'running' — the lens must not fill and the line must not say running")
    func deferredJobIsNotShownRunning() async throws {
        let source = FakeActivitySource(ActivitySample(secondsSinceLastInput: 5))   // Rick is typing → trickle
        let backoff = Backoff(source: source, trickleInterval: .milliseconds(5))
        var configuration = BackgroundFixtures.fastConfiguration()
        configuration.deferRetryInterval = .milliseconds(20)
        let log = InMemoryBackgroundLog()
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                                       factory: ReviewDeferringFactory(), backoff: backoff, log: log, configuration: configuration)
        _ = await supervisor.enqueue(JobRequest(kind: ReviewDeferringFactory.kind, requestedBy: "test"))
        let said = await BackgroundFixtures.waitUntil { log.lines.contains { $0.contains("waits at 0 of 3") } }
        #expect(said, "the supervisor logged the wait: \(log.lines)")
        let status = await supervisor.status(processIdentifier: 1, startedAt: Date())
        let p = BackgroundMenuPresentation.from(status)
        #expect(status.backoff == .trickle)
        #expect(p.icon != .working,
                "the filled lens means a unit is being worked; this job is waiting — JobSupervisor.swift:368 leaves .running while every unit defers")
        #expect(!(p.jobs.first?.words.hasSuffix("running") ?? false), "menu line: \(p.jobs.first?.words ?? "-")")
        await supervisor.abandonForTest()
    }

    @Test("a status READ is not activity: the menu bar's 5 s poll must not keep the helper alive past its idle exit")
    func statusReadDoesNotResetIdle() async throws {
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                                       factory: ReviewDeferringFactory(), backoff: BackgroundFixtures.fullBackoff(),
                                       log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration())
        await supervisor.start()
        try await Task.sleep(for: .milliseconds(300))
        // StatusMenuController.swift:50 — every 5 s for the life of the process.
        _ = await supervisor.status(processIdentifier: 1, startedAt: Date())
        #expect(await supervisor.shouldExitWhenIdle(threshold: 0.2),
                "JobSupervisor.swift:281 touch() on status: every poll resets idleSeconds, so IdleExitPolicy never fires")
    }

    @Test("a queued job is not working: the filled lens says a unit is being worked")
    func queuedIsNotWorking() {
        let p = BackgroundMenuPresentation.from(
            BackgroundMenuPresentationTests.status(.full, [BackgroundMenuPresentationTests.job(.queued, done: 0)]))
        #expect(p.icon != .working, "BackgroundMenuPresentation.swift:38 counts .queued as running")
    }
}
