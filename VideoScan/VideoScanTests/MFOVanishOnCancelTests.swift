// MFOVanishOnCancelTests.swift
// The Center's vanish-on-cancel rule (Rick 2026-08-20, first asked for the
// Archive Helper's sessions): a job that opts in via `vanishesWhenCancelled`
// leaves the list the moment its `.cancelled` state lands; ordinary verbs
// keep their "Stopped" row for Clear Finished.
//
// Ported from AssessCopiesLifecycleTests (rule 2) when Archive Angel S4
// retired the Assess Copies job — the rule is generic Center behaviour
// (PruneApplyJob opts in for rows dropped while queued), so it keeps its
// own positive AND negative sensor with a fake opt-in job.

import Combine
import Foundation
import Testing
@testable import VideoScan

@MainActor
private final class FakeMFOJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind = .compare
    let title: String
    var subtitle = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()
    var finishedAt: Date?
    let vanishesWhenCancelled: Bool
    @Published var settableState: MediaFileOperationState = .running
    var state: MediaFileOperationState { settableState }

    init(title: String, vanishes: Bool) {
        self.title = title
        self.vanishesWhenCancelled = vanishes
    }

    func cancel() {
        settableState = .cancelled
        finishedAt = Date()
    }
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
@Suite("MFO — vanish on cancel (opt-in)")
struct MFOVanishOnCancelTests {

    @Test func aCancelledOptInJobVanishesFromTheList() async {
        let center = MediaFileOperationsCenter()
        let job = FakeMFOJob(title: "opt-in", vanishes: true)
        center.add(job)
        #expect(center.jobs.count == 1)
        job.cancel()
        #expect(job.state == .cancelled)
        await settle { center.jobs.isEmpty }
        #expect(center.jobs.isEmpty)
    }

    @Test func cancelAllVanishesOptInJobsButKeepsOrdinaryCancelledRows() async {
        let center = MediaFileOperationsCenter()
        let ordinary = FakeMFOJob(title: "ordinary", vanishes: false)
        let optIn = FakeMFOJob(title: "opt-in", vanishes: true)
        center.add(ordinary)
        center.add(optIn)
        center.cancelAll()
        await settle { !center.jobs.contains { $0.id == optIn.id } }
        #expect(center.jobs.map(\.id) == [ordinary.id], "the ordinary verb keeps its Stopped row")
        #expect(ordinary.state == .cancelled)
    }
}
