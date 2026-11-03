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
