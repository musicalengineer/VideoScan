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
        #expect(away.headline == "VideoScan Background — full speed", "no 'you're away': the helper runs whether or not Rick is at the Mac")
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

    @Test("HOLD: a held kind has its own line with Resume (and no Pause), the outline glyph, and its failed job's line is not repeated")
    func heldKindHasResume() {
        var failed = Self.job(.failed(reason: "the worker could not load the model"))
        failed.finishedAt = Date()
        var s = Self.status(.full, [failed])
        s.holds = [ScheduleHold(kind: .era, jobID: failed.id, reason: "the worker could not load the model", build: "b1", generation: 7)]
        let p = BackgroundMenuPresentation.from(s)
        #expect(p.icon == .waiting)
        #expect(p.headline == "VideoScan Background — held after a failure")
        #expect(p.jobs.count == 1, "\(p.jobs.map(\.words))")
        #expect(p.jobs[0].id == failed.id)
        #expect(p.jobs[0].canResume && !p.jobs[0].canPause)
        #expect(p.jobs[0].words.contains("held after a failure: the worker could not load the model"))
        #expect(p.jobs[0].words.contains("Resume, a new build or a catalog change clears it"))
    }

    @Test("HOLD after a restart: no job is listed, the hold still has its line and Resume, titled by kind")
    func heldKindAfterRestart() {
        var s = Self.status(.full, [])
        s.holds = [ScheduleHold(kind: .era, jobID: JobID(rawValue: "old"), reason: "x", build: "b1", generation: nil, sticky: true)]
        let p = BackgroundMenuPresentation.from(s)
        #expect(p.jobs.map(\.words) == ["Machine era (8B) — held after a failure: x — Resume or a new build clears it"])
        #expect(p.jobs[0].canResume)
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

@Suite("Background menu bar item — reviewer reds (2026-11-03)")
struct BackgroundMenuPresentationReviewTests {

    @Test("a queued job is not working: the filled lens says a unit is being worked")
    func queuedIsNotWorking() {
        let p = BackgroundMenuPresentation.from(
            BackgroundMenuPresentationTests.status(.full, [BackgroundMenuPresentationTests.job(.queued, done: 0)]))
        #expect(p.icon != .working, "BackgroundMenuPresentation.swift:38 counts .queued as running")
    }
}
