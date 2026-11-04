// BackgroundServiceStoreTests.swift — Settings ▸ Background's Content
// Analysis rows (BackgroundServiceStore + BackgroundServicePresentation).
//
// Since 2026-11-04 the helper owns its schedule: the store registers,
// unregisters and shows status — it never counts and never enqueues. The
// enqueue-rule, recount and hand-run tests (shouldEnqueueTable,
// staleCountNeverEnqueues, viewerNeverEnqueues, overlappingRecountsEnqueueOnce,
// failedRecountCannotEnqueue, visiblePollClearsAFinishedHandRun,
// activeJobBlocks, refusalShownAndLogged, foregroundRunFromCheckpoints,
// handRunNeedsTheHeldLock) went with that behaviour (git keeps them).
//
// Dimensions: LOGIC (the toggle's two paths; the toggle is register /
// unregister and nothing else), TRUTH (no line says "running" without an
// answer; the count shown is the helper's own plan; a hold is said in its
// words), ISOLATION (a viewer refuses the toggle; a silent helper times out).
// No real SMAppService, no XPC, no defaults: every seam is a closure.

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
    }

    static func serviceStatus(jobs: [JobProgressSnapshot] = [], planned: [String: Int]? = nil,
                              holds: [ScheduleHold]? = nil) -> ServiceStatus {
        ServiceStatus(processIdentifier: 4242, startedAt: Date(), backoff: .full, jobs: jobs, idleSeconds: 12,
                      holds: holds, planned: planned)
    }

    static func eraJob(_ state: JobRunState, done: Int = 100, total: Int = 4_709) -> JobProgressSnapshot {
        JobProgressSnapshot(id: JobID(), kind: .era, lane: "model", title: "Machine era (8B)", subtitle: "",
                            completedUnits: done, totalUnits: total, skippedUnits: 0, failedUnits: 0,
                            state: state, startedAt: Date(), finishedAt: nil)
    }

    static func make(enabled: Bool, agent: FakeAgent, status: Result<ServiceStatus, Refusal> = .success(serviceStatus()),
                     readOnly: Bool = false) -> (BackgroundServiceStore, Recorder) {
        let r = Recorder()
        let store = BackgroundServiceStore(
            enabled: enabled,
            agent: { agent },
            askStatus: { r.statusAsks += 1; return status },
            persist: { r.persisted.append($0) },
            isViewer: { readOnly },
            log: { r.lines.append($0) })
        return (store, r)
    }

    // MARK: The toggle

    @Test("RED→GREEN: on = register once, persist true, one log line with launchd's word, then a status read — and no enqueue")
    func toggleOn() async throws {
        let agent = FakeAgent(.notRegistered)
        let (store, r) = Self.make(enabled: false, agent: agent)
        store.setEnabled(true)
        #expect(store.enabled)
        #expect(agent.registerCalls == 1)
        #expect(r.persisted == [true])
        #expect(r.lines.count == 1 && r.lines[0].contains("registered") && r.lines[0].contains("enabled"), "\(r.lines)")
        #expect(store.launchdStatus == .enabled)
        try await Self.settle { r.statusAsks == 1 }
        #expect(!r.lines.contains { $0.contains("enqueue") }, "the helper plans its own work: \(r.lines)")
    }

    @Test("off: unregister once, persist false, the helper's words are cleared")
    func toggleOff() async {
        let agent = FakeAgent(.enabled)
        let (store, r) = Self.make(enabled: true, agent: agent)
        await store.refresh()
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

    @Test("launchd waiting for approval: the helper is never asked (asking would start it)")
    func requiresApprovalAsksNothing() async {
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.requiresApproval))
        await store.refresh()
        #expect(r.statusAsks == 0)
        #expect(store.service == nil)
    }

    @Test("the helper does not answer: the problem is kept in words")
    func notAnswering() async {
        let (store, _) = Self.make(enabled: true, agent: FakeAgent(.enabled),
                                   status: .failure(Refusal("VideoScan Background did not answer: connection invalid")))
        await store.refresh()
        #expect(store.service == nil)
        #expect(store.serviceProblem?.contains("did not answer") == true)
    }

    @Test("a hold in the helper's answer is logged once when it appears and once when it clears")
    func holdLoggedOnChange() async {
        let hold = ScheduleHold(kind: .era, jobID: JobID(rawValue: "J"), reason: "ffmpeg is missing", build: "b", generation: 1)
        let (store, r) = Self.make(enabled: true, agent: FakeAgent(.enabled), status: .success(Self.serviceStatus(holds: [hold])))
        await store.refresh()
        await store.refresh()
        #expect(r.lines.filter { $0.contains("held after a failure: ffmpeg is missing") }.count == 1, "\(r.lines)")
        store.askStatus = { .success(Self.serviceStatus(holds: [])) }
        await store.refresh()
        #expect(r.lines.contains { $0.contains("cleared — era held after a failure") }, "\(r.lines)")
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
                                                    serviceProblem: store.serviceProblem, lastNote: store.lastNote)
        #expect(!l.helper.hasPrefix("VideoScan Background: off"), "\(l.helper)")
        #expect(l.helper.contains("Operation not permitted"), "\(l.helper)")
        #expect(r.lines.contains { $0.contains("unregister failed") }, "\(r.lines)")
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
                      note: String? = nil) -> BackgroundServicePresentation.Lines {
        BackgroundServicePresentation.lines(enabled: enabled, launchd: launchd, service: service, serviceProblem: problem, lastNote: note)
    }

    @Test("the helper line never says running without the helper's answer")
    func helperLineTruth() {
        let up = Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus())
        #expect(up.helper == "VideoScan Background: running · pid 4242 · full")
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

    @Test("TRUTH: the job line — the helper's era job, else its hold, else ITS plan size (the app counts nothing)")
    func jobLineOrder() {
        let helperJob = Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(jobs: [Self.eraJob(.paused(reason: "thermal"), done: 12)]))
        #expect(helperJob.job == "Machine era (8B): 12 of 4,709 · paused (thermal)")
        let hold = ScheduleHold(kind: .era, jobID: JobID(), reason: "the worker could not load the model", build: "b", generation: 3)
        #expect(Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(holds: [hold])).job
                == "Machine era (8B): held after a failure: the worker could not load the model — Resume, a new build or a catalog change clears it (Resume is in the VideoScan Background menu bar item)")
        #expect(Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(planned: ["era": 3_878])).job
                == "Content analysis: 3,878 files to analyze (the helper's plan)")
        #expect(Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus(planned: ["era": 0])).job
                == "Content analysis: nothing left to analyze (the helper's plan)")
        #expect(Self.lines(enabled: true, launchd: .enabled, service: Self.serviceStatus()).job
                == "Content analysis: the helper has not planned yet")
        #expect(Self.lines(enabled: true, launchd: .enabled).job == "Content analysis: the helper is not answering — no plan to show")
        #expect(Self.lines(enabled: false, launchd: .notRegistered).job
                == "Content analysis: off — turn the checkbox on to analyze in the background")
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
