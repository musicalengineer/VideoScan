// JobScheduleTests.swift — the helper owns its schedule (Rick 2026-11-04).
//
//   LOGIC      the supervisor plans by itself at start (no enqueue from
//              anyone); a catalog generation change plans again; an empty
//              plan enqueues nothing; an active job of the kind is not
//              doubled.
//   ISOLATION  a fail-fast job HOLDS its kind (Codex #232 F4: it used to be
//              re-queued on the next recount, forever); the hold survives a
//              restart; Resume, a new build or a catalog change releases
//              it; a repeat failure after a catalog release is sticky; a
//              torn holds file reads as no holds and says so; a unit the
//              helper died in three times is quarantined.
//   SCALE      one scheduling tick that plans 100k catalog rows (EraPlanner,
//              the production planner) inside a budget.

import Foundation
import Testing
@testable import VideoScanCore

/// Thread-safe counters and values the schedule closures read.
final class ScheduleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _generation: Int? = 1
    private var _size = 3
    private var _plans = 0
    var generation: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _generation }
        set { lock.lock(); _generation = newValue; lock.unlock() }
    }
    var size: Int {
        get { lock.lock(); defer { lock.unlock() }; return _size }
        set { lock.lock(); _size = newValue; lock.unlock() }
    }
    var plans: Int { lock.lock(); defer { lock.unlock() }; return _plans }
    func planned() -> Int { lock.lock(); defer { lock.unlock() }; _plans += 1; return _size }
}

/// Every unit fails with the same words (a missing tool): fail fast.
struct AlwaysFailingJob: BackgroundJob {
    let title = "Always failing"
    let unitCount = 20
    func runUnit(_ index: Int) async throws -> UnitOutcome { throw Refusal("ffmpeg is missing") }
}

struct ScheduleFactory: JobFactory {
    static let kind = JobKind(rawValue: "scheduled")
    let recorder: UnitRecorder
    var failing = false
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        failing ? AlwaysFailingJob() : RecordingJob(unitCount: 3, sleepPerUnit: .zero, recorder: recorder, hangAt: nil, failAt: [], skipAt: [])
    }
}

@Suite("JobSchedule — the helper plans, holds and releases by itself", .serialized)
struct JobScheduleTests {

    static func schedule(_ probe: ScheduleProbe, root: URL, build: String = "b1",
                         planInterval: Duration = .seconds(3600)) -> JobSchedule {
        let kind = JobSchedule.Kind(kind: ScheduleFactory.kind, planSize: { probe.planned() },
                                    makeRequest: { JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule") })
        var s = JobSchedule(kinds: [kind], generation: { probe.generation }, buildID: build,
                            holds: ScheduleHoldStore.beside(stateRoot: root))
        s.planInterval = planInterval
        s.pollInterval = .milliseconds(20)
        return s
    }

    static func supervisor(_ probe: ScheduleProbe, root: URL, failing: Bool = false, build: String = "b1",
                           recorder: UnitRecorder = UnitRecorder(), log: InMemoryBackgroundLog = InMemoryBackgroundLog(),
                           planInterval: Duration = .seconds(3600)) -> JobSupervisor {
        JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                      factory: ScheduleFactory(recorder: recorder, failing: failing), backoff: BackgroundFixtures.fullBackoff(),
                      log: log, configuration: BackgroundFixtures.fastConfiguration(),
                      schedule: schedule(probe, root: root, build: build, planInterval: planInterval))
    }

    static func jobs(_ s: JobSupervisor) async -> [JobProgressSnapshot] {
        await s.status(processIdentifier: 1, startedAt: Date()).jobs
    }

    @Test("RED→GREEN: at start, with no message from anyone, the helper plans and runs the scheduled kind")
    func plansAtLaunchWithNoMessage() async throws {
        let root = try BackgroundFixtures.scratch("schedule-launch")
        let probe = ScheduleProbe()
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let s = Self.supervisor(probe, root: root, recorder: recorder, log: log)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "\(log.lines)")
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(s).first?.state == .finished })
        #expect(log.lines.contains { $0.contains("by schedule") }, "\(log.lines)")
        let status = await s.status(processIdentifier: 1, startedAt: Date())
        #expect(status.planned?[ScheduleFactory.kind.rawValue] == 3, "the helper reports its own plan size")
        #expect(status.holds == [])
        await s.abandonForTest()
    }

    @Test("an empty plan enqueues nothing; a catalog generation change plans again (and finds work)")
    func generationChangePlans() async throws {
        let root = try BackgroundFixtures.scratch("schedule-generation")
        let probe = ScheduleProbe()
        probe.size = 0
        let recorder = UnitRecorder()
        let s = Self.supervisor(probe, root: root, recorder: recorder)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { probe.plans == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.plans == 1, "no change, interval not due: no second plan")
        #expect(await Self.jobs(s).isEmpty, "an empty plan queues nothing")
        probe.size = 3
        probe.generation = 2
        #expect(await BackgroundFixtures.waitUntil { probe.plans == 2 })
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 })
        await s.abandonForTest()
    }

    @Test("a kind with an active job is not planned again (no duplicate enqueue)")
    func activeJobIsNotDoubled() async throws {
        let root = try BackgroundFixtures.scratch("schedule-active")
        let probe = ScheduleProbe()
        let recorder = UnitRecorder()
        let gate = UnitGate()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: GatedFactory(recorder: recorder, gate: gate, heldUnit: 0), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: { () -> JobSchedule in
                                  var sc = JobSchedule(kinds: [JobSchedule.Kind(kind: GatedFactory.kind, planSize: { probe.planned() },
                                                                                makeRequest: { GatedFactory.request() })],
                                                       generation: { probe.generation }, buildID: "b1",
                                                       holds: ScheduleHoldStore.beside(stateRoot: root))
                                  sc.pollInterval = .milliseconds(20)
                                  return sc
                              }())
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld })
        probe.generation = 5
        try await Task.sleep(for: .milliseconds(150))
        #expect(await Self.jobs(s).count == 1, "the running job holds the kind")
        gate.open()
        await s.abandonForTest()
    }

    @Test("RED→GREEN Codex #232 F4: a fail-fast job holds its kind — no re-queue, across a restart — until Resume")
    func holdSurvivesRestartAndClearsOnResume() async throws {
        let root = try BackgroundFixtures.scratch("schedule-hold")
        let probe = ScheduleProbe()
        let log = InMemoryBackgroundLog()
        let first = Self.supervisor(probe, root: root, failing: true, log: log, planInterval: .milliseconds(50))
        await first.start()
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(first).contains { if case .failed = $0.state { true } else { false } } })
        try await Task.sleep(for: .milliseconds(250))   // five plan intervals
        let afterHold = await Self.jobs(first)
        #expect(afterHold.count == 1, "held: the next plans queue nothing (\(afterHold.map(\.state)))")
        let held = try #require(await first.status(processIdentifier: 1, startedAt: Date()).holds?.first)
        #expect(held.reason.contains("ffmpeg is missing"))
        #expect(log.lines.contains { $0.contains("held after a failure") }, "\(log.lines)")
        await first.abandonForTest()

        // Relaunch: same build, same catalog — still held, nothing queued.
        let second = Self.supervisor(probe, root: root, failing: true, planInterval: .milliseconds(50))
        await second.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Self.jobs(second).isEmpty, "the hold came back from holds.json")
        #expect(await second.status(processIdentifier: 1, startedAt: Date()).holds?.first?.jobID == held.jobID)

        // Resume on the hold's job id (the menu's line) releases it and plans now.
        #expect(await second.resume(held.jobID))
        #expect(await BackgroundFixtures.waitUntil { await !Self.jobs(second).isEmpty }, "Resume planned and queued again")
        await second.abandonForTest()
    }

    @Test("a hold is released by a new build, and by a catalog change once; the same failure after that is sticky")
    func holdReleasedByBuildAndGeneration() async throws {
        let root = try BackgroundFixtures.scratch("schedule-release")
        let probe = ScheduleProbe()
        let a = Self.supervisor(probe, root: root, failing: true)
        await a.start()
        #expect(await BackgroundFixtures.waitUntil { await a.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        await a.abandonForTest()

        // A new build: the hold goes and the kind runs (and fails, so holds again).
        let log = InMemoryBackgroundLog()
        let b = Self.supervisor(probe, root: root, failing: true, build: "b2", log: log)
        await b.start()
        #expect(await BackgroundFixtures.waitUntil { log.lines.contains { $0.contains("released — a new build") } }, "\(log.lines)")
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(b).count == 1 })
        #expect(await BackgroundFixtures.waitUntil { await b.status(processIdentifier: 1, startedAt: Date()).holds?.first?.build == "b2" })

        // A catalog change releases it once; the same words again → sticky.
        probe.generation = 2
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(b).count == 2 }, "released by the catalog change, ran again")
        #expect(await BackgroundFixtures.waitUntil { await b.status(processIdentifier: 1, startedAt: Date()).holds?.first?.sticky == true })
        probe.generation = 3
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Self.jobs(b).count == 2, "a sticky hold ignores catalog changes")
        await b.abandonForTest()
    }

    @Test("ISOLATION: a torn holds.json reads as no holds and the log says so")
    func tornHoldsFile() async throws {
        let root = try BackgroundFixtures.scratch("schedule-torn")
        try Data("{not json".utf8).write(to: root.appendingPathComponent("holds.json"))
        let probe = ScheduleProbe()
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let s = Self.supervisor(probe, root: root, recorder: recorder, log: log)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 })
        #expect(log.lines.contains { $0.contains("holds.json is unreadable") }, "\(log.lines)")
        await s.abandonForTest()
    }

    @Test("ISOLATION: a unit the helper died in three times is quarantined — counted failed, skipped, said")
    func crashLoopUnitIsQuarantined() async throws {
        let recorder = UnitRecorder()
        let request = RecordingFactory.request()
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 4)
        cp.completedUnits = 1
        cp.unitsRun = 1
        cp.inFlightUnit = 1
        cp.inFlightAttempts = 3
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        let log = InMemoryBackgroundLog()
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: RecordingFactory(recorder: recorder, units: 4), backoff: BackgroundFixtures.fullBackoff(),
                              log: log, configuration: BackgroundFixtures.fastConfiguration())
        await s.start()
        await s.drain()
        #expect(recorder.completedUnits == [2, 3], "unit 1 never ran again")
        #expect(log.lines.contains { $0.contains("unit 1 was in flight when the helper died 3 times — quarantined") }, "\(log.lines)")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recording \(request.id) — finished: 3 run · 0 skipped · 1 failed") }, "\(log.lines)")
    }

    @Test("an in-flight unit below the limit just runs again (one crash is bad luck)")
    func oneCrashRetries() async throws {
        let recorder = UnitRecorder()
        let request = RecordingFactory.request()
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 2)
        cp.inFlightUnit = 0
        cp.inFlightAttempts = 1
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: RecordingFactory(recorder: recorder, units: 2), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration())
        await s.start()
        await s.drain()
        #expect(recorder.completedUnits == [0, 1])
    }

    @Test("COMPAT: a checkpoint written before the in-flight fields still decodes")
    func olderCheckpointDecodes() throws {
        let cp = JobCheckpoint(jobID: JobID(rawValue: "J"), totalUnits: 3)
        var object = try #require(try JSONSerialization.jsonObject(with: try BackgroundPayloadCodec.encode(cp)) as? [String: Any])
        var body = try #require(object["body"] as? [String: Any])
        body.removeValue(forKey: "inFlightUnit")
        body.removeValue(forKey: "inFlightAttempts")
        object["body"] = body
        let decoded = try BackgroundPayloadCodec.decode(JobCheckpoint.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.jobID == cp.jobID && decoded.totalUnits == 3 && decoded.inFlightUnit == nil && decoded.inFlightAttempts == nil)
    }

    static let scaleBudget: Duration = .seconds(5)

    @Test("SCALE: one scheduling tick that plans 100k catalog rows with the production planner, inside a budget")
    func planOneHundredThousandRows() async throws {
        let files = (1...100_000).map { EraFixture.File(n: $0, path: "/synthetic/\(1960 + $0 % 50)/clip\($0).mov") }
        let fixture = try await EraFixture.catalog(files)
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let catalog = fixture.url
        let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        let kind = JobSchedule.Kind(kind: ScheduleFactory.kind, planSize: {
            try EraPlanner.plan(catalogURL: catalog, journal: journal, signer: SeatedApproach.eraA2.signer, limit: nil,
                                jobID: JobID(), isReadable: { _ in true }).units.count
        }, makeRequest: { JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule") })
        let schedule = JobSchedule(kinds: [kind], generation: { BackgroundCatalogAccess.generation(at: catalog) }, buildID: "b1",
                                   holds: ScheduleHoldStore.beside(stateRoot: root))
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder()), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), schedule: schedule)
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let began = clock.now
        await s.scheduleTick()
        let elapsed = clock.now - began
        print("[background-scale] one scheduling tick planned 100k rows in \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).planned?[ScheduleFactory.kind.rawValue] == 100_000)
        #expect(BackgroundCatalogAccess.generation(at: catalog) != nil, "the generation is readable through the read-only door")
        expectWithinTimingBudget("schedule tick, 100k rows", measured: elapsed, budget: Self.scaleBudget, loadBefore: load)
        await s.abandonForTest()
    }
}

@Suite("JobSchedule — re-entrancy", .serialized)
struct JobScheduleReentrancyTests {
    @Test("RED→GREEN: two ticks interleaved across a slow plan queue the kind once")
    func interleavedTicksEnqueueOnce() async throws {
        let root = try BackgroundFixtures.scratch("schedule-reentrant")
        let gate = UnitGate()
        let kind = JobSchedule.Kind(kind: GatedFactory.kind, planSize: { Thread.sleep(forTimeInterval: 0.1); return 3 },
                                    makeRequest: { GatedFactory.request() })
        // Each read is a new generation, so the second tick is due while the first is still planning.
        let reads = ScheduleProbe()
        let schedule = JobSchedule(kinds: [kind], generation: { _ = reads.planned(); return reads.plans }, buildID: "b1",
                                   holds: ScheduleHoldStore.beside(stateRoot: root))
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: GatedFactory(recorder: UnitRecorder(), gate: gate, heldUnit: 0),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(), schedule: schedule)
        async let a: Void = s.scheduleTick()
        async let b: Void = s.scheduleTick()
        _ = await (a, b)
        let jobs = await s.status(processIdentifier: 1, startedAt: Date()).jobs
        #expect(jobs.count == 1, "queued \(jobs.count) jobs of one kind")
        gate.open()
        await s.abandonForTest()
    }
}
