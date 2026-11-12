// CatalogUpdateOrderTests.swift — GH #441 (Rick 2026-11-06: "a user,
// looking at the catalog, sees red, thinks the DB is screwed up — we still
// need to show truth, but the order in which we do things should be more
// natural and less likely to freak the user out").
//
// On 11/06 at 17:02 "Update everything stale" ran the catalog check SECOND
// (registry order: Sound Prints, Integrity, Detect Duplicates, …); the check
// found 262 sampled-hash duplicate groups whose members now carried different
// whole-file digests and the Catalog indicator went Unhealthy; Detect
// Duplicates rebuilt those groups one second later, and the red stood for
// three minutes until Check Now…
//
//   ORDER     (d) the chain's order is pinned: everything that feeds or
//             rebuilds what the check judges first, the check ONCE, LAST
//             (added when it was not stale); the queue starts the check only
//             after every other step has finished
//   TRUTH     (a) REAL engines in a sandbox — Detect Duplicates and Validate
//             Catalog — through the real queue, the real snapshot and its
//             transition log: an Update over stale-but-healable groups never
//             logs a red transition and ends Synced
//             (b) a real structural break no Update step fixes (a
//             supersession circle) still ends Unhealthy with its cause and fix
//   LOGIC     (c) while the Update runs Catalog reads grey "Checking…" over
//             every colour, the window still says what the last check found,
//             and the indicator is coloured again only when the queue drains
//   SENSOR    both Update buttons go through the one queue; the model wires
//             the snapshot to it
//
// Scale: not applicable (at most 13 kinds; the snapshot's scale is pinned in
// CatalogStatusSplitScaleTests). Media matrix: not applicable (no media is
// decoded; the audit stats files, the check reads rows).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - A scripted runner (the queue's seam)

/// Runs each step's closure as the "engine": `isRunning` is true until the
/// closure returns. A kind with no closure refuses (never runs), as a real
/// engine that is busy does.
@MainActor
final class ScriptedUpdateRunner: CatalogUpdateStepRunning {
    var steps: [AnalyzeCycler: () async -> Void] = [:]
    private(set) var started: [AnalyzeCycler] = []
    /// What else was running when each step started.
    private(set) var runningAtStart: [AnalyzeCycler: Set<AnalyzeCycler>] = [:]
    private var inFlight: Set<AnalyzeCycler> = []
    private(set) var lines: [String] = []

    /// A check (or audit) started somewhere else — the daily file check, a
    /// menu item — that this queue did not start (Codex sweep 11/09 F2).
    var runningElsewhere: Set<AnalyzeCycler> = []
    /// What `flushCatalog` answers, and `started.count` at each flush.
    var flushAcknowledged = true
    private(set) var flushes: [Int] = []

    @discardableResult
    func runNow(_ cycler: AnalyzeCycler, volume: String?, source: String) -> Bool {
        started.append(cycler)
        runningAtStart[cycler] = inFlight.union(runningElsewhere)
        guard let step = steps[cycler] else { return false }
        inFlight.insert(cycler)
        Task { @MainActor in
            await step()
            self.inFlight.remove(cycler)
        }
        return true
    }

    func isRunning(_ cycler: AnalyzeCycler) -> Bool { inFlight.contains(cycler) || runningElsewhere.contains(cycler) }
    func note(_ line: String) { lines.append(line) }
    func flushCatalog() -> Bool { flushes.append(started.count); return flushAcknowledged }
    /// Steps that start, then refuse inside their own task (re-review F5).
    var refusedLater: Set<AnalyzeCycler> = []
    func stepRan(_ cycler: AnalyzeCycler) -> Bool { !refusedLater.contains(cycler) }
}

@MainActor
private func drain(_ queue: CatalogStatusUpdateQueue, seconds: Double = 30) async {
    let deadline = Date().addingTimeInterval(seconds)
    while queue.isActive, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
private func fastQueue() -> CatalogStatusUpdateQueue {
    let queue = CatalogStatusUpdateQueue()
    queue.graceSeconds = 0
    queue.pollMilliseconds = 10
    return queue
}

// MARK: - (d) The order

@Suite("Update everything stale — the order (GH #441)", .serialized)
@MainActor
struct CatalogUpdateOrderTests {

    @Test("ORDER: every step that feeds or rebuilds what the check judges runs first, in registry order; the catalog check runs ONCE, LAST")
    func planPinsTheCheckLast() {
        #expect(CatalogStatusUpdateQueue.plan(AnalyzeCycler.allCases)
                == [.filePresence, .fullHashes, .soundPrints, .duplicates, .footage, .sceneCaptions, .ocr, .transcribe,
                    .correlate, .fileSignatures, .embeddedDates, .dateInference, .integrity])
        // The 11/06 17:01:43 list, exactly as staleCyclers handed it over.
        let rick = [AnalyzeCycler.soundPrints, .integrity, .duplicates, .sceneCaptions, .ocr, .transcribe, .correlate, .embeddedDates, .dateInference]
        let plan = CatalogStatusUpdateQueue.plan(rick)
        #expect(plan == [.soundPrints, .duplicates, .sceneCaptions, .ocr, .transcribe, .correlate, .embeddedDates, .dateInference, .integrity])
        #expect(plan.filter { $0 == .integrity }.count == 1, "the check runs once")
        // Not stale, still run last: the colour an Update leaves describes the catalog it left.
        #expect(CatalogStatusUpdateQueue.plan([.duplicates]) == [.duplicates, .integrity])
        #expect(CatalogStatusUpdateQueue.plan([.integrity]) == [.integrity])
        #expect(CatalogStatusUpdateQueue.plan([.dateInference, .duplicates, .dateInference]) == [.duplicates, .dateInference, .integrity],
                "a kind asked twice runs once")
        #expect(CatalogStatusUpdateQueue.plan([]).isEmpty, "nothing stale → nothing run, not even the check")
        // Every order: the check is last and nothing is lost.
        for kind in AnalyzeCycler.allCases {
            let p = CatalogStatusUpdateQueue.plan([.integrity, kind])
            #expect(p.last == .integrity && p.contains(kind), "\(kind): \(p)")
        }
    }

    @Test("ORDER, through the queue: started in plan order; the check starts only after every other step has finished; one START and one OUTCOME line")
    func theQueueStartsTheCheckAfterEverythingElse() async {
        let queue = fastQueue()
        let runner = ScriptedUpdateRunner()
        for kind in [AnalyzeCycler.soundPrints, .duplicates, .correlate, .integrity] {
            runner.steps[kind] = { try? await Task.sleep(for: .milliseconds(30)) }
        }
        queue.enqueue([.soundPrints, .integrity, .duplicates, .correlate], runner: runner, source: "test")
        await drain(queue)
        #expect(!queue.isActive)
        #expect(runner.started == [.soundPrints, .duplicates, .correlate, .integrity])
        #expect(runner.runningAtStart[.integrity] == [], "the check began while \(runner.runningAtStart[.integrity] ?? []) still ran")
        let starts = runner.lines.filter { $0.contains("— START —") }
        let outcomes = runner.lines.filter { $0.contains("— OUTCOME —") }
        #expect(starts == ["Catalog status: update everything stale — START — 4 step(s), in order: Sound Prints, Detect Duplicates, Correlate A/V, Integrity; the catalog check runs once, last (test)"],
                Comment(rawValue: runner.lines.joined(separator: "\n")))
        #expect(outcomes == ["Catalog status: update everything stale — OUTCOME — started 4 step(s): Sound Prints, Detect Duplicates, Correlate A/V, Integrity; the catalog check ran last — its verdict is Catalog's colour"],
                Comment(rawValue: runner.lines.joined(separator: "\n")))
    }

    @Test("ORDER: a step added while the check runs puts the check after it again; asking for the check alone while it runs adds nothing")
    func addingDuringTheCheckRunsItAgainLast() async {
        let queue = fastQueue()
        let runner = ScriptedUpdateRunner()
        var added = false
        runner.steps[.integrity] = {
            if !added {
                added = true
                queue.enqueue([.integrity], runner: runner, source: "again")
                #expect(queue.pending.isEmpty, "the check in flight is not queued behind itself")
                queue.enqueue([.duplicates, .integrity], runner: runner, source: "again")
                #expect(queue.pending == [.duplicates, .integrity])
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        runner.steps[.duplicates] = { try? await Task.sleep(for: .milliseconds(20)) }
        queue.enqueue([.integrity], runner: runner, source: "test")
        await drain(queue)
        #expect(runner.started == [.integrity, .duplicates, .integrity])
    }

    @Test("ISOLATION: Stop clears what has not started — the OUTCOME says the check did not run; a refused step does not stall the queue")
    func clearedAndRefused() async {
        let queue = fastQueue()
        let runner = ScriptedUpdateRunner()
        runner.steps[.duplicates] = { try? await Task.sleep(for: .milliseconds(50)) }
        // .ocr has no closure: refused, never running — the queue moves on.
        queue.enqueue([.ocr, .duplicates], runner: runner, source: "test")
        queue.advanceIfIdle()
        #expect(queue.current == .duplicates)
        queue.clearPending()
        await drain(queue)
        #expect(runner.started == [.duplicates])
        #expect(runner.lines.last?.hasSuffix("the catalog check did not run (the steps left were cleared)") == true,
                Comment(rawValue: runner.lines.joined(separator: "\n")))
        let refused = fastQueue(), r2 = ScriptedUpdateRunner()
        r2.steps[.integrity] = {}
        refused.enqueue([.ocr], runner: r2, source: "test")
        await drain(refused)
        #expect(r2.started == [.ocr, .integrity])
    }
}

// MARK: - (c) Grey "Checking…" while an Update runs

@Suite("Update everything stale — Catalog reads Checking… (GH #441)", .serialized)
@MainActor
struct CatalogUpdateCheckingTests {

    static func lines(_ db: CatalogStatusLineState, _ files: CatalogStatusLineState, updating: Bool) -> CatalogStatusLines {
        CatalogStatusLines(database: CatalogStatusLine(kind: .database, state: db, words: "db \(db)"),
                           files: CatalogStatusLine(kind: .files, state: files, words: "files \(files)"),
                           content: CatalogStatusLine(kind: .content, state: .grey, words: "3 left to analyze"),
                           updating: updating)
    }

    @Test("LOGIC: while updating, every colour reads grey Checking… — the lead says to wait and repeats what the last check found; the menu title names nothing; when the Update ends the real colour is back")
    func everyColourWaits() {
        let all: [CatalogStatusLineState] = [.green, .yellow, .red, .grey]
        for db in all { for files in all {
            let c = Self.lines(db, files, updating: true).catalog
            #expect(c.state == .grey && c.words == "Checking…", "\(db)+\(files) → \(c.state) \(c.words)")
            #expect(c.why.first == CatalogStatusLines.updatingWhy)
            #expect(CatalogStatusLines.menuTitle(Self.lines(db, files, updating: true)) == "Catalog Status…")
            let after = Self.lines(db, files, updating: false).catalog
            #expect(after.words != "Checking…", "\(db)+\(files): \(after.words)")
        } }
        let red = Self.lines(.red, .green, updating: true).catalog
        #expect(red.why == [CatalogStatusLines.updatingWhy, "Before this Update — Database: db red"], "the truth so far is still said")
        #expect(Self.lines(.red, .green, updating: false).catalog.words == "Unhealthy")
    }

    @Test("LOGIC: the snapshot follows the queue — grey Checking… from the first enqueue until the queue drains, then the facts' own colour")
    func snapshotFollowsTheQueue() async {
        let snapshot = CatalogFreshnessSnapshot()
        var report = AnalyzeCoverageReport()
        report.computedAt = Date()
        let red = CatalogFreshnessFacts(integrity: IntegrityReportFacts(outcome: .failed))
        snapshot.publish(report: report, facts: red)
        #expect(CatalogStatusIndicators(snapshot.state).catalog.words == "Unhealthy")
        let queue = fastQueue()
        snapshot.observeUpdate(queue)
        let runner = ScriptedUpdateRunner()
        var during: [CatalogStatusIndicator] = []
        runner.steps[.duplicates] = {
            try? await Task.sleep(for: .milliseconds(20))
            during.append(CatalogStatusIndicators(snapshot.state).catalog)
        }
        runner.steps[.integrity] = {
            try? await Task.sleep(for: .milliseconds(20))
            during.append(CatalogStatusIndicators(snapshot.state).catalog)
            snapshot.publish(report: report, facts: red)           // an intermediate verdict
            during.append(CatalogStatusIndicators(snapshot.state).catalog)
        }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        await drain(queue)
        #expect(during.count == 3)
        #expect(during.allSatisfy { $0.state == .grey && $0.words == "Checking…" }, "\(during.map(\.words))")
        for _ in 0..<100 where snapshot.state.lines?.updating == true { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(CatalogStatusIndicators(snapshot.state).catalog.words == "Unhealthy", "the final verdict colours it")
    }
}

// MARK: - (a), (b) Truth: real engines through the real queue

/// A sandboxed catalog the REAL engines run over: Detect Duplicates
/// (`model.analyzeDuplicates`) and Validate Catalog (the file check, then the
/// tiers — the scene's own configured job). The snapshot hears the facts the
/// app reads (`CatalogFreshnessFactsReader`) after each step, and its
/// transition log is captured.
@MainActor
private struct UpdateScene {
    let scene: ValidateScene
    let snapshot = CatalogFreshnessSnapshot()
    let report: AnalyzeCoverageReport
    var model: VideoScanModel { scene.sandbox.model }
    var catalogFile: String { model.catalogStore.fileLocation }

    static func make(_ label: String) throws -> UpdateScene {
        let scene = try ValidateScene.make("update_\(label)", rows: 0)
        var report = AnalyzeCoverageReport()
        report.computedAt = Date()
        return UpdateScene(scene: scene, report: report)
    }

    func cleanup() { scene.cleanup() }

    func hear() {
        snapshot.publish(report: report, facts: CatalogFreshnessFactsReader.read(catalogFile: catalogFile))
    }

    /// Two copies the scan grouped on a sampled hash whose whole-file
    /// digests now differ (11/06: #434's re-hashing changed their digests and
    /// cleared their duplicate stamp) — stale, and Detect Duplicates heals it.
    func staleButHealableGroup() throws {
        let group = UUID()
        for (name, digest) in [("clipA.mov", 1), ("clipB2.mov", 2)] {
            let r = try scene.sandbox.live(name, bytes: 4_000)
            r.partialMD5 = "same-head-and-tail"
            r.durationSeconds = 60
            r.duration = Formatting.duration(60)
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.resolution = "1920x1080"
            r.videoCodec = "h264"
            r.audioCodec = "aac"
            r.audioChannels = "2"
            r.audioSampleRate = "48000 Hz"
            r.isPlayable = "Yes"
            r.contentFixity = ContentFixity(digest: String(format: "%064x", digest), byteCount: 4_000,
                                            stamp: FileIdentityStamp(device: 1, inode: UInt64(digest), size: 4_000, mtimeNs: 3),
                                            computedAt: Date())
            r.duplicateGroupID = group
            r.duplicateReasons = "hash+duration"
            r.duplicateDisposition = name == "clipA.mov" ? .keep : .extraCopy
            r.duplicateGroupCount = 2
            r.dupAnalyzedAt = nil
        }
    }

    /// A break no Update step repairs: two rows that supersede each other.
    func supersessionCircle() throws {
        let a = try scene.sandbox.live("circleA.mov", bytes: 3_000)
        let b = try scene.sandbox.live("circleB1.mov", bytes: 3_001)
        a.supersededByID = b.id
        b.supersededByID = a.id
    }

    /// The real Update: the real queue, the real engines as its steps.
    func runUpdate(_ kinds: [AnalyzeCycler]) async throws -> (runner: ScriptedUpdateRunner, log: [String], during: [CatalogStatusIndicator]) {
        guard model.saveCatalogNow() else { throw CocoaError(.fileWriteUnknown) }
        var log: [String] = []
        snapshot.note = { log.append($0) }
        hear()
        let queue = fastQueue()
        snapshot.observeUpdate(queue)
        let runner = ScriptedUpdateRunner()
        var during: [CatalogStatusIndicator] = []
        runner.steps[.duplicates] = { [model] in
            await model.analyzeDuplicates()
            _ = model.saveCatalogNow()          // the debounced save, landed
            self.hear()
            during.append(CatalogStatusIndicators(self.snapshot.state).catalog)
        }
        runner.steps[.integrity] = {
            _ = await self.scene.run()
            self.hear()
            during.append(CatalogStatusIndicators(self.snapshot.state).catalog)
        }
        queue.enqueue(kinds, runner: runner, source: "test")
        await drain(queue, seconds: 60)
        for _ in 0..<200 where snapshot.state.lines?.updating == true { try? await Task.sleep(for: .milliseconds(10)) }
        return (runner, log, during)
    }
}

@Suite("Update everything stale — truth through the real engines (GH #441)", .serialized)
@MainActor
struct CatalogUpdateTruthTests {

    @Test("RED 2026-11-06 (#441): an Update over stale-but-healable duplicate groups never logs a red transition and ends Synced")
    func healableGroupsNeverGoRed() async throws {
        let s = try UpdateScene.make("heal"); defer { s.cleanup() }
        try s.staleButHealableGroup()
        // Precondition: the catalog as it stood IS what the check calls a break.
        let before = CatalogConstraints.check(rows: s.model.records.map { IntegrityRow(record: $0) }, events: [])
            .filter { $0.rule.rawValue == "duplicateGroupDigestsAgree" }
        #expect(before.count == 1, "the fixture must hold one stale group")
        // The kinds as staleCyclers hands them over on 11/06: the check before Detect Duplicates.
        let run = try await s.runUpdate([.integrity, .duplicates])
        let all = run.log.joined(separator: "\n")
        #expect(run.runner.started.last == .integrity, "\(run.runner.started)")
        #expect(!run.log.contains { $0.contains("Unhealthy") }, Comment(rawValue: all))
        #expect(run.during.allSatisfy { $0.words == "Checking…" }, "\(run.during.map(\.words))")
        let end = CatalogStatusIndicators(s.snapshot.state).catalog
        #expect(end.state == .green && end.words == "Synced", Comment(rawValue: "\(end.words) — \(end.why) — log:\n\(all)"))
        #expect(s.model.records.allSatisfy { $0.duplicateGroupID == nil }, "different bytes are not copies")
    }

    @Test("TRUTH: an Update over a real structural break no step repairs still ends Unhealthy, naming the cause and the fix")
    func aRealBreakStillEndsRed() async throws {
        let s = try UpdateScene.make("break"); defer { s.cleanup() }
        try s.supersessionCircle()
        let run = try await s.runUpdate([.duplicates])
        #expect(run.runner.started == [.duplicates, .integrity], "the check runs last even when it was not stale")
        #expect(run.during.allSatisfy { $0.words == "Checking…" }, "\(run.during.map(\.words))")
        let state = s.snapshot.state
        let end = CatalogStatusIndicators(state).catalog
        let db = try #require(state.lines?.database)
        #expect(end.state == .red && end.words == "Unhealthy", Comment(rawValue: "\(end.words) — \(end.why)"))
        #expect(db.words.hasPrefix("Red: ") && db.words.contains("superseded in a circle"), Comment(rawValue: db.words))
        #expect((db.detail + [db.words]).contains { $0.contains("Fix: ") }, Comment(rawValue: db.detail.joined(separator: " | ")))
        #expect(end.why.contains { $0.hasPrefix("Database: Red: ") }, "the window says why")
        #expect(run.log.contains { $0.contains("Database:") && $0.contains("→ Unhealthy") }, Comment(rawValue: run.log.joined(separator: "\n")))
    }
}

// MARK: - Sensor

@Suite("Update everything stale — source sensors (GH #441)")
struct CatalogUpdateSensorTests {

    @Test("SENSOR: both Update buttons call the one queue; the model wires the snapshot to it; the queue orders by plan")
    func oneChainOneWiring() throws {
        let window = try SourceTree.appSource(named: "CatalogStatusWindow.swift")
        let panel = try SourceTree.appSource(named: "AnalyzePanelView.swift")
        #expect(window.contains("queue.enqueue(freshness.state.staleCyclers, runner: runner"))
        #expect(panel.contains("queue.enqueue(freshness.state.staleCyclers, runner: runner"))
        let model = try SourceTree.appSource(named: "VideoScanModel.swift")
        #expect(model.contains("catalogFreshness.observeUpdate(catalogStatusUpdateQueue)"))
        let queue = try SourceTree.appSource(named: "CatalogStatusUpdateQueue.swift")
        #expect(queue.contains("pending = Self.plan(pending + kinds.filter { $0 != current })"), "every enqueue is planned")
    }
}
