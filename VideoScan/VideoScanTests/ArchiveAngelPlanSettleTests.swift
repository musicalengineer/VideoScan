// ArchiveAngelPlanSettleTests.swift
// GH #177: cancelled or interrupted Angel batches settle instead of
// lingering as `preparing` ghosts — invisible to the Archive tab yet
// reserving their rows from later batches. Temp dirs only.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — settling interrupted batches (GH #177)")
struct ArchiveAngelPlanSettleTests {
    private func entry(_ status: ArchiveAngelPlan.EntryStatus) -> ArchiveAngelPlan.Entry {
        .init(id: UUID(), sourcePath: "/v/x.mov", filename: "x.mov", sizeBytes: 1, durationSeconds: 120,
              score: 1, evidence: [], proposedName: "x.mov", proposedDate: nil, status: status)
    }
    private func plan(_ dir: URL, name: String, status: ArchiveAngelPlan.Status, rows: [ArchiveAngelPlan.EntryStatus]) throws -> ArchiveAngelPlan {
        var p = ArchiveAngelPlan(batchDir: dir.appendingPathComponent(name).path, requestedCount: 10,
                                 makeLossless: false, entries: rows.map(entry))
        p.status = status
        try ArchiveAngelPlanStore.save(p)
        return p
    }
    private func age(_ p: ArchiveAngelPlan, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: p.planURL.path)
    }

    @Test("settle: never-prepared rows fail with the reason; prepared rows keep the batch as ready; nothing prepared → discarded")
    func settleRule() {
        var some = ArchiveAngelPlan(batchDir: "/tmp/x", requestedCount: 10, makeLossless: false,
                                    entries: [entry(.ready), entry(.pending), entry(.preparing), entry(.promoted)])
        some.status = .preparing
        let keptSome = some.settleAfterInterruption(reason: "Cancelled")
        #expect(keptSome)
        #expect(some.status == .ready)
        #expect(some.entries.map(\.status) == [.ready, .failed, .failed, .promoted])
        #expect(some.entries[1].failure == "Cancelled")
        var none = ArchiveAngelPlan(batchDir: "/tmp/y", requestedCount: 10, makeLossless: false,
                                    entries: [entry(.pending), entry(.preparing)])
        none.status = .preparing
        let keptNone = none.settleAfterInterruption(reason: "Cancelled")
        #expect(!keptNone)
        #expect(none.status == .discarded)
        #expect(none.log.last?.contains("nothing was prepared") == true)
    }

    @Test("on disk: a stale preparing batch with ready rows becomes ready; a stale empty one is removed; a live one is untouched")
    func settleInterruptedOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_settle_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stuck = try plan(root, name: "batch-stuck", status: .preparing, rows: [.ready, .ready, .pending, .preparing])
        try age(stuck, by: 2 * 3600)
        let empty = try plan(root, name: "batch-empty", status: .preparing, rows: [.pending, .preparing])
        try age(empty, by: 2 * 3600)
        let live = try plan(root, name: "batch-live", status: .preparing, rows: [.ready, .pending])
        let ready = try plan(root, name: "batch-ready", status: .ready, rows: [.ready])

        // Before settling, the ghost rows are reserved unless the batch is stale.
        let before = ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root)
        #expect(before.contains(live.entries[1].id), "a live job's pending row is reserved")
        #expect(!before.contains(stuck.entries[2].id), "a stale batch's pending row is NOT reserved")
        #expect(before.contains(ready.entries[0].id))

        let settled = ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root)
        #expect(settled.count == 2)
        let after = ArchiveAngelPlanStore.listBatches(bufferRoot: root)
        let names = Dictionary(uniqueKeysWithValues: after.map { (($0.batchDir as NSString).lastPathComponent, $0) })
        #expect(names["batch-stuck"]?.status == .ready)
        #expect(names["batch-stuck"]?.readyCount == 2)
        #expect(names["batch-stuck"]?.entries.filter { $0.status == .failed }.count == 2)
        #expect(names["batch-empty"] == nil, "removed from disk")
        #expect(names["batch-live"]?.status == .preparing, "a live job is never touched")
        #expect(names["batch-ready"]?.status == .ready)
        // Idempotent.
        #expect(ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root).isEmpty)
        // Reserved rows now: the two ready rows of the settled batch, the live batch's rows, the ready batch's row.
        let now = ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root)
        #expect(now.contains(stuck.entries[0].id) && now.contains(stuck.entries[1].id))
        #expect(!now.contains(stuck.entries[2].id) && !now.contains(stuck.entries[3].id))
    }
}
