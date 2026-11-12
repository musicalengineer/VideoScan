// CatalogUpdateQueueSweepTests.swift — Codex sweep 2026-11-09 ("catalog
// check scheduling" pass, cycle #261), the three Update-queue findings:
//   F2  an Update started while a catalog check runs elsewhere (the 03:30
//       daily check, a menu item) ran its writer steps alongside the check;
//   F3  the check could start before the earlier steps' debounced catalog
//       save landed, so it judged the catalog from before them;
//   F5  a refused check was logged as "the catalog check ran last".
// Seam: ScriptedUpdateRunner (CatalogUpdateOrderTests.swift).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func sweepQueue() -> CatalogStatusUpdateQueue {
    let queue = CatalogStatusUpdateQueue()
    queue.graceSeconds = 0
    queue.pollMilliseconds = 10
    return queue
}

@MainActor
private func waitWhile(_ seconds: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite("Update everything stale — Codex sweep 11/09 (F2, F3, F5)", .serialized)
@MainActor
struct CatalogUpdateQueueSweepTests {

    @Test("RED F5: the check refused (another audit holds the engine) → OUTCOME never says it ran")
    func refusedCheckIsNotClaimed() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()          // no closure for .integrity: it refuses
        queue.enqueue([.integrity], runner: runner, source: "test")
        await waitWhile { queue.isActive }
        let outcome = runner.lines.last { $0.contains("OUTCOME") } ?? ""
        #expect(!outcome.contains("ran last"), Comment(rawValue: outcome))
        #expect(outcome.contains("did not run"), Comment(rawValue: outcome))
    }

    @Test("RED F2: while a catalog check started elsewhere runs, no Update step starts; when it ends, the Update runs")
    func waitsForACheckRunningElsewhere() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.integrity]
        runner.steps[.duplicates] = { }
        runner.steps[.integrity] = { }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        try? await Task.sleep(for: .milliseconds(150))   // fifteen polls
        #expect(runner.started.isEmpty, "started \(runner.started) while a check ran elsewhere")
        runner.runningElsewhere = []
        await waitWhile { queue.isActive }
        #expect(runner.started == [.duplicates, .integrity])
        #expect(runner.runningAtStart[.duplicates]?.contains(.integrity) != true)
    }

    @Test("RED F3: the catalog is flushed (acknowledged) after the earlier steps and before the check; a refused flush runs no check")
    func checkWaitsForTheSave() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.steps[.duplicates] = { }
        runner.steps[.integrity] = { }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        await waitWhile { queue.isActive }
        #expect(runner.started == [.duplicates, .integrity])
        #expect(runner.flushes == [1], "flush after duplicates, before the check: \(runner.flushes)")

        let refused = sweepQueue()
        let second = ScriptedUpdateRunner()
        second.flushAcknowledged = false
        second.steps[.duplicates] = { }
        second.steps[.integrity] = { }
        refused.enqueue([.duplicates], runner: second, source: "test")
        await waitWhile { refused.isActive }
        #expect(second.started == [.duplicates], "the check ran on an unsaved catalog: \(second.started)")
        let outcome = second.lines.last { $0.contains("OUTCOME") } ?? ""
        #expect(outcome.contains("did not run") && outcome.contains("could not be saved"), Comment(rawValue: outcome))
    }
}

// MARK: - Re-review (Codex sweep 11/09, cycle #267): F1 readers, F5 late refusal, N1, N2

@Suite("Update everything stale — Codex sweep 11/09 re-review (F5, N1, N2)", .serialized)
@MainActor
struct CatalogUpdateQueueSweepReReviewTests {

    @Test("RED F5: a check that starts, then refuses inside its own task, is never claimed as run")
    func lateRefusalIsNotClaimed() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.steps[.integrity] = { }
        runner.refusedLater = [.integrity]
        queue.enqueue([.integrity], runner: runner, source: "test")
        await waitWhile { queue.isActive }
        let outcome = runner.lines.last { $0.contains("OUTCOME") } ?? ""
        #expect(!outcome.contains("ran last") && outcome.contains("did not run"), Comment(rawValue: outcome))
    }

    @Test("RED F5: a re-added check that is refused is not covered by the earlier one that ran")
    func reAddedCheckRefusedIsSaid() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.steps[.duplicates] = { }                            // .ocr has no step: it refuses too
        runner.steps[.integrity] = { [unowned runner, unowned queue] in
            runner.steps[.integrity] = nil                         // the next start refuses
            queue.enqueue([.ocr], runner: runner, source: "added during the check")
        }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        await waitWhile { queue.isActive }
        #expect(runner.started.filter { $0 == .integrity }.count == 2, "\(runner.started)")
        let outcome = runner.lines.last { $0.contains("OUTCOME") } ?? ""
        #expect(!outcome.contains("ran last") && outcome.contains("did not run"), Comment(rawValue: outcome))
    }

    @Test("RED N1: a writer refused because it is ALREADY running holds the queue until it ends — the check never starts beside it")
    func busyWriterIsWaitedFor() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.duplicates]                  // started from the panel; the queue's start refuses
        runner.steps[.integrity] = { }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!runner.started.contains(.integrity), "the check started while Detect Duplicates still ran: \(runner.started)")
        runner.runningElsewhere = []
        await waitWhile { queue.isActive }
        #expect(runner.started.last == .integrity)
        #expect(runner.runningAtStart[.integrity]?.contains(.duplicates) != true)
    }

    @Test("RED N2: a refused step is named in the OUTCOME")
    func refusedStepIsNamed() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.steps[.integrity] = { }                            // .ocr has no step: refused
        queue.enqueue([.ocr], runner: runner, source: "test")
        await waitWhile { queue.isActive }
        let outcome = runner.lines.last { $0.contains("OUTCOME") } ?? ""
        #expect(outcome.contains("refused") && outcome.contains(AnalyzeCycler.ocr.title), Comment(rawValue: outcome))
    }
}

@Suite("Catalog Status — every reader of a check date: future-dated is no proof (Codex sweep 11/09 re-review F1)")
struct CatalogFutureEvidenceReadersTests {

    private static let now = Date()
    private static let hour: TimeInterval = 3_600

    private static func tier(_ n: Int, at date: Date) -> IntegrityTier {
        IntegrityTier(tier: n, name: VerifyCatalogTiers.name(n), verifiedAt: date, result: .ok, checked: 10, passed: 10, needsDecision: 0, summary: "ok")
    }

    @Test("RED: a report whose tier 0 is 04:00 and other tiers + completion are tomorrow claims tomorrow (future), not 04:00")
    func integrityFactsClaimTheFuture() {
        let id = UUID()
        let early = Self.now.addingTimeInterval(-Self.hour)
        let tomorrow = Self.now.addingTimeInterval(24 * Self.hour)
        var tiers = [Self.tier(0, at: early)] + [1, 3, 4, 5].map { Self.tier($0, at: tomorrow) }
        tiers = tiers.map { var t = $0; t.runID = t.tier == 0 ? nil : id; return t }
        let report = IntegrityReport(runID: id, startedAt: tomorrow.addingTimeInterval(-5), verifiedAt: tomorrow, outcome: .completed,
                                     catalogFile: "/x/catalog.json", rowsTotal: 10, rowsLive: 10, elapsedSeconds: 5,
                                     tiers: tiers, findings: [], findingsTotal: 0)
        let facts = IntegrityReportFacts.from(report: report, now: Self.now)
        let claimed = facts.lastCompleted ?? .distantPast
        #expect(CatalogRealityPolicy.age(of: claimed, now: Self.now) == .future, "claimed \(claimed)")
        #expect(CatalogStatusLinesPolicy.database(facts, now: Self.now, date: { _ in "D" }).state != .green)
    }

    @Test("RED: the band's one Validate outcome with one step dated tomorrow is future, not the older step's date")
    func builderValidationClaimsTheFuture() {
        let early = Self.now.addingTimeInterval(-Self.hour)
        let tomorrow = Self.now.addingTimeInterval(24 * Self.hour)
        let audit = CatalogAuditRunRecord(startedAt: early.addingTimeInterval(-60), finishedAt: early, outcome: .completed,
                                          partial: false, counts: ["planned": 10, "present": 10])
        let v = CatalogRealityFactsBuilder.validation(audit: audit, integrity: IntegrityReportFacts(lastCompleted: tomorrow, outcome: .ok),
                                                      switchedAt: nil, now: Self.now)
        let facts = CatalogRealityFacts(validation: v, rowsToCheck: 10, rowsNotChecked: 0)
        #expect(CatalogRealityPolicy.colour(facts, now: Self.now) != .green, "\(v)")
    }

    @Test("RED: Catalog Database Info never says 'completed … nothing to decide' for a report dated in the future")
    func databaseInfoQualifiesTheFuture() {
        let tomorrow = Self.now.addingTimeInterval(24 * Self.hour)
        let v = CatalogIntegrityVerdict(facts: IntegrityReportFacts(lastCompleted: tomorrow, outcome: .ok),
                                        startedAt: tomorrow, verifiedAt: tomorrow, outcome: .completed, missing: false)
        guard case .known(let words) = CatalogDatabaseInfoLines.validate(v, date: { _ in "D" }, now: Self.now) else {
            Issue.record("expected known words"); return
        }
        #expect(words.contains("dated in the future"), Comment(rawValue: words))
    }
}

// MARK: - Closing pass (Codex sweep 11/09, cycle #271): C2, C3, C4, C5

@Suite("Catalog Status — Codex sweep 11/09 closing pass (C2–C5)", .serialized)
@MainActor
struct CatalogSweepClosingTests {

    @Test("RED C2: Database Info qualifies a report whose facts claim a future date even when its completion is older")
    func databaseInfoReadsTheFacts() {
        let now = Date()
        let v = CatalogIntegrityVerdict(facts: IntegrityReportFacts(lastCompleted: now.addingTimeInterval(86_400), outcome: .ok),
                                        startedAt: now.addingTimeInterval(-3_700), verifiedAt: now.addingTimeInterval(-3_600),
                                        outcome: .completed, missing: false)
        guard case .known(let words) = CatalogDatabaseInfoLines.validate(v, date: { _ in "D" }, now: now) else {
            Issue.record("expected known words"); return
        }
        #expect(words.contains("dated in the future"), Comment(rawValue: words))
    }

    @Test("RED C3: no evidence that the started Validate ran is not proof that it ran (fail closed)")
    func missingEvidenceFailsClosed() {
        let runner = AnalyzeRunner(model: VideoScanModel(), orchestrator: nil, center: nil)
        #expect(runner.stepRan(.integrity) == false)
        #expect(runner.stepRan(.duplicates) == true, "other steps carry no such evidence; their own OUTCOME lines speak")
    }

    @Test("RED C4: a writer already running elsewhere holds the check even when the Update did not ask for that writer")
    func checkWaitsForAnyRunningWriter() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.duplicates]
        runner.steps[.integrity] = { }
        queue.enqueue([.integrity], runner: runner, source: "test")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!runner.started.contains(.integrity), "the check started beside a running Detect Duplicates: \(runner.started)")
        runner.runningElsewhere = []
        await waitWhile { queue.isActive }
        #expect(runner.started == [.integrity])
    }

    @Test("RED C5: after waiting for a writer that ran elsewhere, its save is flushed (acknowledged) before the check")
    func waitedWriterIsFlushedToo() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.duplicates]
        runner.flushAcknowledged = false
        runner.steps[.integrity] = { }
        queue.enqueue([.duplicates], runner: runner, source: "test")
        try? await Task.sleep(for: .milliseconds(100))
        runner.runningElsewhere = []
        await waitWhile { queue.isActive }
        #expect(!runner.started.contains(.integrity), "the check ran without the writer's save acknowledged: \(runner.started)")
        #expect(!runner.flushes.isEmpty)
    }
}

@Suite("Catalog Status — the waiting lines are said once (closing pass C4)", .serialized)
@MainActor
struct CatalogSweepWaitLineTests {
    @Test("waiting for a running writer is logged once, not once per poll")
    func waitLineOnce() async {
        let queue = sweepQueue()
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.duplicates]
        runner.steps[.integrity] = { }
        queue.enqueue([.integrity], runner: runner, source: "test")
        try? await Task.sleep(for: .milliseconds(200))           // ~20 polls
        #expect(runner.lines.filter { $0.contains("waiting:") }.count == 1, "\(runner.lines)")
        runner.runningElsewhere = []
        await waitWhile { queue.isActive }
    }
}

@Suite("Catalog Status — Codex sweep 11/09 final pass (#272 #5)", .serialized)
@MainActor
struct CatalogSweepFinalTests {
    @Test("RED: after waiting behind an audit (and a writer) that both ended before the next poll, the save is flushed before the check")
    func waitingBehindAnAuditFlushes() {
        let queue = CatalogStatusUpdateQueue()
        queue.graceSeconds = 0
        let runner = ScriptedUpdateRunner()
        runner.runningElsewhere = [.filePresence, .duplicates]
        runner.flushAcknowledged = false
        runner.steps[.integrity] = { }
        queue.enqueue([.integrity], runner: runner, source: "test")
        queue.advanceIfIdle()
        runner.runningElsewhere = []
        queue.advanceIfIdle()
        #expect(!runner.flushes.isEmpty, "no flush was asked")
        #expect(!runner.started.contains(.integrity), "the check ran without the writers' save acknowledged: \(runner.started)")
    }
}
