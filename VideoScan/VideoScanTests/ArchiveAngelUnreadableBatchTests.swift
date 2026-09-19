// ArchiveAngelUnreadableBatchTests.swift
// Audit #7 (Rick 2026-09-19, option a): a batch whose plan.json can't be
// read used to vanish from every list silently — its gigabytes kept, its
// reservations dropped, never settled. It is now listed, with a reason and
// a size, logged once, and never touched.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — an unreadable batch is listed and left alone")
struct ArchiveAngelUnreadableBatchTests {
    @Test func unreadableBatchesAreListedWithReasonAndSizeAndLoggedOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_unreadable_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // A good batch.
        var good = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-2026-09-19T10-00-00").path,
                                    requestedCount: 1, makeLossless: false, entries: [])
        good.status = .ready
        try ArchiveAngelPlanStore.save(good)
        // A damaged plan.json, with 5,000 bytes of companions beside it.
        let damaged = root.appendingPathComponent("batch-2026-09-19T11-00-00")
        try fm.createDirectory(at: damaged.appendingPathComponent("entry"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: damaged.appendingPathComponent(ArchiveAngelPlan.planFilename))
        try Data(count: 5_000).write(to: damaged.appendingPathComponent("entry/x.vs.archive.mov"))
        // A folder a crash left with no plan.json at all.
        let empty = root.appendingPathComponent("batch-2026-09-19T12-00-00")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)

        var lines: [String] = []
        let scan = ArchiveAngelPlanStore.scanBatches(bufferRoot: root, log: { lines.append($0) })
        #expect(scan.plans.map(\.batchDir) == [good.batchDir])
        #expect(scan.unreadable.map { ($0.batchDir as NSString).lastPathComponent }
                == ["batch-2026-09-19T11-00-00", "batch-2026-09-19T12-00-00"])
        #expect(scan.unreadable[0].reason.hasPrefix("its plan.json can't be read"), "\(scan.unreadable[0].reason)")
        #expect(scan.unreadable[0].sizeBytes >= 5_000)
        #expect(scan.unreadable[1].reason == "it has no plan.json")
        #expect(lines.count == 2 && lines.allSatisfy { $0.contains("left in place, not settled or deleted") }, "\(lines)")

        // Logged once per session, not on every refresh.
        _ = ArchiveAngelPlanStore.scanBatches(bufferRoot: root, log: { lines.append($0) })
        #expect(lines.count == 2)
        // Never settled or deleted.
        _ = ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root)
        #expect(fm.fileExists(atPath: damaged.path) && fm.fileExists(atPath: empty.path))
    }

    @Test func theRowSaysHowManyAndHowBig() {
        let one = [ArchiveAngelPlanStore.UnreadableBatch(batchDir: "/b/batch-1", reason: "r", sizeBytes: 12_400_000_000)]
        #expect(ArchiveAngelUnreadableRow.title(one).hasPrefix("1 Angel batch can't be read (12.4 GB)"))
        let two = one + [ArchiveAngelPlanStore.UnreadableBatch(batchDir: "/b/batch-2", reason: "r", sizeBytes: 0)]
        #expect(ArchiveAngelUnreadableRow.title(two).hasPrefix("2 Angel batches can't be read"))
    }
}
