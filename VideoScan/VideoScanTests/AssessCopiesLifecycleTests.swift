import Testing
import Combine
import Foundation
@testable import VideoScan

// MARK: - Archive Helper (Assess Copies) session lifecycle (2026-08-20)
//
// Rick's live-reported lifecycle rules for Helper sessions in the MFO
// job list, pinned at the job-list model level:
//
//   1. A finished session is KEPT as a finished success (green check)
//      until Clear Finished.
//   2. A CANCELLED session disappears from the list completely and
//      immediately (vanishesWhenCancelled — assess-only opt-in).
//   3. Re-running the Helper on the same recording while an earlier
//      session is still listed REPLACES it — never a pile. "Same
//      recording" is family membership in either direction, so
//      re-running from a different copy of the family replaces too.
//   4. Clear Finished removes sessions PERMANENTLY — nothing re-adds
//      them (regression sensor: the 2026-08-20 report of jobs
//      reappearing was re-dispatch stacking, which rule 3 now prevents).
//
// Per the safety-critical testing policy: positive AND negative
// coverage (unrelated recordings still stack; ordinary verbs keep
// their cancelled "Stopped" rows).

// MARK: - Fakes / helpers

/// Minimal conformer for the negative vanish test — an ordinary verb
/// (default vanishesWhenCancelled == false) whose cancelled row must
/// linger. (Mirrors MediaFileOperationsTests' private fake; fakes are
/// file-private by convention, so each suite carries its own.)
@MainActor
private final class OrdinaryFakeJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind = .compare
    let title = "ordinary fake"
    var subtitle = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()
    var finishedAt: Date?
    @Published var settableState: MediaFileOperationState = .running
    var state: MediaFileOperationState { settableState }
    func cancel() {
        settableState = .cancelled
        finishedAt = Date()
    }
}

@MainActor
private func makeRecord(_ name: String, hash: String = "") -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = "/tmp/AssessLifecycleTests/\(name)"
    r.contentHash = hash
    return r
}

/// Build an Assess job directly (no model round-trip) — the same shape
/// startAssessCopies produces, for tests that only exercise list rules.
@MainActor
private func makeAssessJob(seed: VideoRecord,
                           family: [VideoRecord]? = nil) -> AssessCopiesJob {
    AssessCopiesJob(seed: seed, family: family ?? [seed], inputs: [])
}

/// Pump the main actor until `done()` or ~1 s — the Center's
/// vanish-on-cancel runs in a deferred main-actor Task.
@MainActor
private func settle(until done: () -> Bool) async {
    for _ in 0..<500 {
        if done() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func assessJobs(_ center: MediaFileOperationsCenter) -> [AssessCopiesJob] {
    center.jobs.compactMap { $0 as? AssessCopiesJob }
}

// MARK: - Lifecycle rules

@MainActor
@Suite("Archive Helper session lifecycle")
struct AssessCopiesLifecycleTests {

    // Rule 1 + 4: finished session stays (as a finished success) until
    // Clear Finished, and Clear Finished is permanent.
    @Test func finishedSessionStaysUntilClearFinishedAndStaysCleared() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let seed = makeRecord("Clip 01.dv", hash: "h-clip01")
        model.records = [seed]

        let job = center.startAssessCopies(seed: seed, model: model)
        await job.task?.value
        if case .finished = job.state {
            // green-check success row
        } else {
            Issue.record("expected .finished, got \(job.state)")
        }
        #expect(assessJobs(center).map(\.id) == [job.id])

        center.clearFinished()
        #expect(center.jobs.isEmpty)

        // Permanence sensor: nothing re-publishes or re-adds the cleared
        // session on later main-actor turns.
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(center.jobs.isEmpty)
    }

    // Rule 2: a cancelled session vanishes completely and immediately.
    @Test func cancelledSessionVanishesFromTheList() async {
        let center = MediaFileOperationsCenter()
        let job = makeAssessJob(seed: makeRecord("a.mov"))
        center.add(job)
        #expect(center.jobs.count == 1)

        job.cancel()
        #expect(job.state == .cancelled)
        await settle { center.jobs.isEmpty }
        #expect(center.jobs.isEmpty)
    }

    // Rule 2, via the header's Cancel All — and the negative half:
    // vanish-on-cancel is an ASSESS opt-in, ordinary verbs keep their
    // cancelled "Stopped" row for Clear Finished.
    @Test func cancelAllVanishesAssessButKeepsOrdinaryCancelledRows() async {
        let center = MediaFileOperationsCenter()
        let ordinary = OrdinaryFakeJob()
        let assess = makeAssessJob(seed: makeRecord("b.mov"))
        center.add(ordinary)
        center.add(assess)

        center.cancelAll()
        await settle { assessJobs(center).isEmpty }

        #expect(assessJobs(center).isEmpty)
        #expect(center.jobs.map(\.id) == [ordinary.id])
        #expect(ordinary.state == .cancelled)
    }

    // Rule 3: re-running on the SAME seed replaces the listed session.
    @Test func rerunOnSameSeedReplacesInsteadOfStacking() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let seed = makeRecord("Mark_Bday_Thanksgiving_1984.mkv", hash: "h-mark84")
        model.records = [seed]

        let first = center.startAssessCopies(seed: seed, model: model)
        await first.task?.value
        let second = center.startAssessCopies(seed: seed, model: model)
        await second.task?.value

        #expect(assessJobs(center).map(\.id) == [second.id])
        #expect(!center.jobs.contains { $0.id == first.id })
    }

    /// Rule 3, the live repro shape: seven rapid re-runs (the 2026-08-20
    /// log shows 7 "assess copies START" lines for one file) must leave
    /// exactly ONE listed session — the newest.
    @Test func repeatedRerunsNeverPile() async throws {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let seed = makeRecord("Mark_Bday_Thanksgiving_1984.mkv", hash: "h-mark84")
        model.records = [seed]

        var last: AssessCopiesJob?
        for _ in 0..<7 {
            let job = center.startAssessCopies(seed: seed, model: model)
            await job.task?.value
            last = job
        }
        let newest = try #require(last)
        #expect(assessJobs(center).map(\.id) == [newest.id])
        // No cancelled stragglers either — replaced rows are gone, not
        // parked (rule 2 corollary).
        #expect(center.jobs.count == 1)
    }

    // Rule 3, cross-copy: re-running from ANOTHER copy of the same
    // family (same content signature) replaces the earlier session.
    @Test func rerunFromAnotherFamilyCopyReplaces() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let original = makeRecord("Clip 01.dv", hash: "h-family")
        let balanced = makeRecord("Clip 01_balanced.mov", hash: "h-family")
        model.records = [original, balanced]

        let first = center.startAssessCopies(seed: original, model: model)
        await first.task?.value
        #expect(first.familyByID[balanced.id] != nil)   // family discovery sanity

        let second = center.startAssessCopies(seed: balanced, model: model)
        await second.task?.value

        #expect(assessJobs(center).map(\.id) == [second.id])
    }

    // Negative for rule 3: sessions about UNRELATED recordings coexist.
    @Test func unrelatedRecordingsKeepSeparateSessions() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let a = makeRecord("wedding.mov", hash: "h-wedding")
        let b = makeRecord("graduation.mov", hash: "h-graduation")
        model.records = [a, b]

        let jobA = center.startAssessCopies(seed: a, model: model)
        await jobA.task?.value
        let jobB = center.startAssessCopies(seed: b, model: model)
        await jobB.task?.value

        #expect(Set(assessJobs(center).map(\.id)) == [jobA.id, jobB.id])
    }

    // Rule 4 at scale: clearing a stack of finished sessions removes all
    // of them, and none return.
    @Test func clearFinishedSweepsAllFinishedSessionsPermanently() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let seeds = ["a.mov", "b.mov", "c.mov"].enumerated().map {
            makeRecord($1, hash: "h-\($0)")
        }
        model.records = seeds
        for seed in seeds {
            let job = center.startAssessCopies(seed: seed, model: model)
            await job.task?.value
        }
        #expect(assessJobs(center).count == 3)

        center.clearFinished()
        #expect(center.jobs.isEmpty)
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(center.jobs.isEmpty)
    }
}
