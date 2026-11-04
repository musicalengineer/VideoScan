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
    var unitCount = 20
    func runUnit(_ index: Int) async throws -> UnitOutcome { throw Refusal("ffmpeg is missing") }
}

struct ScheduleFactory: JobFactory {
    static let kind = JobKind(rawValue: "scheduled")
    let recorder: UnitRecorder
    var failing = false
    var failingUnits: @Sendable () -> Int = { 20 }
    /// Counts every job the factory makes (admission and START both ask it).
    var made: ScheduleProbe? = nil
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        _ = made?.planned()
        return failing ? AlwaysFailingJob(unitCount: failingUnits())
            : RecordingJob(unitCount: 3, sleepPerUnit: .zero, recorder: recorder, hangAt: nil, failAt: [], skipAt: [])
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

    @Test("a hold is released by a new build, and by a changed plan size — not by a catalog commit that adds no work")
    func holdReleasedByBuildAndNewWork() async throws {
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

        // A catalog commit alone does not release it (Fable review 11/04); new work does.
        probe.generation = 2
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Self.jobs(b).count == 1, "a commit that adds no work is not a release")
        probe.size = 4
        probe.generation = 3
        #expect(await BackgroundFixtures.waitUntil { await Self.jobs(b).count == 2 }, "a changed plan released it, and it ran again")
        await b.abandonForTest()
    }

    @Test("RED→GREEN Codex #235 F2: a torn holds.json fails CLOSED — every scheduled kind held until Resume, then it runs")
    func tornHoldsFile() async throws {
        let root = try BackgroundFixtures.scratch("schedule-torn")
        try Data("{not json".utf8).write(to: root.appendingPathComponent("holds.json"))
        let probe = ScheduleProbe()
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let s = JobScheduleTests.supervisor(probe, root: root, recorder: recorder, log: log)
        await s.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.completedUnits.isEmpty, "an unreadable holds file is not permission to run")
        #expect(log.lines.contains { $0.contains("holds.json is unreadable") && $0.contains("holding every scheduled kind") }, "\(log.lines)")
        let hold = try #require(await s.status(processIdentifier: 1, startedAt: Date()).holds?.first)
        #expect(await s.resume(hold.jobID))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "Resume released it and rewrote the file")
        #expect(ScheduleHoldStore.beside(stateRoot: root).load() == .success([]))
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

/// A queue store that records, at each remove, whether the holds file already
/// names the kind — the order `finish` must keep (Codex #235 F1).
final class HoldOrderQueueStore: JobQueueStore, @unchecked Sendable {
    let inner = InMemoryJobQueueStore()
    let holds: ScheduleHoldStore
    private let lock = NSLock()
    private var _heldAtRemove: [Bool] = []
    init(holds: ScheduleHoldStore) { self.holds = holds }
    var heldAtRemove: [Bool] { lock.lock(); defer { lock.unlock() }; return _heldAtRemove }
    func list() -> (requests: [JobRequest], ignored: [String]) { inner.list() }
    func put(_ request: JobRequest) throws { try inner.put(request) }
    func contains(_ id: JobID) -> Bool { inner.contains(id) }
    func remove(_ id: JobID) {
        let held = (try? holds.load().get())?.contains { $0.jobID == id } ?? false
        lock.lock(); _heldAtRemove.append(held); lock.unlock()
        inner.remove(id)
    }
}

/// A job whose unit output is already durable (EraJob: a journal line by the signer).
struct AlreadyRecordedJob: BackgroundJob {
    let title = "Recorded"
    let unitCount = 2
    let recorder: UnitRecorder
    func runUnit(_ index: Int) async throws -> UnitOutcome { recorder.begin(); recorder.end(index); return .done }
    func unitIsAlreadyRecorded(_ index: Int) async -> Bool { index == 0 }
}

struct AlreadyRecordedFactory: JobFactory {
    static let kind = JobKind(rawValue: "recorded")
    let recorder: UnitRecorder
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { AlreadyRecordedJob(recorder: recorder) }
}

@Suite("JobSchedule — Codex #235 closing reds", .serialized)
struct JobScheduleCodex235Tests {
    typealias T = JobScheduleTests

    @Test("F1: the hold is on disk before the failed job's queue file goes (a crash between leaves both, never neither)")
    func holdIsDurableBeforeTheQueueFileGoes() async throws {
        let root = try BackgroundFixtures.scratch("c235-f1")
        let probe = ScheduleProbe()
        let holds = ScheduleHoldStore.beside(stateRoot: root)
        let queue = HoldOrderQueueStore(holds: holds)
        let s = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder(), failing: true), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: T.schedule(probe, root: root))
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { !queue.heldAtRemove.isEmpty })
        #expect(queue.heldAtRemove == [true], "the queue file went before the hold was written")
        await s.abandonForTest()
    }

    @Test("F3: a retained request of a held kind, adopted at relaunch, never starts — not even a factory call")
    func adoptedRequestOfAHeldKindNeverStarts() async throws {
        let root = try BackgroundFixtures.scratch("c235-f3")
        let probe = ScheduleProbe()
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        let hold = ScheduleHold(kind: ScheduleFactory.kind, jobID: request.id, reason: "refused",
                                build: "b1", planSize: 3, heldAt: Date(timeIntervalSince1970: 1_762_000_000))
        try ScheduleHoldStore.beside(stateRoot: root).save([hold])
        let made = ScheduleProbe()
        let recorder = UnitRecorder()
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: recorder, made: made), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: T.schedule(probe, root: root))
        await s.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(made.plans == 0, "the factory was asked \(made.plans) time(s)")
        #expect(recorder.completedUnits.isEmpty)
        #expect(ScheduleHoldStore.beside(stateRoot: root).load() == .success([hold]), "the hold is unchanged")
        await s.abandonForTest()
    }

    @Test("F4 (amended by the Fable review): an XPC/CLI enqueue of a scheduled kind is always refused — the helper schedules it itself")
    func enqueueOfAScheduledKindIsRefused() async throws {
        let root = try BackgroundFixtures.scratch("c235-f4")
        let made = ScheduleProbe()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder(), made: made), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), schedule: T.schedule(ScheduleProbe(), root: root))
        guard case .refused(let r) = await s.enqueue(JobRequest(kind: ScheduleFactory.kind, requestedBy: "cli")) else {
            Issue.record("a scheduled kind was accepted from the CLI"); return
        }
        #expect(r.words.contains("schedules scheduled itself"), "\(r.words)")
        #expect(made.plans == 0, "the factory is not even asked")
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).holds == [], "a refused enqueue is not a failure of the kind")
    }

    @Test("F6: a one-unit plan whose unit fails systemically ends failed and holds — no retry every interval")
    func shortSystemicJobHolds() async throws {
        let root = try BackgroundFixtures.scratch("c235-f6")
        let probe = ScheduleProbe()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder(), failing: true, failingUnits: { 1 }),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: T.schedule(probe, root: root, planInterval: .milliseconds(40)))
        await s.start()
        try await Task.sleep(for: .milliseconds(400))
        let jobs = await T.jobs(s)
        #expect(jobs.count == 1, "retried \(jobs.count) times")
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).holds?.first?.reason.contains("ffmpeg is missing") == true)
        await s.abandonForTest()
    }

    @Test("F7: an unreadable generation is not a catalog change: 1 → nil → 1 keeps the hold")
    func unknownGenerationIsNotAChange() async throws {
        let root = try BackgroundFixtures.scratch("c235-f7")
        let probe = ScheduleProbe()
        let s = T.supervisor(probe, root: root, failing: true)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        probe.generation = nil
        try await Task.sleep(for: .milliseconds(150))
        probe.generation = 1
        try await Task.sleep(for: .milliseconds(150))
        #expect(await T.jobs(s).count == 1, "the hold was released by an unreadable generation")
        #expect(await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false)
        await s.abandonForTest()
    }

    @Test("F8: a contender that does not own the root plans nothing and cannot rewrite the owner's holds")
    func contenderTouchesNothing() async throws {
        let root = try BackgroundFixtures.scratch("c235-f8")
        let owner = FileStateRootLock(root: root, owner: "cli --run era")
        guard case .success = owner.claim() else { Issue.record("could not claim"); return }
        defer { owner.release() }
        let hold = ScheduleHold(kind: ScheduleFactory.kind, jobID: JobID(), reason: "x", build: "b1")
        try ScheduleHoldStore.beside(stateRoot: root).save([hold])
        let before = try Data(contentsOf: root.appendingPathComponent("holds.json"))
        let probe = ScheduleProbe()
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: ScheduleFactory(recorder: UnitRecorder()), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), ownership: FileStateRootLock(root: root, owner: "service test"),
                              schedule: T.schedule(probe, root: root))
        await s.scheduleTick()
        await s.releaseHold(ScheduleFactory.kind, words: "test")
        #expect(probe.plans == 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("holds.json")) == before)
    }

    @Test("F9: a quarantined unit whose output is already durable is counted skipped, not failed")
    func quarantineReconcilesWithTheJob() async throws {
        let recorder = UnitRecorder()
        let request = JobRequest(kind: AlreadyRecordedFactory.kind, requestedBy: "test")
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 2)
        cp.inFlightUnit = 0
        cp.inFlightAttempts = 3
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        let log = InMemoryBackgroundLog()
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: AlreadyRecordedFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                              log: log, configuration: BackgroundFixtures.fastConfiguration())
        await s.start()
        await s.drain()
        #expect(recorder.completedUnits == [1])
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recorded \(request.id) — finished: 1 run · 1 skipped · 0 failed") }, "\(log.lines)")
    }
}

/// Refuses at START until `allow` is set (a dependency repaired), then a gated job.
final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var _on = false
    var on: Bool { get { lock.lock(); defer { lock.unlock() }; return _on } set { lock.lock(); _on = newValue; lock.unlock() } }
}

struct RefuseThenGateFactory: JobFactory {
    let allow: Toggle
    let gate: UnitGate
    let recorder: UnitRecorder
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        guard allow.on else { throw Refusal("weights missing") }
        return try GatedFactory(recorder: recorder, gate: gate, heldUnit: 0).makeJob(for: request)
    }
}

@Suite("JobSchedule — Codex #236 closing reds", .serialized)
struct JobScheduleCodex236Tests {
    typealias T = JobScheduleTests

    @Test("F1: EraJob's real load-failure words (two loads, then fail fast) make a short plan FAIL, not finish")
    func eraLoadFailureWordsAreOneStreak() async throws {
        let c = EraCounters()
        let first = await c.loadFailed("broken model")
        let second = await c.loadFailed("broken model")
        let remaining = try #require(await c.failFast)
        let r = await JobSupervisorFailFastTests.run([first, second, remaining])
        guard case .failed? = r.state else { Issue.record("state \(String(describing: r.state))"); return }
    }

    @Test("F2: a crash after the last unit's checkpoint, before finish, relaunches into FAILED and a hold — not finished")
    func failedVerdictSurvivesARelaunch() async throws {
        let root = try BackgroundFixtures.scratch("c236-f2")
        let probe = ScheduleProbe()
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 1)
        cp.completedUnits = 1
        cp.unitsFailed = 1
        var streak = FailureStreak()
        streak.record("ffmpeg is missing", unit: 0, systemic: true)
        streak.save(into: &cp)
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: ScheduleFactory(recorder: UnitRecorder(), failing: true, failingUnits: { 1 }),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(), schedule: T.schedule(probe, root: root))
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.snapshot(request.id)?.state.isActive == false })
        guard case .failed? = await s.snapshot(request.id)?.state else {
            Issue.record("relaunch said \(String(describing: await s.snapshot(request.id)?.state))"); return
        }
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        await s.abandonForTest()
    }

    @Test("F3b (amended by #239): Resume after a START refusal drops the kept request and runs ONE fresh job — never two")
    func resumeRequeuesTheKeptRequest() async throws {
        let root = try BackgroundFixtures.scratch("c236-f3b")
        let probe = ScheduleProbe()
        probe.size = 0                      // nothing new to plan: only the kept request
        let a = JobRequest(kind: GatedFactory.kind, requestedBy: "schedule")
        let queue = InMemoryJobQueueStore([a])
        let allow = Toggle()
        let gate = UnitGate()
        var sc = JobSchedule(kinds: [JobSchedule.Kind(kind: GatedFactory.kind, planSize: { probe.planned() }, makeRequest: { GatedFactory.request() })],
                             generation: { 1 }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        sc.pollInterval = .milliseconds(20)
        let s = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(),
                              factory: RefuseThenGateFactory(allow: allow, gate: gate, recorder: UnitRecorder()),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(), schedule: sc)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        #expect(!queue.contains(a.id), "a START refusal no longer keeps its file (Fable review 11/04)")
        allow.on = true
        probe.size = 3
        #expect(await s.resume(a.id))
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld }, "a fresh job ran")
        let jobs = await T.jobs(s)
        #expect(jobs.filter { $0.state.isActive }.count == 1, "\(jobs.map { ($0.id, $0.state) })")
        #expect(queue.list().requests.count == 1 && !queue.contains(a.id), "the old request is dropped; one fresh request")
        gate.open()
        await s.abandonForTest()
    }

    @Test("F4: a torn holds file is moved aside and its fail-closed holds written, so a new build releases them")
    func tornFileReleasedByANewBuild() async throws {
        let root = try BackgroundFixtures.scratch("c236-f4")
        try Data("{not json".utf8).write(to: root.appendingPathComponent("holds.json"))
        let probe = ScheduleProbe()
        let first = T.supervisor(probe, root: root)
        await first.start()
        try await Task.sleep(for: .milliseconds(150))
        await first.abandonForTest()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("holds.json.unreadable-") }, "kept aside: \(names)")
        let recorder = UnitRecorder()
        let second = T.supervisor(probe, root: root, build: "b2", recorder: recorder)
        await second.start()
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "a new build released the fail-closed hold")
        await second.abandonForTest()
    }
}

@Suite("JobSchedule — Codex #237 closing reds", .serialized)
struct JobScheduleCodex237Tests {
    typealias T = JobScheduleTests

    static func relaunch(_ cp: JobCheckpoint, request: JobRequest, root: URL, log: InMemoryBackgroundLog = InMemoryBackgroundLog()) -> JobSupervisor {
        let checkpoints = InMemoryCheckpointStore()
        try? checkpoints.save(cp)
        return JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                             factory: ScheduleFactory(recorder: UnitRecorder(), failing: true, failingUnits: { cp.totalUnits }),
                             backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration(),
                             schedule: T.schedule(ScheduleProbe(), root: root))
    }

    static func checkpoint(_ request: JobRequest, total: Int, completed: Int, run: Int, failed: Int, streak: Int) -> JobCheckpoint {
        var cp = JobCheckpoint(jobID: request.id, totalUnits: total)
        cp.completedUnits = completed
        cp.unitsRun = run
        cp.unitsFailed = failed
        var st = FailureStreak()
        for u in (completed - streak)..<completed { st.record("ffmpeg is missing", unit: u, systemic: true) }
        st.save(into: &cp)
        return cp
    }

    @Test("F1: one success then five identical failures, crash before finish — the relaunch says FAILED and holds")
    func restoredFailFastAtTheEndIsAFailure() async throws {
        let root = try BackgroundFixtures.scratch("c237-f1a")
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        let s = Self.relaunch(Self.checkpoint(request, total: 6, completed: 6, run: 1, failed: 5, streak: 5), request: request, root: root)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.snapshot(request.id)?.state.isActive == false })
        guard case .failed? = await s.snapshot(request.id)?.state else {
            Issue.record("relaunch said \(String(describing: await s.snapshot(request.id)?.state))"); return
        }
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        await s.abandonForTest()
    }

    @Test("F1: a restored streak at the fail-fast threshold stops the job before another unit runs")
    func restoredFailFastMidPlanStopsAtOnce() async throws {
        let root = try BackgroundFixtures.scratch("c237-f1b")
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        let log = InMemoryBackgroundLog()
        let s = Self.relaunch(Self.checkpoint(request, total: 10, completed: 6, run: 1, failed: 5, streak: 5), request: request, root: root, log: log)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.snapshot(request.id)?.state.isActive == false })
        guard case .failed? = await s.snapshot(request.id)?.state else { Issue.record("not failed"); return }
        #expect(!log.lines.contains { $0.contains("unit 6 failed") }, "a unit ran after the restored streak: \(log.lines)")
        await s.abandonForTest()
    }

}

@Suite("JobSchedule — Codex #238 closing reds", .serialized)
struct JobScheduleCodex238Tests {
    typealias T = JobScheduleTests

    @Test("F1: Resume on an adopted request whose checkpoint carries the held fail-fast streak runs work — no instant re-fail")
    func resumeForgetsTheHeldStreak() async throws {
        let root = try BackgroundFixtures.scratch("c238-f1")
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 3)
        cp.completedUnits = 3
        cp.unitsFailed = 3
        var st = FailureStreak()
        for u in 0..<3 { st.record("ffmpeg is missing", unit: u, systemic: true) }
        st.save(into: &cp)
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        try ScheduleHoldStore.beside(stateRoot: root).save([ScheduleHold(kind: ScheduleFactory.kind, jobID: request.id, reason: "ffmpeg is missing",
                                                                         build: "b1")])
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let probe = ScheduleProbe()
        var config = BackgroundFixtures.fastConfiguration()
        config.failFastUnits = 3
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: ScheduleFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                              log: log, configuration: config, schedule: T.schedule(probe, root: root))
        await s.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.completedUnits.isEmpty, "held: nothing runs")
        #expect(await s.resume(request.id))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 }, "the dependency is back: work runs \(log.lines)")
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds == [] }, "no hold came back")
        await s.abandonForTest()
    }

    @Test("F1 mid-plan (amended by #239): Resume drops the half-done adopted job and a fresh job runs its own plan")
    func resumeMidPlanRunsTheRest() async throws {
        let root = try BackgroundFixtures.scratch("c238-f1b")
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 6)
        cp.completedUnits = 3
        cp.unitsFailed = 3
        var st = FailureStreak()
        for u in 0..<3 { st.record("ffmpeg is missing", unit: u, systemic: true) }
        st.save(into: &cp)
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        try ScheduleHoldStore.beside(stateRoot: root).save([ScheduleHold(kind: ScheduleFactory.kind, jobID: request.id, reason: "ffmpeg is missing",
                                                                         build: "b1")])
        let recorder = UnitRecorder()
        var config = BackgroundFixtures.fastConfiguration()
        config.failFastUnits = 3
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: ScheduleFactory(recorder: recorder), backoff: BackgroundFixtures.fullBackoff(),
                              log: InMemoryBackgroundLog(), configuration: config, schedule: T.schedule(ScheduleProbe(), root: root))
        await s.start()
        #expect(await s.resume(request.id))
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits == [0, 1, 2] }, "a fresh job runs its own plan: \(recorder.completedUnits)")
        await s.abandonForTest()
    }

    @Test("F2 (amended by the Fable review): a factory refusal at the schedule's admission holds the kind; a later tick does not retry it")
    func admissionRefusalHolds() async throws {
        let root = try BackgroundFixtures.scratch("c238-f2")
        let probe = ScheduleProbe()
        let allow = Toggle()
        let gate = UnitGate()
        var sc = JobSchedule(kinds: [JobSchedule.Kind(kind: GatedFactory.kind, planSize: { probe.planned() }, makeRequest: { GatedFactory.request() })],
                             generation: { 1 }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        sc.planInterval = .milliseconds(30)
        sc.pollInterval = .milliseconds(20)
        let s = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                              factory: RefuseThenGateFactory(allow: allow, gate: gate, recorder: UnitRecorder()),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(), schedule: sc)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false },
                "the refusal held the kind")
        allow.on = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(!gate.isHeld, "a tick retried a held kind without a release")
        await s.abandonForTest()
    }
}

@Suite("JobSchedule — Codex #239 closing reds", .serialized)
struct JobScheduleCodex239Tests {
    typealias T = JobScheduleTests

    @Test("F2: after Resume the released attempt is counted fresh — a failure that repeats holds again, no retry after it")
    func releasedAttemptFailingAgainHolds() async throws {
        let root = try BackgroundFixtures.scratch("c239-f2")
        let request = JobRequest(kind: ScheduleFactory.kind, requestedBy: "schedule")
        var cp = JobCheckpoint(jobID: request.id, totalUnits: 6)
        cp.completedUnits = 5
        cp.unitsFailed = 5
        var st = FailureStreak()
        for u in 0..<5 { st.record("ffmpeg is missing", unit: u, systemic: true) }
        st.save(into: &cp)
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        try ScheduleHoldStore.beside(stateRoot: root).save([ScheduleHold(kind: ScheduleFactory.kind, jobID: request.id, reason: "ffmpeg is missing",
                                                                         build: "b1")])
        let s = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: checkpoints,
                              factory: ScheduleFactory(recorder: UnitRecorder(), failing: true, failingUnits: { 2 }),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(),
                              schedule: T.schedule(ScheduleProbe(), root: root, planInterval: .milliseconds(40)))
        await s.start()
        #expect(await s.resume(request.id))
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.first.map { $0.jobID != request.id } == true },
                "the fresh attempt failed the same way and holds again")
        try await Task.sleep(for: .milliseconds(250))
        #expect(await T.jobs(s).count == 1, "one fresh attempt, then held — no retry after it")
        await s.abandonForTest()
    }

    @Test("F3: a START-refused request that carried a fail-fast streak is dropped on Resume; a fresh job reaches its gate")
    func refusedRequestWithAStreakRunsFreshOnResume() async throws {
        let root = try BackgroundFixtures.scratch("c239-f3")
        let a = JobRequest(kind: GatedFactory.kind, requestedBy: "schedule")
        var cp = JobCheckpoint(jobID: a.id, totalUnits: 6)
        cp.completedUnits = 5
        cp.unitsFailed = 5
        var st = FailureStreak()
        for u in 0..<5 { st.record("x", unit: u, systemic: true) }
        st.save(into: &cp)
        let checkpoints = InMemoryCheckpointStore()
        try checkpoints.save(cp)
        let probe = ScheduleProbe()
        let allow = Toggle()
        let gate = UnitGate()
        var sc = JobSchedule(kinds: [JobSchedule.Kind(kind: GatedFactory.kind, planSize: { probe.planned() }, makeRequest: { GatedFactory.request() })],
                             generation: { 1 }, buildID: "b1", holds: ScheduleHoldStore.beside(stateRoot: root))
        sc.pollInterval = .milliseconds(20)
        let s = JobSupervisor(queue: InMemoryJobQueueStore([a]), checkpoints: checkpoints,
                              factory: RefuseThenGateFactory(allow: allow, gate: gate, recorder: UnitRecorder()),
                              backoff: BackgroundFixtures.fullBackoff(), log: InMemoryBackgroundLog(),
                              configuration: BackgroundFixtures.fastConfiguration(), schedule: sc)
        await s.start()
        #expect(await BackgroundFixtures.waitUntil { await s.status(processIdentifier: 1, startedAt: Date()).holds?.isEmpty == false })
        allow.on = true
        #expect(await s.resume(a.id))
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld }, "the obsolete streak failed the work again")
        gate.open()
        await s.abandonForTest()
    }
}
