// BackgroundServiceStoreTests.swift — Settings ▸ Background's Content
// Analysis rows (BackgroundServiceStore + BackgroundServicePresentation).
//
// Dimensions: LOGIC (the toggle's two paths, the enqueue rule, one enqueue
// per recount, refusals shown and logged), TRUTH (no line says "running"
// without an answer; the hand-started run is read from its checkpoint's
// updatedAt), ISOLATION (a torn checkpoint is skipped; a viewer refuses the
// toggle). Scale: the count is EraPlanner.plan — its 100k-row budget is
// pinned in VideoScanCore's EraJob scale tests. No real SMAppService, no
// XPC, no defaults: every seam is a closure.

import Foundation
import ServiceManagement
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("BackgroundServiceStore — the one setter for VideoScan Background")
struct BackgroundServiceStoreTests {

    final class FakeAgent: BackgroundAgentService {
        var registerCalls = 0
        var unregisterCalls = 0
        var status: SMAppService.Status
        init(_ status: SMAppService.Status) { self.status = status }
        func register() throws { registerCalls += 1; if status == .notRegistered { status = .enabled } }
        func unregister() throws { unregisterCalls += 1; status = .notRegistered }
    }

    /// Everything the store said and asked, for the assertions.
    @MainActor
    final class Recorder {
        var persisted: [Bool] = []
        var lines: [String] = []
        var statusAsks = 0
        var enqueued: [JobRequest] = []
        var counts = 0
    }

    static func serviceStatus(jobs: [JobProgressSnapshot] = []) -> ServiceStatus {
        ServiceStatus(processIdentifier: 4242, startedAt: Date(), backoff: .trickle, jobs: jobs, idleSeconds: 12)
    }

    static func eraJob(_ state: JobRunState, done: Int = 100, total: Int = 4_709) -> JobProgressSnapshot {
        JobProgressSnapshot(id: JobID(), kind: .era, lane: "model", title: "Machine era (8B)", subtitle: "",
                            completedUnits: done, totalUnits: total, skippedUnits: 0, failedUnits: 0,
                            state: state, startedAt: Date(), finishedAt: nil)
    }

    static func make(enabled: Bool, agent: FakeAgent, status: Result<ServiceStatus, Refusal> = .success(serviceStatus()),
                     work: Result<BackgroundWorkCount, Refusal> = .success(BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil)),
                     reply: Result<EnqueueReply, Refusal> = .success(.accepted(JobID(rawValue: "JOB-1"))),
                     readOnly: Bool = false) -> (BackgroundServiceStore, Recorder) {
        let r = Recorder()
        let store = BackgroundServiceStore(
            enabled: enabled,
            agent: { agent },
            askStatus: { r.statusAsks += 1; return status },
            enqueueRequest: { r.enqueued.append($0); return reply },
            countWork: { _ in r.counts += 1; return work },
            findHandRun: { _ in nil },
            makeRequest: { EraJob.request(limit: nil, repoPath: "/tmp/repo", requestedBy: "app") },
            persist: { r.persisted.append($0) },
            isViewer: { readOnly },
            log: { r.lines.append($0) })
        return (store, r)
    }

    // MARK: The toggle

    @Test("on: register once, persist true, one log line with launchd's word, then a recount that enqueues the era job")
    func toggleOn() async throws {
        let agent = FakeAgent(.notRegistered)
        let (store, r) = Self.make(enabled: false, agent: agent)
        store.setEnabled(true)
        #expect(store.enabled)
        #expect(agent.registerCalls == 1)
        #expect(r.persisted == [true])
        #expect(r.lines.count == 1 && r.lines[0].contains("registered") && r.lines[0].contains("enabled"), "\(r.lines)")
        #expect(store.launchdStatus == .enabled)
        // The recounting refresh runs as a Task; wait for it.
        try await Self.settle { store.enqueueCount == 1 }
        #expect(r.counts == 1)
        #expect(r.enqueued.count == 1)
        #expect(r.enqueued.first?.kind == .era)
        #expect(r.enqueued.first?.requestedBy == "app")
        #expect(store.lastNote == "queued era JOB-1")
        #expect(r.lines.last?.contains("enqueued era JOB-1 — 3,878 files left") == true, "\(r.lines)")
    }

    @Test("off: unregister once, persist false, the helper's words are cleared")
    func toggleOff() async {
        let agent = FakeAgent(.enabled)
        let (store, r) = Self.make(enabled: true, agent: agent)
        await store.refresh(recount: false)
        #expect(store.service != nil)
        store.setEnabled(false)
        #expect(!store.enabled)
        #expect(agent.unregisterCalls == 1)
        #expect(r.persisted == [false])
        #expect(store.service == nil)
        #expect(store.launchdStatus == .notRegistered)
        #expect(r.lines.contains { $0.contains("unregistered") }, "\(r.lines)")
    }

    @Test("a viewer Mac: the toggle is refused — nothing registered, nothing persisted, a reason shown")
    func viewerRefuses() {
        let agent = FakeAgent(.notRegistered)
        let (store, r) = Self.make(enabled: false, agent: agent, readOnly: true)
        store.setEnabled(true)
        #expect(!store.enabled)
        #expect(agent.registerCalls == 0)
        #expect(r.persisted.isEmpty)
        #expect(store.lastNote?.contains("viewer") == true)
    }

    @Test("setting the value it already has is a no-op")
    func sameValueIsNoOp() {
        let agent = FakeAgent(.enabled)
        let (store, r) = Self.make(enabled: true, agent: agent)
        store.setEnabled(true)
        #expect(agent.registerCalls == 0 && r.persisted.isEmpty && r.lines.isEmpty)
    }

    // MARK: The enqueue rule

    @Test("the pure rule: every condition must hold")
    func shouldEnqueueTable() {
        let idle = Self.serviceStatus()
        let busy = Self.serviceStatus(jobs: [Self.eraJob(.running)])
        let finished = Self.serviceStatus(jobs: [Self.eraJob(.finished)])
        let left = BackgroundWorkCount(filesLeft: 10, foregroundRun: nil)
        let none = BackgroundWorkCount(filesLeft: 0, foregroundRun: nil)
        let hand = BackgroundWorkCount(filesLeft: 10, foregroundRun: JobCheckpoint(jobID: JobID(), totalUnits: 5))
        typealias R = BackgroundServiceStore
        #expect(R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: idle, work: left))
        #expect(R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: finished, work: left), "a finished job is not active")
        #expect(!R.shouldEnqueue(enabled: false, viewer: false, launchd: .enabled, service: idle, work: left))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .requiresApproval, service: idle, work: left))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .notRegistered, service: idle, work: left))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: nil, service: idle, work: left))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: nil, work: left), "no answer, no enqueue")
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: busy, work: left))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: idle, work: none))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: idle, work: nil))
        #expect(!R.shouldEnqueue(enabled: true, viewer: false, launchd: .enabled, service: idle, work: hand), "a hand-started run holds the lane")
        #expect(!R.shouldEnqueue(enabled: true, viewer: true, launchd: .enabled, service: idle, work: left), "a viewer never queues")
    }

    @Test("launchd waiting for approval: the helper is never asked (asking would start it) and nothing is queued")
    func requiresApprovalAsksNothing() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.requiresApproval))
        await store.refresh(recount: true)
        #expect(r.statusAsks == 0)
        #expect(r.enqueued.isEmpty)
        #expect(store.service == nil)
        #expect(r.counts == 1, "the count still runs so the line can say how much is left")
    }

    @Test("a refresh without a recount never enqueues, even with work left")
    func staleCountNeverEnqueues() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled))
        await store.refresh(recount: true)
        #expect(r.enqueued.count == 1)
        for _ in 0..<5 { await store.refresh(recount: false) }
        #expect(r.enqueued.count == 1, "the 5 s visible poll is read-only")
        #expect(r.counts == 1)
    }

    /// Regression (codex-1102 review): `refresh` never asked `isViewer`, so a
    /// Mac that was master with the flag on and is now a viewer queued the
    /// era job on its launch recount — the toggle's guard was the only one.
    @Test("a viewer Mac with the flag already on never enqueues, on the launch recount or any later one")
    func viewerNeverEnqueues() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled), readOnly: true)
        await store.refresh(recount: true)
        await store.refresh(recount: true)
        #expect(r.enqueued.isEmpty, "a viewer queued \(r.enqueued.count) job(s)")
        #expect(store.enqueueCount == 0)
        // Codex 11/03 F1 (decision): a viewer counts nothing — the master runs
        // content analysis, and this Mac's own catalog.sqlite is not what it shows.
        #expect(r.counts == 0, "no count on a viewer")
    }

    /// Regression (codex-1102 review): two recounting refreshes interleaved
    /// across their awaits (the launch cycle and the toggle's Task) — both
    /// read the same pre-enqueue status and both queued an era job.
    @Test("two recounts in flight at once queue the era job once")
    func overlappingRecountsEnqueueOnce() async {
        let r = Recorder()
        let store = BackgroundServiceStore(
            enabled: true,
            agent: { FakeAgent(.enabled) },
            askStatus: {
                r.statusAsks += 1
                // The helper lists what it was given: after one enqueue its era job is running.
                return .success(Self.serviceStatus(jobs: r.enqueued.isEmpty ? [] : [Self.eraJob(.running)]))
            },
            enqueueRequest: { r.enqueued.append($0); try? await Task.sleep(for: .milliseconds(40)); return .success(.accepted($0.id)) },
            countWork: { _ in r.counts += 1; try? await Task.sleep(for: .milliseconds(40))
                return .success(BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil)) },
            findHandRun: { _ in nil },
            makeRequest: { EraJob.request(limit: nil, repoPath: "/tmp/repo", requestedBy: "app") },
            persist: { _ in },
            isViewer: { false },
            log: { r.lines.append($0) })
        async let first: Void = store.refresh(recount: true)
        async let second: Void = store.refresh(recount: true)
        _ = await (first, second)
        #expect(r.enqueued.count == 1, "queued \(r.enqueued.count) era jobs from one burst of recounts")
        #expect(store.service?.jobs.contains { $0.kind == .era && $0.state.isActive } == true)
    }

    /// Regression (codex-1102 F4): a failed recount kept the previous count
    /// and enqueued on it — the rule is "only from a fresh count".
    @Test("a recount that fails never enqueues on the previous count")
    func failedRecountCannotEnqueue() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled))
        await store.refresh(recount: true)
        #expect(r.enqueued.count == 1)
        store.countWork = { _ in .failure(Refusal("catalog unavailable")) }
        await store.refresh(recount: true)
        #expect(r.enqueued.count == 1, "a failed count queued again on the old number")
        #expect(store.work == nil, "the old count is not shown as current")
        #expect(store.workProblem == "catalog unavailable")
    }

    /// Regression (codex-1102 F5): the hand run's line came from the count
    /// only, so after the run exited the visible poll kept saying "running
    /// outside the service" until the next recount (never, while off).
    @Test("the visible poll re-reads the hand run: when it is gone, the line stops saying running")
    func visiblePollClearsAFinishedHandRun() async {
        var hand = JobCheckpoint(jobID: JobID(rawValue: "HAND"), totalUnits: 4_709)
        hand.completedUnits = 831
        let (store, _) = Self.make(enabled: false, agent: FakeAgent(.notRegistered),
                                   work: .success(BackgroundWorkCount(filesLeft: 3_878, foregroundRun: hand)))
        var live: JobCheckpoint? = hand
        store.findHandRun = { _ in live }
        await store.refresh(recount: true)
        #expect(store.work?.foregroundRun?.jobID == hand.jobID)
        live = nil
        await store.refresh(recount: false)
        #expect(store.work?.foregroundRun == nil, "the hand run exited; the line must not still say running")
        #expect(store.work?.filesLeft == 3_878, "the count itself stands until the next recount")
    }

    /// Regression (codex-1102 F6): unregister failed, launchd still said
    /// enabled, and the line said "off".
    @Test("unregister fails and launchd still says enabled: the line says so, never plain off")
    func failedUnregisterIsNotOff() async {
        final class StuckAgent: BackgroundAgentService {
            var status: SMAppService.Status = .enabled
            func register() throws {}
            func unregister() throws { throw Refusal("Operation not permitted") }
        }
        let agent = StuckAgent()
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled))
        store.agent = { agent }
        store.setEnabled(false)
        let l = BackgroundServicePresentation.lines(enabled: store.enabled, launchd: store.launchdStatus, service: store.service,
                                                    serviceProblem: store.serviceProblem, work: store.work, workProblem: store.workProblem,
                                                    lastNote: store.lastNote, time: { _ in "16:16" })
        #expect(!l.helper.hasPrefix("VideoScan Background: off"), "\(l.helper)")
        #expect(l.helper.contains("Operation not permitted"), "\(l.helper)")
        #expect(r.lines.contains { $0.contains("unregister failed") }, "\(r.lines)")
    }

    @Test("an active era job in the helper's answer: nothing more is queued")
    func activeJobBlocks() async {
        let busy = Self.serviceStatus(jobs: [Self.eraJob(.paused(reason: "thermal"))])
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled), status: .success(busy))
        await store.refresh(recount: true)
        #expect(r.enqueued.isEmpty)
    }

    @Test("the helper refuses: its words are shown on the job line and logged once")
    func refusalShownAndLogged() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled),
                                   reply: .success(.refused(Refusal("the 8B weights are not on this Mac"))))
        await store.refresh(recount: true)
        #expect(store.lastNote == "the 8B weights are not on this Mac")
        #expect(r.lines.filter { $0.contains("era refused — the 8B weights") }.count == 1, "\(r.lines)")
    }

    @Test("the helper does not answer: the problem is kept in words, the count still runs, nothing is queued")
    func notAnswering() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled),
                                   status: .failure(Refusal("VideoScan Background did not answer: connection invalid")))
        await store.refresh(recount: true)
        #expect(store.service == nil)
        #expect(store.serviceProblem?.contains("did not answer") == true)
        #expect(r.counts == 1)
        #expect(r.enqueued.isEmpty)
    }

    // MARK: The hand-started run (checkpoint files)

    @Test("a checkpoint touched within 15 minutes that the helper does not list is a hand-started run; the helper's own and stale ones are not; a torn file is skipped")
    func foregroundRunFromCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-store-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileCheckpointStore(directory: folder)
        let now = Date()

        let hand = JobID(rawValue: "HAND")
        var c = JobCheckpoint(jobID: hand, totalUnits: 4_709, startedAt: now.addingTimeInterval(-3_600))
        c.completedUnits = 831
        c.updatedAt = now.addingTimeInterval(-120)
        try store.save(c)
        let helpers = JobID(rawValue: "HELPER")
        var h = JobCheckpoint(jobID: helpers, totalUnits: 10, startedAt: now)
        h.updatedAt = now
        try store.save(h)
        let stale = JobID(rawValue: "STALE")
        var s = JobCheckpoint(jobID: stale, totalUnits: 10, startedAt: now.addingTimeInterval(-7_200))
        s.updatedAt = now.addingTimeInterval(-20 * 60)
        try store.save(s)
        try Data("{not json".utf8).write(to: folder.appendingPathComponent("TORN.json"))
        // The hand run is alive: it holds the state-root lock.
        let lock = FileStateRootLock(root: root, owner: "cli --run era")
        guard case .success = lock.claim() else { Issue.record("could not claim the root"); return }
        defer { lock.release() }

        let found = BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [helpers], now: now)
        #expect(found?.jobID == hand)
        #expect(found?.completedUnits == 831)
        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [helpers, hand], now: now) == nil)
        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [], now: now.addingTimeInterval(16 * 60)) == nil,
                "sixteen minutes later every checkpoint is stale")
        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root.appendingPathComponent("missing"), knownJobs: [], now: now) == nil)
    }

    /// Regression (codex-1102 F5): a recent checkpoint proves past progress,
    /// not a live run. The evidence of a live hand run is its held state-root
    /// lock (StateRootLock.swift) naming a `--run`; a dead run (kill -9) leaves
    /// a fresh checkpoint and a free lock.
    @Test("a hand run is live only while a --run holds the state-root lock; a fresh checkpoint alone is not")
    func handRunNeedsTheHeldLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-lock-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var c = JobCheckpoint(jobID: JobID(rawValue: "HAND"), totalUnits: 4_709, startedAt: now.addingTimeInterval(-600))
        c.updatedAt = now.addingTimeInterval(-30)
        try FileCheckpointStore(directory: folder).save(c)

        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [], now: now) == nil,
                "no process holds the root: the run died; its checkpoint is history, not a live run")

        let service = FileStateRootLock(root: root, owner: "service Rick-Breen.VideoScan.Background")
        guard case .success = service.claim() else { Issue.record("could not claim as the service"); return }
        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [], now: now) == nil,
                "the service holds the root: its checkpoints are not a hand run")
        service.release()

        let cli = FileStateRootLock(root: root, owner: "cli --run era")
        guard case .success = cli.claim() else { Issue.record("could not claim as the hand run"); return }
        defer { cli.release() }
        #expect(BackgroundServiceStore.foregroundRun(stateRoot: root, knownJobs: [], now: now)?.jobID == c.jobID)
    }

    /// Regression (codex-1102 F7): a helper that accepted the message and
    /// never replied left the refresh cycle suspended forever — no deadline.
    @Test("a helper that never replies: the call fails within its deadline; the late reply is dropped")
    func silentHelperTimesOut() async {
        final class Stash: @unchecked Sendable { var late: (@Sendable () -> Void)? }
        final class Done: @unchecked Sendable { var result: Result<Int, Refusal>? }
        let stash = Stash()
        let done = Done()
        let call = Task { @MainActor in
            done.result = await BackgroundServiceClient.awaitReply(within: .milliseconds(200)) { once in stash.late = { once.resume(.success(1)) } }
        }
        // Bounded so a red run fails here instead of hanging the suite.
        for _ in 0..<200 where done.result == nil { try? await Task.sleep(for: .milliseconds(10)) }
        guard case .failure(let refusal)? = done.result else {
            Issue.record("the call was still waiting 2 s after a 200 ms deadline")
            call.cancel()
            return
        }
        #expect(refusal.words.contains("did not answer within"), "\(refusal.words)")
        stash.late?()   // the late reply: dropped, no double resume
    }

    // MARK: The words (truth)

    static func lines(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus? = nil, problem: String? = nil,
                      work: BackgroundWorkCount? = nil, workProblem: String? = nil, note: String? = nil) -> BackgroundServicePresentation.Lines {
        BackgroundServicePresentation.lines(enabled: enabled, launchd: launchd, service: service, serviceProblem: problem,
                                            work: work, workProblem: workProblem, lastNote: note, time: { _ in "16:16" })
    }

    @Test("the helper line never says running without the helper's answer")
    func helperLineTruth() {
        let up = Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus())
        #expect(up.helper == "VideoScan Background: running · pid 4242 · trickle · idle 12 s")
        #expect(up.helperIsUp)
        let silent = Self.lines(enabled: true, launchd: .enabled, problem: "connection invalid")
        #expect(silent.helper == "VideoScan Background: enabled · not answering (connection invalid)")
        #expect(!silent.helperIsUp && !silent.helper.contains("running"))
        let asking = Self.lines(enabled: true, launchd: .enabled)
        #expect(asking.helper == "VideoScan Background: enabled · asking…")
        let off = Self.lines(enabled: false, launchd: .notRegistered)
        #expect(off.helper == "VideoScan Background: off" && !off.helperIsUp && !off.needsApproval)
        let offButListed = Self.lines(enabled: false, launchd: .enabled)
        #expect(offButListed.helper.contains("still listed in System Settings"))
        let approval = Self.lines(enabled: true, launchd: .requiresApproval)
        #expect(approval.needsApproval)
        #expect(approval.helper == "VideoScan Background: waiting for your approval in System Settings ▸ General ▸ Login Items")
        let unregistered = Self.lines(enabled: true, launchd: .notRegistered)
        #expect(unregistered.helper.contains("Fix: turn the checkbox off and on"))
        #expect(Self.lines(enabled: true, launchd: nil).helper == "VideoScan Background: asking launchd…")
    }

    @Test("the job line: a hand-started run first, then the helper's era job, then the count")
    func jobLineOrder() {
        var hand = JobCheckpoint(jobID: JobID(), totalUnits: 4_709)
        hand.completedUnits = 831
        let handRun = Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(jobs: [Self.eraJob(.running)]),
                                 work: BackgroundWorkCount(filesLeft: 3_878, foregroundRun: hand))
        #expect(handRun.job == "Machine era (8B): 831 of 4,709 · running outside the service (started by hand; last unit 16:16)")
        let helperJob = Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(jobs: [Self.eraJob(.paused(reason: "thermal"), done: 12)]),
                                   work: BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil))
        #expect(helperJob.job == "Machine era (8B): 12 of 4,709 · paused (thermal)")
        #expect(Self.lines(enabled: true, launchd: .enabled).job == "Content analysis: counting…")
        #expect(Self.lines(enabled: true, launchd: .enabled, work: BackgroundWorkCount(filesLeft: 0, foregroundRun: nil)).job
                == "Content analysis: nothing left to analyze")
        #expect(Self.lines(enabled: false, launchd: .notRegistered, work: BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil)).job
                == "Content analysis: 3,878 files to analyze — turn the checkbox on to analyze them")
        #expect(Self.lines(enabled: true, launchd: .enabled, work: BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil)).job
                == "Content analysis: 3,878 files to analyze · queued on the next check")
        #expect(Self.lines(enabled: true, launchd: .enabled, work: BackgroundWorkCount(filesLeft: 3_878, foregroundRun: nil), note: "queued era X").job
                == "Content analysis: 3,878 files to analyze · queued era X")
        #expect(Self.lines(enabled: true, launchd: .enabled, workProblem: "no catalog is open").job
                == "Content analysis: could not count — no catalog is open")
    }

    @Test("the defaults key is the registrar's — the launch and the pane read one flag")
    func oneKey() {
        #expect(BackgroundServiceStore.defaultsKey == BackgroundServiceRegistrar.enabledDefaultsKey)
        #expect(BackgroundServiceStore.defaultsKey == "background.service.enabled")
    }

    // MARK: -

    /// Poll a condition on the main actor for up to two seconds.
    static func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "did not settle in 2 s")
    }
}
