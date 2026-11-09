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
