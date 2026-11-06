// FableReviewHelperTests.swift — Fable's review reds for feat/helper-owns-schedule
// (0dedf4768), each run red on that tip, then green. The varying-words test
// is restated for the rule that replaced "sticky" (a hold is released by
// Resume, a new build, or a CHANGED PLAN SIZE — never by a catalog commit alone).

import Foundation
import Testing
@testable import VideoScanCore

// MARK: doubles

/// Every unit fails the way a clip timeout / worker death does: words that do
/// not name the file, `failureIsSystemic == false`. The supervisor's streak
/// ignores these, so the job ends `.finished` with 0 run.
struct AllNonSystemicJob: BackgroundJob {
    let title = "every unit times out"
    let unitCount = 2
    func runUnit(_ index: Int) async throws -> UnitOutcome {
        throw Refusal("analyze_clip exceeded 180 s; the worker was killed and the GPU freed")
    }
    func failureIsSystemic(_ error: any Error) -> Bool { false }
}

struct AllNonSystemicFactory: JobFactory {
    static let kind = JobKind(rawValue: "timeouts")
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { AllNonSystemicJob() }
}

final class SpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// A model-load failure as EraJob really words it: `Refusal` (systemic) whose
/// text ends with the worker's stderr tail — and a tail differs per spawn
/// (progress-bar rates, timings). Within ONE job the words are fixed, so the
/// job fails fast; across jobs they differ.
struct VaryingTailJob: BackgroundJob {
    let title = "load fails, stderr tail differs per spawn"
    let unitCount = 6
    let spawn: Int
    func runUnit(_ index: Int) async throws -> UnitOutcome {
        throw Refusal("the worker could not load the model (the worker died during load — last words: "
                      + "Fetching 10 files: 100%|██████████| 10/10 [00:00<00:00, \(spawn * 137).\(spawn)it/s])")
    }
}

struct VaryingTailFactory: JobFactory {
    static let kind = JobKind(rawValue: "varying")
    let spawns: SpawnCounter
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { VaryingTailJob(spawn: spawns.next()) }
}

@Suite("Fable review — helper owns its schedule", .serialized)
struct FableReviewHelperTests {

    static func schedule(kind: JobKind, probe: ScheduleProbe, root: URL,
                         planInterval: Duration) -> JobSchedule {
        var s = JobSchedule(kinds: [JobSchedule.Kind(kind: kind, planSize: { probe.planned() },
                                                     makeRequest: { JobRequest(kind: kind, requestedBy: "schedule") })],
                            generation: { probe.generation }, buildID: "b1",
                            holds: ScheduleHoldStore.beside(stateRoot: root))
        s.planInterval = planInterval
        s.pollInterval = .milliseconds(20)
        return s
    }

    static func jobs(_ s: JobSupervisor) async -> [JobProgressSnapshot] {
        await s.status(processIdentifier: 1, startedAt: Date()).jobs
    }

    /// A schedule whose plan reads what the job has done, as EraPlanner reads
    /// the journal: 3 units minus those completed. `calls` counts measurements;
    /// `holdSecond`, when given, blocks the second measurement (the post-run
    /// one) until signalled, so a test can look at status inside that window.
    static func shrinkingSchedule(root: URL, recorder: UnitRecorder, calls: ScheduleProbe,
                                  holdSecond: DispatchSemaphore? = nil, poll: Duration) -> JobSchedule {
        let kind = JobSchedule.Kind(kind: ScheduleFactory.kind,
                                    planSize: {
                                        _ = calls.planned()
                                        if calls.plans == 2 { holdSecond?.wait() }
                                        return max(0, 3 - recorder.completedUnits.count)
                                    },
                                    makeRequest: { JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule") })
        var s = JobSchedule(kinds: [kind], generation: { 1 }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        s.planInterval = .seconds(3600)
        s.pollInterval = poll
        return s
    }

    static func shrinkingSupervisor(_ schedule: JobSchedule, recorder: UnitRecorder) -> JobSupervisor {
        JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                      factory: ScheduleFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                      log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(),
                      schedule: schedule)
    }

    static func plannedSize(_ s: JobSupervisor) async -> Int? {
        await s.status(processIdentifier: 1, startedAt: Date()).planned?[ScheduleFactory.kind.rawValue]
    }

    // Pins `finish` (JobSupervisor.swift) — a scheduled kind's job ends and the
    // plan must be re-measured, or for up to `planInterval` (10 min in
    // production) `status.planned` repeats the plan size from BEFORE the job
    // ran; BackgroundServiceStore prints it as "Content analysis: N files to
    // analyze (the helper's plan)". Until 2026-11-06 this test changed the
    // probe AFTER observing `.finished`, racing the post-run measurement (one
    // 20 ms poll tick): red whenever the supervisor's tick beat the test's
    // 10 ms waitUntil poll (the 16-core M4 under the parallel suite), green
    // otherwise (the Ultra). The plan now shrinks as units complete, as the
    // real planner's does, so the outcome no longer depends on who wakes first.
    @Test("TRUTH: after the job finished its whole plan, status still reports the pre-run plan size")
    func planSizeIsStaleAfterTheJobFinished() async throws {
        let root = try BackgroundFixtures.scratch("fable-stale-plan")
        let recorder = UnitRecorder()
        let calls = ScheduleProbe()
        let s = Self.shrinkingSupervisor(Self.shrinkingSchedule(root: root, recorder: recorder, calls: calls,
                                                                poll: .milliseconds(20)), recorder: recorder)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 })
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(s).first?.state == .finished })
        let measured = await BackgroundFixtures.waitUntil {
            let size = await Self.plannedSize(s)
            return calls.plans >= 2 && size == 0
        }
        let planned = await Self.plannedSize(s)
        #expect(measured,
                "finish() never invalidates the plan: Settings says '3 files to analyze (the helper's plan)' for up to planInterval after they were all done (got \(String(describing: planned)))")
        try await Task.sleep(for: .milliseconds(100))     // five poll ticks: nothing re-queues
        #expect(await Self.jobs(s).count == 1, "re-measured, not re-queued: no job runs back to back")
        await s.abandonForTest()
    }

    // Pins `finish` — between the job's end and the post-run measurement
    // landing (a poll interval plus a ~1 s catalog plan in production) the
    // pre-run size is not a fact and must not be shown.
    @Test("TRUTH: while the post-run plan is being measured, status shows no plan size rather than the pre-run one")
    func preRunSizeIsDroppedAtFinish() async throws {
        let root = try BackgroundFixtures.scratch("fable-plan-window")
        let recorder = UnitRecorder()
        let calls = ScheduleProbe()
        let gate = DispatchSemaphore(value: 0)
        let s = Self.shrinkingSupervisor(Self.shrinkingSchedule(root: root, recorder: recorder, calls: calls, holdSecond: gate,
                                                                poll: .milliseconds(20)), recorder: recorder)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { calls.plans == 2 }, "the post-run measurement started")
        let during = await Self.plannedSize(s)
        gate.signal()
        #expect(during == nil, "status said \(String(describing: during)) files to analyze while the post-run plan was still being measured")
        #expect(await BackgroundFixtures.waitUntil { (await Self.plannedSize(s)) == 0 })
        await s.abandonForTest()
    }

    // Pins `finish` — the post-run measurement starts when the job ends, not
    // at the next poll (30 s in production; one hour here).
    @Test("LIFECYCLE: the post-run plan is measured when the job ends, not at the next poll")
    func postRunMeasurementStartsAtOnce() async throws {
        let root = try BackgroundFixtures.scratch("fable-plan-kick")
        let recorder = UnitRecorder()
        let calls = ScheduleProbe()
        let s = Self.shrinkingSupervisor(Self.shrinkingSchedule(root: root, recorder: recorder, calls: calls,
                                                                poll: .seconds(3600)), recorder: recorder)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(s).first?.state == .finished })
        let measured = await BackgroundFixtures.waitUntil(.seconds(2)) { (await Self.plannedSize(s)) == 0 }
        let planned = await Self.plannedSize(s)
        #expect(measured, "two seconds after the job ended the plan still says \(String(describing: planned)) (\(calls.plans) measurement(s))")
        await s.abandonForTest()
    }

    // Pins JobSupervisor.swift:689-697 (`Turn.verdict`) — a job whose EVERY
    // unit failed non-systemically (timeouts, worker deaths) ends `.finished`
    // with 0 run, so nothing holds the kind; the planner finds the same units
    // (nothing was journaled) and queues the same job again at the next plan —
    // every planInterval, or every catalog commit, forever, each run paying a
    // model load plus N clip timeouts. The menu bar says "working" throughout.
    @Test("LIFECYCLE: a job that made no progress is re-planned and re-run forever")
    func zeroProgressJobIsRunAgainForever() async throws {
        let root = try BackgroundFixtures.scratch("fable-zero-progress")
        let probe = ScheduleProbe()                       // plan size 3 (> 0: work "left")
        let log = InMemoryBackgroundLog()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: AllNonSystemicFactory(), backoff: BackgroundFixtures.fullBackoff(),
                              log: log, configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: Self.schedule(kind: AllNonSystemicFactory.kind, probe: probe, root: root,
                                                      planInterval: .milliseconds(50)))
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(s).first?.state.isActive == false }, "\(log.lines)")
        try await Task.sleep(for: .milliseconds(400))     // eight plan intervals
        let status = await s.status(processIdentifier: 1, startedAt: Date())
        #expect(status.jobs.count == 1 || status.holds?.isEmpty == false,
                "0 run · 0 skipped · 2 failed is not progress; the kind should hold (or at least not be re-queued): \(status.jobs.map(\.state))")
        await s.abandonForTest()
    }

    // Pins JobSupervisor.swift:549 (`hold`, the signature compare) with
    // EraJob.swift:185 + PythonClipWorker.swift:51 (load-failure words carry the
    // 64 KB stderr tail). The design says a catalog change releases a hold ONCE
    // per failure; a repeat with "the same words" is sticky. The words are never
    // the same when the tail moves, so every catalog commit releases the hold
    // and buys another spawn + model load, without end.
    @Test("LIFECYCLE: a hold whose failure words vary (stderr tail) is not released by catalog commits — only by a changed plan")
    func holdWithVaryingWordsIsReleasedForever() async throws {
        let root = try BackgroundFixtures.scratch("fable-varying-words")
        let probe = ScheduleProbe()
        let spawns = SpawnCounter()
        let log = InMemoryBackgroundLog()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: VaryingTailFactory(spawns: spawns), backoff: BackgroundFixtures.fullBackoff(),
                              log: log, configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: Self.schedule(kind: VaryingTailFactory.kind, probe: probe, root: root,
                                                      planInterval: .seconds(3600)))
        @Sendable func failedJobs() async -> Int {
            await Self.jobs(s).filter { if case .failed = $0.state { true } else { false } }.count
        }
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await failedJobs() == 1 }, "first failure holds: \(log.lines)")
        probe.generation = 2                              // a commit that adds no work
        try await Task.sleep(for: .milliseconds(200))
        probe.generation = 3                              // another
        try await Task.sleep(for: .milliseconds(200))
        #expect(await failedJobs() == 1, "a catalog commit released the hold: \(log.lines.filter { $0.contains("released") })")
        probe.size = 4                                    // the work changed: one more file to analyze
        probe.generation = 4
        #expect(await BackgroundFixtures.waitUntil { await failedJobs() == 2 }, "a changed plan releases it once: \(log.lines)")
        await s.abandonForTest()
    }
}

@Suite("Fable review — pause, clean exit, build", .serialized)
struct FableReviewHelperFollowUpTests {

    @Test("PAUSE survives a restart: the relaunched supervisor adopts the job paused and runs no unit until Resume")
    func pauseSurvivesARestart() async throws {
        let root = try BackgroundFixtures.scratch("fable-pause")
        let probe = ScheduleProbe()
        let recorder = UnitRecorder()
        let queue = InMemoryJobQueueStore()
        let checkpoints = InMemoryCheckpointStore()
        func supervisor() -> JobSupervisor {
            JobSupervisor(queue: queue, checkpoints: checkpoints,
                          factory: RecordingFactory(recorder: recorder, units: 50, sleepPerUnit: .milliseconds(20)),
                          backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                          configuration: BackgroundFixtures.fastConfiguration(),
                          schedule: FableReviewHelperTests.schedule(kind: RecordingFactory.kind, probe: probe, root: root,
                                                                    planInterval: .seconds(3600)))
        }
        let first = supervisor()
        await first.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count >= 2 })
        let id = try #require(await FableReviewHelperTests.jobs(first).first?.id)
        #expect(await first.pause(id))
        #expect(await BackgroundFixtures.waitUntil { await first.snapshot(id)?.state == .paused(reason: JobSupervisor.userPauseReason) })
        await first.abandonForTest()
        let ranBefore = recorder.completedUnits.count

        let second = supervisor()
        await second.start()
        let stillPaused = await BackgroundFixtures.waitUntil { await second.snapshot(id)?.state == .paused(reason: JobSupervisor.userPauseReason) }
        let state = await second.snapshot(id)?.state
        #expect(stillPaused, "after a restart the job is \(String(describing: state))")
        try await Task.sleep(for: .milliseconds(150))
        #expect(recorder.completedUnits.count == ranBefore, "a unit ran while paused")
        #expect(await FableReviewHelperTests.jobs(second).count == 1, "no second job was planned beside the paused one")
        #expect(await second.resume(id))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count > ranBefore }, "Resume runs it again")
        #expect(ScheduleHoldStore.beside(stateRoot: root).loadPaused() == .success([]), "Resume clears the persisted pause")
        await second.abandonForTest()
    }

    @Test("SIGTERM is not a crash: prepareForExit clears the in-flight mark, so a clean restart never counts toward quarantine")
    func cleanExitClearsTheInFlightMark() async throws {
        let recorder = UnitRecorder()
        let gate = UnitGate()
        let checkpoints = InMemoryCheckpointStore()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: checkpoints,
                              factory: GatedFactory(recorder: recorder, gate: gate, heldUnit: 1), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration())
        let request = GatedFactory.request()
        _ = await s.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld }, "unit 1 is in flight")
        guard case .found(let during) = checkpoints.load(request.id) else { Issue.record("no checkpoint"); return }
        #expect(during.inFlightUnit == 1)
        await s.prepareForExit()
        guard case .found(let after) = checkpoints.load(request.id) else { Issue.record("no checkpoint"); return }
        #expect(after.inFlightUnit == nil && after.inFlightAttempts == nil, "the clean exit left an in-flight mark")
        gate.open()
    }

    @Test("TRUTH: the status names the running helper's build, so the app can say an older helper is running")
    func statusCarriesTheBuild() async throws {
        let root = try BackgroundFixtures.scratch("fable-build")
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder()), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(),
                              schedule: FableReviewHelperTests.schedule(kind: ScheduleFactory.kind, probe: ScheduleProbe(), root: root,
                                                                        planInterval: .seconds(3600)))
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).build == "b1")
    }
}

@Suite("Fable review — no back-to-back reruns", .serialized)
struct FableReviewHelperLoopTests {
    @Test("a finished job whose plan did not shrink is re-measured, never re-queued at once (no tight loop)")
    func finishedJobIsNotRequeuedAtOnce() async throws {
        let root = try BackgroundFixtures.scratch("fable-no-loop")
        let probe = ScheduleProbe()                       // the plan stays at 3: the job "succeeded" but wrote nothing
        let recorder = UnitRecorder()
        let s = JobScheduleTests.supervisor(probe, root: root, recorder: recorder)   // planInterval 1 h
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.completedUnits.count == 3, "the job was re-run back to back \(recorder.completedUnits.count / 3) times")
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).planned?[ScheduleFactory.kind.rawValue] == 3, "but the plan was re-measured")
        await s.abandonForTest()
    }
}

/// Refuses every admission and counts them (a dependency that stays missing).
struct CountingRefusalFactory: JobFactory {
    static let kind = JobKind(rawValue: "refusing")
    let made: ScheduleProbe
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        _ = made.planned()
        throw Refusal("weights missing")
    }
}

@Suite("Codex #241 — the Fable delta's reds", .serialized)
struct Codex241Tests {
    typealias F = FableReviewHelperTests

    @Test("F1: an older helper's running job with `waiting` is said waiting, never running")
    func olderWaitingPayloadSaysWaiting() {
        var job = JobProgressSnapshot(id: JobID(rawValue: "J"), kind: .era, lane: "model", title: "Machine era (8B)", subtitle: "",
                                      completedUnits: 3, totalUnits: 9, skippedUnits: 0, failedUnits: 0,
                                      state: .running, startedAt: Date(), finishedAt: nil)
        job.waiting = "you're at the Mac"
        #expect(job.stateWords == "waiting — you're at the Mac")
    }

    @Test("F2: a measurement begun under an earlier hold never sets the baseline of a newer hold")
    func staleMeasurementIsDropped() async throws {
        let root = try BackgroundFixtures.scratch("c241-f2")
        let old = ScheduleHold(kind: CountingRefusalFactory.kind, jobID: JobID(rawValue: "H1"), reason: "x", build: "b1")
        try ScheduleHoldStore.beside(stateRoot: root).save([old])
        let calls = ScheduleProbe()
        let sizes = ScheduleProbe()
        let made = ScheduleProbe()
        let gen = ScheduleProbe()
        let gate = DispatchSemaphore(value: 0)
        let kind = JobSchedule.Kind(kind: CountingRefusalFactory.kind,
                                    planSize: { let n = sizes.size; _ = calls.planned(); if calls.plans == 1 { gate.wait() }; return n },
                                    makeRequest: { JobRequest(kind: CountingRefusalFactory.kind, requestedBy: "schedule") })
        var sc = JobSchedule(kinds: [kind], generation: { gen.generation }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        sc.pollInterval = .milliseconds(20)
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: CountingRefusalFactory(made: made), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(), schedule: sc)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { calls.plans == 1 }, "tick A is measuring under H1")
        sizes.size = 4
        #expect(await s.resume(old.jobID))
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.first.map { $0.jobID != old.jobID } == true },
                "tick B was refused and made a new hold")
        gate.signal()                                     // tick A returns its stale 3
        try await Task.sleep(for: .milliseconds(100))
        gen.generation = 2                                 // a later tick: work unchanged at 4
        try await Task.sleep(for: .milliseconds(200))
        #expect(made.plans == 1, "re-admitted \(made.plans) times without a release")
        await s.abandonForTest()
    }

    @Test("F3: a held kind with a retained queued request is still measured — new work releases it and one fresh job runs")
    func heldKindWithRetainedRequestIsReleasedByNewWork() async throws {
        let root = try BackgroundFixtures.scratch("c241-f3")
        let probe = ScheduleProbe()
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        try ScheduleHoldStore.beside(stateRoot: root).save([ScheduleHold(kind: ScheduleFactory.kind, jobID: request.id, reason: "x",
                                                                         build: "b1", planSize: 3)])
        let recorder = UnitRecorder()
        let queue = InMemoryJobQueueStore([request])
        let s = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: JobScheduleTests.schedule(probe, root: root))
        await s.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.completedUnits.isEmpty)
        probe.size = 4
        probe.generation = 2
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "new work released the hold")
        #expect(!queue.contains(request.id), "the retained request was dropped, a fresh one ran")
        await s.abandonForTest()
    }

    @Test("F4: two queue files of one scheduled kind at relaunch — one adopted (the one with a checkpoint), the other removed")
    func relaunchAdoptsOnePerKind() async throws {
        let root = try BackgroundFixtures.scratch("c241-f4")
        let a = JobRequest(kind: ScheduleFactory.kind, requestedAt: Date(timeIntervalSince1970: 1), requestedBy: "schedule")
        let b = JobRequest(kind: ScheduleFactory.kind, requestedAt: Date(timeIntervalSince1970: 2), requestedBy: "cli --run")
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(JobCheckpoint(jobID: b.id, totalUnits: 3))
        let queue = InMemoryJobQueueStore([a, b])
        let log = InMemoryBackgroundLog()
        let s = JobSupervisor(queue: queue, checkpoints: checkpoints, factory: ScheduleFactory(recorder: UnitRecorder()),
                              backoff: BackgroundFixtures.fullBackoff(), log: log,
                              schedule: JobScheduleTests.schedule(ScheduleProbe(), root: root))
        #expect(await s.plan() == 1)
        #expect(queue.contains(b.id) && !queue.contains(a.id))
        #expect(log.lines.contains { $0.contains("second request of a scheduled kind") }, "\(log.lines)")
    }

    @Test("F5: a status with a hold still carries `sticky` on the wire (a 0dedf4768 reader requires it)")
    func holdKeepsTheLegacyWireField() throws {
        let status = ServiceStatus(processIdentifier: 1, startedAt: Date(), backoff: .full, jobs: [], idleSeconds: 0,
                                   holds: [ScheduleHold(kind: .era, jobID: JobID(rawValue: "J"), reason: "x", build: "b")])
        let object = try #require(try JSONSerialization.jsonObject(with: try BackgroundPayloadCodec.encode(status)) as? [String: Any])
        let hold = try #require(((object["body"] as? [String: Any])?["holds"] as? [[String: Any]])?.first)
        #expect(hold["sticky"] as? Bool == false)
    }
}

@Suite("Codex #242 — the legacy wire field decodes when absent")
struct Codex242Tests {
    @Test("a hold written by 07c314e5d (no `sticky`) still decodes, as sticky false")
    func holdWithoutStickyStillDecodes() throws {
        let hold = ScheduleHold(kind: .era, jobID: JobID(rawValue: "J"), reason: "weights missing", build: "old",
                                heldAt: Date(timeIntervalSince1970: 0))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hold)) as? [String: Any])
        object.removeValue(forKey: "sticky")
        let decoded = try JSONDecoder().decode(ScheduleHold.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == hold)
    }
}
