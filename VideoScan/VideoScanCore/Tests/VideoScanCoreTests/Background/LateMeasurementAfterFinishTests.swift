// LateMeasurementAfterFinishTests.swift — Codex sweep 2026-11-09 (catalog
// check scheduling pass, P1 F4). `finish()` drops a scheduled kind's pre-run
// plan size and measures again, but a measurement that STARTED before the job
// (under an older hold) and lands after it still wrote `planned[kind]` before
// planKind rejected it as stale — so a finished job showed its pre-run count
// again ("3 files to analyze" for files already done).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Background — a late pre-run measurement never overwrites the post-run plan (Codex sweep 11/09 F4)")
struct LateMeasurementAfterFinishTests {

    @Test("RED: a measurement begun under hold H1, released after the job ran and the post-run plan said 0, leaves the plan at 0")
    func lateMeasurementIsNotPublished() async throws {
        let root = try BackgroundFixtures.scratch("sweep-f4-late-measure")
        let kind = ScheduleFactory.kind
        let old = ScheduleHold(kind: kind, jobID: JobID(rawValue: "H1"), reason: "x", build: "b1")
        try ScheduleHoldStore.beside(stateRoot: root).save([old])
        let recorder = UnitRecorder()
        let calls = ScheduleProbe()
        let gate = DispatchSemaphore(value: 0)
        let k = JobSchedule.Kind(kind: kind,
                                 planSize: {
                                     _ = calls.planned()
                                     if calls.plans == 1 { gate.wait(); return 3 }   // measured before the job: 3
                                     return max(0, 3 - recorder.completedUnits.count)
                                 },
                                 makeRequest: { JobRequest(kind: kind, requestedBy: "schedule") })
        var schedule = JobSchedule(kinds: [k], generation: { 1 }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        schedule.planInterval = .seconds(3600)
        schedule.pollInterval = .milliseconds(20)
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(), schedule: schedule)
        let planned: @Sendable () async -> Int? = { await s.status(processIdentifier: 1, startedAt: Date()).planned?[kind.rawValue] }
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { calls.plans == 1 }, "tick A is measuring under H1")
        #expect(await s.resume(old.jobID))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "the released kind ran its job")
        #expect(await BackgroundFixtures.waitUntil { (await planned()) == 0 }, "the post-run plan measured 0")
        gate.signal()                                      // tick A lands its pre-run 3
        try await Task.sleep(for: .milliseconds(200))
        let after = await planned()
        #expect(after == 0, "the finished job shows its pre-run plan size again: \(String(describing: after))")
        await s.abandonForTest()
    }
}
