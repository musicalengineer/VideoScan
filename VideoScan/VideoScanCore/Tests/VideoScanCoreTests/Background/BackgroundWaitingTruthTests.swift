// BackgroundWaitingTruthTests.swift — regressions from the 11/03 checklist
// review (Codex cycle #220):
//
//   F3 (P0 TRUE) a cold era worker returns `.deferred` while Backoff trickles;
//      the supervisor logged the wait but kept `.running`, so the menu bar
//      showed the filled "working" lens and "· running" — and Settings the
//      same — while no unit could start. Supervisor → status → presentation.
//   F5 (P2 PERFORMANCE) the menu bar's 5 s in-process status read called
//      `touch()`, so `idleSeconds` never reached the exit threshold and the
//      helper (menu item, ownership lock) never exited. Shortened threshold.
//
// Dimensions: LOGIC + TRUTH (the words and glyph come from the supervisor's
// own state), ISOLATION (a waiting job that starts recording clears the
// wait), compatibility (a status payload without the new field decodes).

import Foundation
import Testing
@testable import VideoScanCore

/// Defers every unit while `gate` is closed, then records.
final class DeferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
}

struct DeferringJob: BackgroundJob {
    static let reason = "you're at the Mac (the model loads when you step away)"
    let title = "Machine era (8B)"
    let unitCount = 3
    let gate: DeferGate
    func runUnit(_ index: Int) async throws -> UnitOutcome {
        gate.isOpen ? .done : .deferred(reason: Self.reason)
    }
}

struct DeferringFactory: JobFactory {
    static let kind = JobKind(rawValue: "deferring")
    let gate: DeferGate
    func makeJob(for request: JobRequest) throws -> any BackgroundJob { DeferringJob(gate: gate) }
}

@Suite("Background truth — a waiting job is not 'running'; reading status is not activity")
struct BackgroundWaitingTruthTests {

    /// `trickling`: Rick typed 5 s ago — Backoff says `.trickle`, the era
    /// job's own condition for deferring.
    static func supervisor(_ gate: DeferGate, log: LogLines = LogLines(), trickling: Bool = false) -> JobSupervisor {
        var c = BackgroundFixtures.fastConfiguration()
        c.deferRetryInterval = .milliseconds(20)
        let backoff = trickling
            ? Backoff(source: FakeActivitySource(ActivitySample(secondsSinceLastInput: 5)), trickleInterval: .milliseconds(1))
            : BackgroundFixtures.fullBackoff(trickle: .milliseconds(1))
        return JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                             factory: DeferringFactory(gate: gate), backoff: backoff, log: log, configuration: c)
    }

    @Test("RED 11/03 F3: a deferred unit → the menu says waiting, outline glyph, never 'running'; Settings' words too")
    func deferredUnitIsWaitingNotRunning() async throws {
        let gate = DeferGate()
        let log = LogLines()
        let s = Self.supervisor(gate, log: log, trickling: true)
        _ = await s.enqueue(JobRequest(kind: DeferringFactory.kind, requestedBy: "test"))
        let waited = await BackgroundFixtures.waitUntil {
            log.lines.contains { $0.contains("waits at 0 of 3") }
        }
        #expect(waited, "\(log.lines)")
        let status = await s.status(processIdentifier: 1, startedAt: Date())
        let menu = BackgroundMenuPresentation.from(status)
        #expect(menu.icon != .working, "no unit can start: the lens is not filled")
        #expect(menu.icon == .waiting)
        let words = try #require(menu.jobs.first?.words)
        #expect(!words.hasSuffix("· running"), Comment(rawValue: words))
        #expect(words == "Machine era (8B) — 0 of 3 · waiting — \(DeferringJob.reason)", Comment(rawValue: words))
        #expect(menu.headline == "VideoScan Background — waiting (you're at the Mac)", Comment(rawValue: menu.headline))
        #expect(menu.tooltip.contains("waiting"), Comment(rawValue: menu.tooltip))
        // Settings reads the same snapshot's words.
        let job = try #require(status.jobs.first)
        #expect(job.waiting == DeferringJob.reason)
        #expect(job.stateWords == "waiting — \(DeferringJob.reason)")

        // The Mac lets it go: the next unit records and the wait is gone.
        gate.release()
        await s.drain()
        let after = await s.status(processIdentifier: 1, startedAt: Date())
        #expect(after.jobs.first?.waiting == nil)
        #expect(after.jobs.first?.state == .finished)
    }

    @Test("ISOLATION F3: a wait that is cleared by a recorded unit is not left on the row")
    func waitClearsWhenAUnitRecords() async {
        let gate = DeferGate()
        let log = LogLines()
        let s = Self.supervisor(gate, log: log)
        let id = JobID()
        _ = await s.enqueue(JobRequest(id: id, kind: DeferringFactory.kind, requestedBy: "test"))
        _ = await BackgroundFixtures.waitUntil { await s.snapshot(id)?.waiting != nil }
        #expect(await s.snapshot(id)?.waiting == DeferringJob.reason)
        #expect(await s.snapshot(id)?.state == .running, "the state stays the wire's own; the wait is beside it")
        gate.release()
        _ = await BackgroundFixtures.waitUntil { await s.snapshot(id)?.waiting == nil }
        #expect(await s.snapshot(id)?.waiting == nil)
        await s.drain()
    }

    @Test("COMPAT F3: a status payload from a build without `waiting` still decodes (additive field, same schema)")
    func olderPayloadDecodes() throws {
        let job = JobProgressSnapshot(id: JobID(rawValue: "J"), kind: .noop, lane: "default", title: "t", subtitle: "",
                                      completedUnits: 0, totalUnits: 1, skippedUnits: 0, failedUnits: 0,
                                      state: .running, startedAt: nil, finishedAt: nil)
        let data = try BackgroundPayloadCodec.encode(job)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(object["body"] as? [String: Any])
        body.removeValue(forKey: "waiting")
        object["body"] = body
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try BackgroundPayloadCodec.decode(JobProgressSnapshot.self, from: old)
        #expect(decoded.waiting == nil)
        #expect(decoded == job)
    }

    @Test("RED 11/03 F5: repeated menu-bar status reads do not hold an empty service up (shortened threshold)")
    func statusReadsAreNotActivity() async throws {
        let s = Self.supervisor(DeferGate())
        await s.start()
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(600)
        while clock.now < deadline {
            _ = await s.status(processIdentifier: 1, startedAt: Date())   // the menu bar's read
            try await Task.sleep(for: .milliseconds(25))
        }
        let idle = await s.idleSeconds
        #expect(await s.shouldExitWhenIdle(threshold: 0.3), "idle \(idle) s: watching is not working")
    }

    @Test("SENSOR F5: the XPC status handler marks client activity; the menu bar's read does not")
    func sensorWhoTouches() throws {
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScanBackground")
        let xpc = try String(contentsOf: helper.appendingPathComponent("XPCServer.swift"), encoding: .utf8)
        let start = try #require(xpc.range(of: "func status(reply:")).upperBound
        #expect(String(xpc[start...].prefix(500)).contains("await supervisor.noteClientActivity()"))
        let menu = try String(contentsOf: helper.appendingPathComponent("StatusMenuController.swift"), encoding: .utf8)
        #expect(!menu.contains("noteClientActivity"), "watching is not working")
    }

    @Test("F5: a client message (the app over XPC) is activity — the helper stays while VideoScan asks")
    func clientMessageIsActivity() async throws {
        let s = Self.supervisor(DeferGate())
        await s.start()
        try await Task.sleep(for: .milliseconds(400))
        await s.noteClientActivity()
        #expect(await !s.shouldExitWhenIdle(threshold: 0.3))
    }
}
