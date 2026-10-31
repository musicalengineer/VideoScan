// JobSupervisorScaleTests.swift — SCALE (design §6): 100k queued units
// planned inside a stated budget; progress pushes capped at 4/s under a
// 10k-unit NoOpJob.
//
// Budgets (Debug, load-aware via TimingBudget): planning 100k requests
// 2 s — measured 2026-10-30 on the M5 Ultra in Debug beside two other
// workers: ≈ 0.4 s. Not in the sensor lane (NOT_A_LANE_TEST_RE: scale/budget).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("JobSupervisor — SCALE", .serialized)
struct JobSupervisorScaleTests {

    static let planBudget: Duration = .seconds(2)

    @Test("100k queued single-unit requests are planned (scanned and registered) within budget")
    func plan100k() async throws {
        let requests = (0..<100_000).map { i in
            JobRequest(id: JobID(rawValue: String(format: "%06d", i)), kind: .noop, lane: "lane\(i % 4)",
                       parameters: [NoOpJob.unitsKey: "1", NoOpJob.sleepMillisecondsKey: "0"],
                       requestedAt: Date(timeIntervalSince1970: Double(i)), requestedBy: "scale")
        }
        let queue = InMemoryJobQueueStore(requests)
        let supervisor = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(), factory: DefaultJobFactory(),
                                       backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog())
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let began = clock.now
        let planned = await supervisor.plan()
        let elapsed = clock.now - began
        print("[background-scale] planned \(planned) requests in \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(planned == 100_000)
        expectWithinTimingBudget("plan 100k requests", measured: elapsed, budget: Self.planBudget, loadBefore: load)
        #expect(await supervisor.activeJobCount == 100_000)
    }

    @Test("progress pushes are capped at 4/s under a 10k-unit NoOpJob (final push excepted)")
    func progressCap() async throws {
        let counter = InMemoryBackgroundLog(capacity: 100_000)
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: DefaultJobFactory(),
                                       backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog())
        await supervisor.setProgressSink { counter.write("\($0.completedUnits)") }
        let clock = ContinuousClock()
        let began = clock.now
        let request = NoOpJob.request(units: 10_000, sleepMilliseconds: 0, requestedBy: "scale")
        _ = await supervisor.enqueue(request)
        await supervisor.drain()
        let elapsed = clock.now - began
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let pushes = await supervisor.progressPushCount
        print("[background-scale] 10k units in \(elapsed): \(pushes) progress pushes")
        // 4 per second of run time, plus the forced START and OUTCOME pushes.
        #expect(pushes <= Int(seconds * 4) + 3, "pushes \(pushes) over \(seconds) s")
        #expect(counter.lines.last == "10000", "the final state is always pushed")
        #expect(pushes >= 2)
    }
}
