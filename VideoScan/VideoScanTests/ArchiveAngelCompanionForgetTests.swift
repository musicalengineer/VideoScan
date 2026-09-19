// ArchiveAngelCompanionForgetTests.swift
// codex #1572 (2026-09-19): reclaiming an unfinished row deleted its
// already-catalogued companions (Balance / Access copies are catalogued
// by their jobs the moment they finish) and left live workspace records
// pointing at missing files. ONE model entry point now retires those
// records wherever the Angel throws buffer files away.
//
// Dimensions: LOGIC (prefix rule, entry filter, idempotence, the ledger
// line) · ISOLATION (sandbox model + sandbox ledger, never the real
// catalog) · SENSOR (a record outside the batch is never touched; a row
// that failed with its folder intact keeps its records).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — catalogued companions go with their files (codex #1572)", .serialized)
@MainActor
struct ArchiveAngelCompanionForgetTests {

    private func makeModel(_ sb: MasterArchiveTestSupport.Sandbox) throws -> VideoScanModel {
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        return model
    }

    private func record(_ path: String, derivedFrom: UUID? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.sizeBytes = 1_000
        r.derivedFrom = derivedFrom
        r.workspaceActive = derivedFrom != nil
        return r
    }

    @Test("records under the batch folder are retired (purgedAt), with a copyDeleted line by the angel; outside records untouched; idempotent")
    func retiresCompanionsUnderTheBatch() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angelforget")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let batchDir = sb.root.appendingPathComponent("buffer/batch-2026-09-19T10-00-00").path
        let original = record("/Volumes/LaCie/Family/tape.mov")
        let rowA = UUID(), rowB = UUID()
        let access = record(batchDir + "/\(rowA.uuidString)/tape.vs.archive.mov", derivedFrom: original.id)
        let balanced = record(batchDir + "/\(rowA.uuidString)/tape_balanced.mov", derivedFrom: original.id)
        let otherRow = record(batchDir + "/\(rowB.uuidString)/other.vs.archive.mov", derivedFrom: original.id)
        let otherBatch = record(sb.root.appendingPathComponent("buffer/batch-2026-09-18T10-00-00/x/y.mov").path, derivedFrom: original.id)
        model.records.append(contentsOf: [original, access, balanced, otherRow, otherBatch])

        let n = model.forgetArchiveAngelCompanions(batchDir: batchDir, entryIDs: [rowA], reason: "skipped by you")
        #expect(n == 2)
        #expect(access.isPurged && balanced.isPurged)
        #expect(!otherRow.isPurged, "another row of the same batch keeps its companions")
        #expect(!otherBatch.isPurged && !original.isPurged)

        #expect(model.forgetArchiveAngelCompanions(batchDir: batchDir, entryIDs: [rowA], reason: "again") == 0, "idempotent")
        #expect(model.forgetArchiveAngelCompanions(batchDir: batchDir, reason: "whole batch") == 1, "the whole batch: the other row goes too")
        #expect(otherRow.isPurged && !otherBatch.isPurged)

        await model.mediaLedger.waitForPendingWrites()
        let lines = model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.by == .angel && $0.batchID == "batch-2026-09-19T10-00-00" })
        #expect(lines.first?.detail[MediaLedgerEvent.Detail.reason] == "skipped by you")
    }

    @Test("the batch dir is a prefix of whole path components: a sibling folder that merely starts with the same name is not the batch")
    func prefixIsAFolderNotAString() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angelforget2")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let batchDir = sb.root.appendingPathComponent("buffer/batch-1").path
        let lookalike = record(sb.root.appendingPathComponent("buffer/batch-10/row/x.mov").path)
        let inside = record(batchDir + "/row/x.mov")
        model.records.append(contentsOf: [lookalike, inside])
        #expect(model.forgetArchiveAngelCompanions(batchDir: batchDir, reason: "test") == 1)
        #expect(!lookalike.isPurged && inside.isPurged)
        #expect(model.forgetArchiveAngelCompanions(batchDir: "", reason: "test") == 0)
        #expect(model.forgetArchiveAngelCompanions(batchDir: "/", reason: "test") == 0, "never the whole disk")
    }

    @Test("after a settle: a discarded batch loses all its companions; in a kept batch only rows whose folder is GONE lose theirs (SENSOR: an earlier real failure keeps its records)")
    func settledBatchesRule() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angelforget3")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let keptDir = sb.root.appendingPathComponent("buffer/batch-kept").path
        let goneDir = sb.root.appendingPathComponent("buffer/batch-gone").path
        let reclaimed = UUID(), realFailure = UUID(), ready = UUID()
        func entry(_ id: UUID, _ status: ArchiveAngelPlan.EntryStatus) -> ArchiveAngelPlan.Entry {
            .init(id: id, sourcePath: "/v/\(id).mov", filename: "\(id).mov", sizeBytes: 1, durationSeconds: 3600,
                  score: 40, evidence: [], proposedName: "x.mov", proposedDate: nil, status: status)
        }
        var kept = ArchiveAngelPlan(batchDir: keptDir, requestedCount: 3, makeLossless: false,
                                    entries: [entry(reclaimed, .failed), entry(realFailure, .failed), entry(ready, .ready)])
        kept.status = .ready
        var gone = ArchiveAngelPlan(batchDir: goneDir, requestedCount: 1, makeLossless: false, entries: [entry(UUID(), .failed)])
        gone.status = .discarded
        let a = record(keptDir + "/\(reclaimed.uuidString)/a.mov"), b = record(keptDir + "/\(realFailure.uuidString)/b.mov")
        let c = record(keptDir + "/\(ready.uuidString)/c.mov"), d = record(goneDir + "/anything/d.mov")
        model.records.append(contentsOf: [a, b, c, d])
        // Only the reclaimed row's folder is gone; the real failure's folder still exists.
        let existing: Set<String> = [keptDir + "/\(realFailure.uuidString)", keptDir + "/\(ready.uuidString)"]
        let n = model.forgetArchiveAngelCompanions(settled: [kept, gone], fileExists: { existing.contains($0) })
        #expect(n == 2)
        #expect(a.isPurged && d.isPurged)
        #expect(!b.isPurged && !c.isPurged)
    }
}
