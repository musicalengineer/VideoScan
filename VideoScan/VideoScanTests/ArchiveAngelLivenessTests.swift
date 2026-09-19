// ArchiveAngelLivenessTests.swift
// Audit #3/#4 (2026-09-19): "is this batch alive?" used to mean "plan.json
// rewritten within the hour". A 14-hour lossless verify rewrites nothing,
// so the Archive tab could settle and delete a batch ffmpeg was still
// working in; and a promote left `.promoting` by a quit had no liveness at
// all — hidden forever, its rows reserved, its buffer kept.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — liveness: running batches are never settled; stranded promotes are")
struct ArchiveAngelLivenessTests {
    private func entry(_ status: ArchiveAngelPlan.EntryStatus, id: UUID = UUID()) -> ArchiveAngelPlan.Entry {
        .init(id: id, sourcePath: "/v/x.mov", filename: "x.mov", sizeBytes: 1, durationSeconds: 120,
              score: 1, evidence: [], proposedName: "x.mov", proposedDate: nil, status: status)
    }

    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func aged(_ plan: ArchiveAngelPlan, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: plan.planURL.path)
    }

    @Test func aLongStepInARunningBatchIsNeverSettledOrDeleted() throws {
        let root = tempRoot("longstep"); defer { try? FileManager.default.removeItem(at: root) }
        var p = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-long").path, requestedCount: 2,
                                 makeLossless: true, entries: [entry(.preparing), entry(.pending)])
        p.status = .preparing
        try ArchiveAngelPlanStore.save(p)
        try aged(p, hours: 3)   // last step boundary 3 h ago: a long FFV1 verify, reading only

        ArchiveAngelLiveBatches.begin(p.batchDir)
        #expect(!ArchiveAngelPlanStore.isInterrupted(p))
        #expect(ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root).isEmpty, "a live batch was settled")
        #expect(FileManager.default.fileExists(atPath: p.batchDir), "a live batch's folder was deleted")
        #expect(ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root) == Set(p.entries.map(\.id)),
                "its rows stay reserved while it runs")
        ArchiveAngelLiveBatches.end(p.batchDir)

        // Once nothing is running it (a quit), the hour rule applies again.
        #expect(ArchiveAngelPlanStore.isInterrupted(p))
        #expect(ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root).count == 1)
    }

    @Test func liveRegistrationIsCountedAndPathNormalized() {
        let dir = "/tmp/test_angel_reg_\(UUID().uuidString)/batch-a"
        ArchiveAngelLiveBatches.begin(dir)
        ArchiveAngelLiveBatches.begin(dir + "/")          // a prepare and a promote of one folder
        #expect(ArchiveAngelLiveBatches.isLive(dir))
        ArchiveAngelLiveBatches.end(dir)
        #expect(ArchiveAngelLiveBatches.isLive(dir), "one of two still running")
        ArchiveAngelLiveBatches.end(dir)
        #expect(!ArchiveAngelLiveBatches.isLive(dir))
        ArchiveAngelLiveBatches.end(dir)                  // extra end is harmless
        #expect(!ArchiveAngelLiveBatches.isLive(dir))
    }

    /// A quit mid-promote: record A reached the archive (the Promote job
    /// writes the catalog), record B did not.
    @Test @MainActor func aStrandedPromoteIsSettledAgainstTheCatalog() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_stranded"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let archiveRoot = try #require(model.masterArchiveRootPath)
        let inArchive = URL(fileURLWithPath: archiveRoot).appendingPathComponent("2009/2009_a.mov")
        try FileManager.default.createDirectory(at: inArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: inArchive, bytes: 2048, seed: 1)
        let outside = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("b.mov"), bytes: 2048, seed: 2)
        let recA = MasterArchiveTestSupport.makeRecord(path: inArchive.path)
        let recB = MasterArchiveTestSupport.makeRecord(path: outside.path)
        model.records = [recA, recB]
        #expect(model.isArchived(recA) && !model.isArchived(recB), "fixture")

        let bufferRoot = sb.root.appendingPathComponent("buffer", isDirectory: true)
        var p = ArchiveAngelPlan(batchDir: bufferRoot.appendingPathComponent("batch-p").path, requestedCount: 2,
                                 makeLossless: false, entries: [entry(.ready, id: recA.id), entry(.ready, id: recB.id)])
        p.status = .promoting
        try ArchiveAngelPlanStore.save(p)
        for e in p.entries {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: p.batchDir).appendingPathComponent(e.id.uuidString), withIntermediateDirectories: true)
        }

        // While a promote of it runs in this app, nothing is touched.
        ArchiveAngelLiveBatches.begin(p.batchDir)
        #expect(ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model).isEmpty)
        ArchiveAngelLiveBatches.end(p.batchDir)

        let lines = ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model)
        #expect(lines.count == 1 && lines[0].contains("1 archived, 1 back to ready"), "\(lines)")
        let after = try ArchiveAngelPlanStore.load(batchDir: p.batchDir)
        let byID = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.id, $0) })
        #expect(after.status == .ready, "listed in the Archive tab again, not hidden as promoting")
        #expect(byID[recA.id]?.status == .promoted)
        #expect(byID[recB.id]?.status == .ready)
        #expect(byID[recB.id]?.failure?.contains("interrupted") == true)
        let dirA = URL(fileURLWithPath: p.batchDir).appendingPathComponent(recA.id.uuidString).path
        let dirB = URL(fileURLWithPath: p.batchDir).appendingPathComponent(recB.id.uuidString).path
        #expect(!FileManager.default.fileExists(atPath: dirA), "the archived row's buffer is reclaimed")
        #expect(FileManager.default.fileExists(atPath: dirB), "the unarchived row keeps its buffer for a retry")
        // Idempotent: nothing left promoting.
        #expect(ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model).isEmpty)
    }
}
