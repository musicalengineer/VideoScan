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

    // MARK: GH #288 — recovery's "landed" rule (N1016-F1/F2)

    /// An archive copy record promoted from `source` (the promote link
    /// `masterArchiveCopy(of:)` follows), its file inside the archive.
    @MainActor
    private func archiveCopy(of source: VideoRecord?, at url: URL, contentHash: String = "",
                             seed: UInt64) throws -> VideoRecord {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MasterArchiveTestSupport.writeBlob(at: url, bytes: 2048, seed: seed)
        let r = MasterArchiveTestSupport.makeRecord(path: url.path)
        r.derivedFrom = source?.id
        r.derivationKind = ArchivePromotion.derivationKind
        r.contentHash = contentHash
        return r
    }

    /// A row left `.promoting` by a quit, with its buffer folder on disk.
    private func strandedPlan(_ entries: [ArchiveAngelPlan.Entry], bufferRoot: URL, name: String) throws -> ArchiveAngelPlan {
        var p = ArchiveAngelPlan(batchDir: bufferRoot.appendingPathComponent(name).path, requestedCount: entries.count,
                                 makeLossless: false, entries: entries)
        p.status = .promoting
        try ArchiveAngelPlanStore.save(p)
        for e in entries {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: p.batchDir).appendingPathComponent(e.id.uuidString), withIntermediateDirectories: true)
        }
        return p
    }

    /// N1016-F1: recovery checked only the ORIGINAL, then deleted the row's
    /// buffer folder — taking an access copy that never reached the archive
    /// with it. Recovery now asks the same per-companion question as the
    /// normal settle. Twin: when the companion DID land, the folder goes.
    @Test @MainActor func aStrandedRowWhoseCompanionDidNotLandKeepsItsBuffer() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_stranded_companion"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let archive = URL(fileURLWithPath: try #require(model.masterArchiveRootPath))
        let bufferRoot = sb.root.appendingPathComponent("buffer", isDirectory: true)

        // Two originals, both landed (inside the archive). A's access copy
        // did not land; B's did (it has its own archive copy).
        let recA = try archiveCopy(of: nil, at: archive.appendingPathComponent("2009/2009_a.mov"), seed: 1)
        let recB = try archiveCopy(of: nil, at: archive.appendingPathComponent("2009/2009_b.mov"), seed: 2)
        recA.derivationKind = nil; recB.derivationKind = nil   // plain files of the archive
        var a = entry(.ready, id: recA.id), b = entry(.ready, id: recB.id)
        var p = try strandedPlan([a, b], bufferRoot: bufferRoot, name: "batch-c")
        func companion(for e: ArchiveAngelPlan.Entry, seed: UInt64) throws -> (VideoRecord, ArchiveAngelPlan.StepOutcome) {
            let rel = "\(e.id.uuidString)/x_access.mp4"
            let url = try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: p.batchDir).appendingPathComponent(rel),
                                                             bytes: 1024, seed: seed)
            let rec = MasterArchiveTestSupport.makeRecord(path: url.path)
            return (rec, .init(kind: .accessCopy, state: .done, outputRelPath: rel, recordID: rec.id))
        }
        let (compA, stepA) = try companion(for: a, seed: 3)
        let (compB, stepB) = try companion(for: b, seed: 4)
        a.steps = [stepA]; b.steps = [stepB]
        p.entries = [a, b]
        try ArchiveAngelPlanStore.save(p)
        let compBCopy = try archiveCopy(of: compB, at: archive.appendingPathComponent("2009/2009_b_access.mp4"), seed: 5)
        model.records = [recA, recB, compA, compB, compBCopy]
        #expect(model.masterArchiveCopy(of: compA) == nil && model.masterArchiveCopy(of: compB) != nil, "fixture")

        let lines = ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model)
        #expect(lines.last?.contains("1 archived, 1 back to ready") == true, "\(lines)")
        let after = try ArchiveAngelPlanStore.load(batchDir: p.batchDir)
        let byID = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.id, $0) })
        #expect(byID[a.id]?.status == .ready, "a row whose access copy never landed is not promoted")
        #expect(byID[a.id]?.failure?.contains("Access copy") == true, "\(String(describing: byID[a.id]?.failure))")
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: p.batchDir).appendingPathComponent(stepA.outputRelPath ?? "").path),
                "the un-landed access copy is kept in the buffer")
        #expect(byID[b.id]?.status == .promoted, "every companion landed: promoted")
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: p.batchDir).appendingPathComponent(b.id.uuidString).path),
                "the fully landed row's buffer is reclaimed")
    }

    /// N1016-F2: recovery decided "landed" with the display-only
    /// `isArchived`, whose content-hash fallback says yes when IDENTICAL
    /// bytes reached the archive from ANOTHER batch. This row's own promote
    /// never landed: it must go back to ready, keep its buffer, and have
    /// the facts Promote stamped on it undone.
    @Test @MainActor func identicalBytesFromAnotherBatchAreNotThisRowLanding() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_stranded_twin"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let archive = URL(fileURLWithPath: try #require(model.masterArchiveRootPath))
        let bufferRoot = sb.root.appendingPathComponent("buffer", isDirectory: true)

        let other = MasterArchiveTestSupport.makeRecord(
            path: try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("other.mov"), bytes: 2048, seed: 7).path)
        other.contentHash = "h:twin"
        let x2 = MasterArchiveTestSupport.makeRecord(
            path: try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("x2.mov"), bytes: 2048, seed: 7).path,
            userDate: "1994")
        x2.contentHash = "h:twin"
        x2.userDateConfidence = UserDateConfidence.known.rawValue
        let otherCopy = try archiveCopy(of: other, at: archive.appendingPathComponent("1994/1994_other.mov"),
                                        contentHash: "h:twin", seed: 7)
        model.records = [other, x2, otherCopy]
        #expect(model.isArchived(x2), "fixture: the display rule calls x2 archived by content")
        #expect(model.masterArchiveCopy(of: x2) == nil, "fixture: x2's own promote never landed")

        var e = entry(.ready, id: x2.id)
        e.stampedFacts = [.init(recordID: x2.id, field: .date, previousValue: nil, previousConfidence: nil,
                                writtenValue: "1994", writtenConfidence: UserDateConfidence.known.rawValue)]
        let p = try strandedPlan([e], bufferRoot: bufferRoot, name: "batch-t")

        let lines = ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model)
        #expect(lines.last?.contains("0 archived, 1 back to ready") == true, "\(lines)")
        let after = try ArchiveAngelPlanStore.load(batchDir: p.batchDir)
        #expect(after.entries.first?.status == .ready)
        #expect(after.entries.first?.failure?.contains("interrupted") == true)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: p.batchDir).appendingPathComponent(x2.id.uuidString).path),
                "the buffer is kept for a retry")
        #expect(x2.userDate == nil && x2.userDateConfidence == nil, "the inherited date is undone")
    }
}
