// JobSupervisorTests.swift — the supervisor's lifecycle (design §3, §6 logic):
// START/OUTCOME with counts, one job per lane, checkpoint resume without a
// repeated unit, pause/resume/stop, partial queue files ignored, NoOpJob.
//
// Dimensions: LOGIC. Scale and isolation have their own files beside this.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("JobSupervisor — lifecycle")
struct JobSupervisorTests {

    private func make(queue: any JobQueueStore = InMemoryJobQueueStore(),
                      checkpoints: any CheckpointStore = InMemoryCheckpointStore(),
                      factory: any JobFactory, log: InMemoryBackgroundLog = InMemoryBackgroundLog(),
                      backoff: Backoff = BackgroundFixtures.fullBackoff()) -> JobSupervisor {
        JobSupervisor(queue: queue, checkpoints: checkpoints, factory: factory, backoff: backoff, log: log,
                      configuration: BackgroundFixtures.fastConfiguration())
    }

    @Test("a job runs every unit once and writes START and OUTCOME with run · skipped · failed counts")
    func startAndOutcome() async throws {
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let factory = RecordingFactory(recorder: recorder, units: 6, failAt: [2], skipAt: [4])
        let supervisor = make(factory: factory, log: log)
        let request = RecordingFactory.request()
        #expect(await supervisor.enqueue(request) == .accepted(request.id))
        await supervisor.drain()

        #expect(recorder.completedUnits == [0, 1, 3, 4, 5], "the failed unit threw before recording; every other unit once")
        let start = log.lines.filter { $0.hasPrefix("START recording \(request.id)") }
        let outcome = log.lines.filter { $0.hasPrefix("OUTCOME recording \(request.id)") }
        #expect(start.count == 1)
        #expect(outcome.count == 1)
        #expect(outcome.first?.contains("finished: 4 run · 1 skipped · 1 failed") == true, "\(outcome)")
        let snapshot = await supervisor.snapshot(request.id)
        #expect(snapshot?.state == .finished)
        #expect(snapshot?.completedUnits == 6)
        #expect(snapshot?.finishedAt != nil)
    }

    @Test("one job per lane: two jobs in one lane never overlap; two lanes run beside each other")
    func lanes() async throws {
        let same = UnitRecorder()
        let s1 = make(factory: RecordingFactory(recorder: same, units: 4, sleepPerUnit: .milliseconds(15)))
        _ = await s1.enqueue(RecordingFactory.request(lane: "a"))
        _ = await s1.enqueue(RecordingFactory.request(lane: "a"))
        await s1.drain()
        #expect(same.maxInFlight == 1)
        #expect(same.completedUnits.count == 8)

        let different = UnitRecorder()
        let s2 = make(factory: RecordingFactory(recorder: different, units: 6, sleepPerUnit: .milliseconds(40)))
        _ = await s2.enqueue(RecordingFactory.request(lane: "a"))
        _ = await s2.enqueue(RecordingFactory.request(lane: "b"))
        await s2.drain()
        #expect(different.maxInFlight == 2)
    }

    @Test("a job found with a checkpoint resumes after it and repeats no unit; the log closes the old START with an OUTCOME")
    func resumeFromCheckpoint() async throws {
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let request = RecordingFactory.request()
        let queue = InMemoryJobQueueStore([request])
        let checkpoints = InMemoryCheckpointStore()
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 10)
        cp.completedUnits = 4
        cp.unitsRun = 3
        cp.unitsSkipped = 1
        try checkpoints.save(cp)

        let supervisor = make(queue: queue, checkpoints: checkpoints, factory: RecordingFactory(recorder: recorder, units: 10), log: log)
        await supervisor.start()
        await supervisor.drain()

        #expect(recorder.completedUnits == [4, 5, 6, 7, 8, 9])
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recording \(request.id) — interrupted at 4 of 10") })
        #expect(log.lines.contains { $0.hasPrefix("START recording \(request.id)") && $0.contains("resuming at unit 4") })
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recording \(request.id) — finished: 9 run · 1 skipped · 0 failed") })
        #expect(queue.isEmpty, "a finished job leaves the queue")
        #expect(checkpoints.checkpoint(request.id) == nil)
    }

    @Test("the queue scan ignores a partial file and an in-flight temp, and runs the whole one")
    func partialQueueFile() async throws {
        let dir = try BackgroundFixtures.scratch("queue")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileJobQueueStore(directory: dir.appendingPathComponent("queue"))
        let checkpoints = FileCheckpointStore(directory: dir.appendingPathComponent("checkpoints"))
        let whole = RecordingFactory.request()
        try queue.put(whole)
        let partialID = JobID()
        let partialData = try BackgroundPayloadCodec.encode(RecordingFactory.request(id: partialID)).prefix(40)
        try partialData.write(to: dir.appendingPathComponent("queue/\(partialID).json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("queue/.\(JobID()).json.abc\(AtomicFilePublish.temporarySuffix)"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("queue/notes.txt"))

        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = make(queue: queue, checkpoints: checkpoints, factory: RecordingFactory(recorder: recorder, units: 3), log: log)
        await supervisor.start()
        await supervisor.drain()

        #expect(recorder.completedUnits == [0, 1, 2])
        let ignored = log.lines.filter { $0.hasPrefix("queue: ignored") }
        #expect(ignored.count == 3, "\(ignored)")
        #expect(ignored.contains { $0.contains("\(partialID).json") })
        #expect(ignored.contains { $0.contains("in-flight temp") })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("queue/\(partialID).json").path), "the partial file is left for a person to look at")
        #expect(!queue.contains(whole.id))
    }

    @Test("pause holds the job between units with a paused state; resume continues; stop ends it with a counted OUTCOME")
    func pauseResumeStop() async throws {
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = make(factory: RecordingFactory(recorder: recorder, units: 1_000, sleepPerUnit: .milliseconds(5)), log: log)
        let request = RecordingFactory.request()
        _ = await supervisor.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count >= 3 })
        #expect(await supervisor.pause(request.id))
        #expect(await BackgroundFixtures.waitUntil { await supervisor.snapshot(request.id)?.state == .paused(reason: "user") })
        let atPause = recorder.completedUnits.count
        try await Task.sleep(for: .milliseconds(60))
        #expect(recorder.completedUnits.count == atPause, "no unit runs while paused")

        #expect(await supervisor.resume(request.id))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count > atPause + 2 })
        #expect(await supervisor.stop(request.id))
        await supervisor.drain()

        let snapshot = await supervisor.snapshot(request.id)
        #expect(snapshot?.state == .stopped)
        let outcome = log.lines.filter { $0.hasPrefix("OUTCOME recording \(request.id) — stopped at") }
        #expect(outcome.count == 1, "\(outcome)")
        #expect(outcome.first?.contains("\(recorder.completedUnits.count) run · 0 skipped · 0 failed") == true, "\(outcome)")
        #expect(await supervisor.pause(request.id) == false, "a stopped job takes no verb")
    }

    @Test("an unknown kind or bad parameters are refused at enqueue, in words, and nothing is queued")
    func refusals() async throws {
        let queue = InMemoryJobQueueStore()
        let supervisor = make(queue: queue, factory: DefaultJobFactory())
        let unknown = JobRequest(kind: JobKind(rawValue: "caption"), requestedBy: "test")
        guard case .refused(let r) = await supervisor.enqueue(unknown) else { Issue.record("expected a refusal"); return }
        #expect(r.words.contains("does not know the job kind `caption`"))
        let bad = JobRequest(kind: .noop, parameters: [NoOpJob.unitsKey: "many"], requestedBy: "test")
        guard case .refused(let r2) = await supervisor.enqueue(bad) else { Issue.record("expected a refusal"); return }
        #expect(r2.words.contains("`units` must be a whole number"))
        #expect(queue.isEmpty)
    }

    @Test("NoOpJob reads units and sleepMilliseconds, counts, and resumes from its checkpoint")
    func noOp() async throws {
        let job = try NoOpJob(request: NoOpJob.request(units: 5, sleepMilliseconds: 0, requestedBy: "test"))
        #expect(job.unitCount == 5)
        #expect(job.sleepPerUnit == .zero)
        #expect(try await job.runUnit(0) == .done)
        let defaults = try NoOpJob(request: JobRequest(kind: .noop))
        #expect(defaults.unitCount == NoOpJob.defaultUnits)
        #expect(defaults.sleepPerUnit == .milliseconds(NoOpJob.defaultSleepMilliseconds))

        let request = NoOpJob.request(units: 8, sleepMilliseconds: 0, requestedBy: "test")
        let checkpoints = InMemoryCheckpointStore()
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 8)
        cp.completedUnits = 5
        cp.unitsRun = 5
        try checkpoints.save(cp)
        let log = InMemoryBackgroundLog()
        let supervisor = make(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints, factory: DefaultJobFactory(), log: log)
        await supervisor.start()
        await supervisor.drain()
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME noop \(request.id) — finished: 8 run · 0 skipped · 0 failed") }, "\(log.lines)")
        #expect(checkpoints.saveCount == 1 + 1 + 3, "one seed save, one at START (so a kill in the first unit still has its OUTCOME), then one per remaining unit")
    }

    @Test("the trickle state spaces units by the trickle interval")
    func trickleSpacing() async throws {
        let recorder = UnitRecorder()
        let source = FakeActivitySource(ActivitySample(secondsSinceLastInput: 1))
        let backoff = Backoff(source: source, trickleInterval: .milliseconds(50))
        let supervisor = make(factory: RecordingFactory(recorder: recorder, units: 4), backoff: backoff)
        let clock = ContinuousClock()
        let began = clock.now
        _ = await supervisor.enqueue(RecordingFactory.request())
        await supervisor.drain()
        #expect(clock.now - began >= .milliseconds(180), "4 units × 50 ms of trickle")
        #expect(recorder.completedUnits.count == 4)
    }

    @Test("status lists every job with its state, and idle time resets on activity")
    func status() async throws {
        let supervisor = make(factory: RecordingFactory(recorder: UnitRecorder(), units: 2))
        let request = RecordingFactory.request()
        _ = await supervisor.enqueue(request)
        await supervisor.drain()
        let status = await supervisor.status(processIdentifier: 1, startedAt: Date())
        #expect(status.jobs.count == 1)
        #expect(status.jobs.first?.state == .finished)
        #expect(status.backoff == .full)
        #expect(status.idleSeconds < 1)
        #expect(await supervisor.shouldExitWhenIdle(threshold: 0))
        #expect(await supervisor.shouldExitWhenIdle(threshold: 600) == false)
    }
    // MARK: - Reviewer reds (2026-10-30), now green

    @Test("a queue file naming a JobKind this build does not know gets START…refused and its OUTCOME, and the file is kept (refuse, never erase)")
    func unknownKindQueueFileHasItsOutcomeAndKeepsItsFile() async throws {
        let newer = JobRequest(kind: JobKind(rawValue: "caption"), requestedBy: "app-v2")
        let queue = InMemoryJobQueueStore([newer])
        let log = InMemoryBackgroundLog()
        let supervisor = make(queue: queue, factory: DefaultJobFactory(), log: log)
        await supervisor.start()
        await supervisor.drain()

        #expect(log.lines.contains { $0.hasPrefix("START caption \(newer.id) — refused") }, "\(log.lines)")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME caption \(newer.id) — failed:") && $0.contains("the queue file is kept") }, "\(log.lines)")
        #expect(log.startCount == log.outcomeCount, "\(log.lines)")
        #expect(queue.contains(newer.id), "the request is the app's intent; a build that knows the kind will run it")
        #expect(await supervisor.snapshot(newer.id)?.state == .failed(reason: "VideoScan Background does not know the job kind `caption` (this build knows: noop)"))
        #expect(await supervisor.shouldExitWhenIdle(threshold: 0), "a refused file is not pending work")
    }

    @Test("a unit that throws CancellationError while the task is NOT cancelled is a failed unit; the job finishes with its OUTCOME")
    func unitThrowingCancellationErrorIsAFailedUnit() async throws {
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = make(factory: SelfCancellingFactory(recorder: recorder), log: log)
        let request = JobRequest(kind: SelfCancellingFactory.kind, requestedBy: "test")
        _ = await supervisor.enqueue(request)
        await supervisor.drain()

        #expect(await supervisor.snapshot(request.id)?.state == .finished)
        #expect(recorder.completedUnits == [0, 2])
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME selfcancel \(request.id) — finished: 2 run · 0 skipped · 1 failed") }, "\(log.lines)")
        #expect(log.startCount == log.outcomeCount)
        #expect(await supervisor.shouldExitWhenIdle(threshold: 0))
    }

    @Test("resume() before the pause lands restores .running — the row never keeps saying pausing…")
    func resumeBeforePauseLandsRestoresRunning() async throws {
        // RED 2026-10-31 (nightly, Release, Core lane): the earlier shape slept 100 ms per
        // unit and read the state after pause(); under load the unit ended first, the
        // between-units check parked the job (.paused "user") and both reads failed.
        // Now the lane is held INSIDE unit 1 by a gate the test owns, so no between-units
        // check can run until the test opens it: both verbs land while the job is running.
        let recorder = UnitRecorder()
        let gate = UnitGate()
        let supervisor = make(factory: GatedFactory(recorder: recorder, gate: gate, heldUnit: 1))
        let request = GatedFactory.request()
        _ = await supervisor.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld }, "unit 1 reached the gate")
        #expect(recorder.completedUnits == [0])
        #expect(await supervisor.pause(request.id))
        #expect(await supervisor.snapshot(request.id)?.state == .pausing)
        #expect(await supervisor.resume(request.id))
        #expect(await supervisor.snapshot(request.id)?.state == .running)
        gate.open()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count >= 4 })
        #expect(await supervisor.snapshot(request.id)?.state == .running, "the withdrawn pause never landed")
        _ = await supervisor.stop(request.id)
        await supervisor.drain()
        #expect(await supervisor.snapshot(request.id)?.state == .stopped)
    }

    @Test("a pause requested during a thermal hold is honoured before any unit runs when the Mac cools")
    func pauseDuringThermalHoldRunsNoUnit() async throws {
        let recorder = UnitRecorder()
        let source = FakeActivitySource(ActivitySample(thermalState: .serious))
        let backoff = Backoff(source: source, trickleInterval: .milliseconds(1))
        let supervisor = make(factory: RecordingFactory(recorder: recorder, units: 10), backoff: backoff)
        let request = RecordingFactory.request()
        _ = await supervisor.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { await supervisor.snapshot(request.id)?.state == .paused(reason: "thermal") })
        #expect(await supervisor.pause(request.id))
        source.set(ActivitySample(thermalState: .nominal))
        #expect(await BackgroundFixtures.waitUntil { await supervisor.snapshot(request.id)?.state == .paused(reason: "user") })
        #expect(recorder.completedUnits.isEmpty, "paused by the user before the Mac cooled: no unit should run; ran \(recorder.completedUnits)")
        _ = await supervisor.stop(request.id)
        await supervisor.drain()
        #expect(await supervisor.snapshot(request.id)?.state == .stopped)
    }
}
