// ArchiveAngelBufferReconcileTests.swift
// Launch-time reconciliation of the Angel buffer (2026-09-21): batches
// cleared BEFORE the companion-retirement fix (codex #1572) left live
// records for files that no longer exist — 8 of the 13 "not connected"
// rows in Rick's "Archived — what next?" sheet. Once per launch, every
// active record under the buffer root whose batch folder (or row folder)
// is gone is retired through `forgetArchiveAngelCompanions`, per batch,
// with a launch reason. A record whose folders still exist is never
// touched — whatever its file says.
//
// Dimensions: LOGIC (the pure folder parse; gone batch, gone row, live
// row) · ISOLATION (sandbox buffer root + sandbox ledger, never Rick's
// ~/Movies buffer) · SENSOR (a live companion and a record outside the
// buffer are untouched; a folder present with a missing file is left to
// the job's own reconciliation; idempotent).

import Foundation
import os
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — launch reconciliation of orphaned buffer companions", .serialized)
@MainActor
struct ArchiveAngelBufferReconcileTests {

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
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = 1_000
        r.derivedFrom = derivedFrom
        r.workspaceActive = derivedFrom != nil
        return r
    }

    @Test("the pure parse: <root>/batch-…/<uuid>/file → (batch, row); a non-batch child or a path outside the root is nil")
    func folderParse() {
        let root = URL(fileURLWithPath: "/tmp/buf")
        let row = UUID()
        let hit = VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buf/batch-2026-09-10T10-00-00/\(row.uuidString)/x.mov", bufferRoot: root)
        #expect(hit?.batchDir == "/tmp/buf/batch-2026-09-10T10-00-00")
        #expect(hit?.entryDir == "/tmp/buf/batch-2026-09-10T10-00-00/\(row.uuidString)")
        let flat = VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buf/batch-1/x.mov", bufferRoot: root)
        #expect(flat?.batchDir == "/tmp/buf/batch-1" && flat?.entryDir == nil)
        let notUUID = VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buf/batch-1/sub/x.mov", bufferRoot: root)
        #expect(notUUID?.batchDir == "/tmp/buf/batch-1" && notUUID?.entryDir == nil)
        #expect(VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buf/plans/x.mov", bufferRoot: root) == nil)
        #expect(VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buffer/batch-1/x.mov", bufferRoot: root) == nil, "a sibling that merely starts with the root's name")
        #expect(VideoScanModel.archiveAngelBufferFolders(of: "/Volumes/LaCie/Family/x.mov", bufferRoot: root) == nil)
        #expect(VideoScanModel.archiveAngelBufferFolders(of: "/tmp/buf/batch-1", bufferRoot: root) == nil, "the folder itself is not a companion")
    }

    @Test("a gone batch folder retires its companions; a gone row folder retires that row's; a live row and a record outside the buffer are untouched; a present folder with a missing file is left alone; idempotent; ledger lines by the angel with the launch reason")
    func reconcilesOrphansOnly() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angellaunch")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let fm = FileManager.default
        let root = sb.root.appendingPathComponent("buffer", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let original = record("/Volumes/LaCie/Family/tape.mov")

        // Batch A: folder GONE (cleared before the fix) — two companions.
        let aDir = root.appendingPathComponent("batch-2026-09-10T10-00-00").path
        let aRow = UUID()
        let a1 = record(aDir + "/\(aRow.uuidString)/tape.vs.archive.mov", derivedFrom: original.id)
        let a2 = record(aDir + "/\(aRow.uuidString)/tape_balanced.mov", derivedFrom: original.id)

        // Batch B: folder present. Row b1 present with its file (live);
        // row b2 folder GONE; row b3 folder present, FILE gone (a job's
        // business, not launch's).
        let bDir = root.appendingPathComponent("batch-2026-09-19T12-49-52").path
        let b1Row = UUID(), b2Row = UUID(), b3Row = UUID()
        try fm.createDirectory(atPath: bDir + "/\(b1Row.uuidString)", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: bDir + "/\(b3Row.uuidString)", withIntermediateDirectories: true)
        let b1Path = bDir + "/\(b1Row.uuidString)/live.vs.archive.mov"
        #expect(fm.createFile(atPath: b1Path, contents: Data([1, 2, 3])))
        let b1 = record(b1Path, derivedFrom: original.id)
        let b2 = record(bDir + "/\(b2Row.uuidString)/gone.vs.archive.mov", derivedFrom: original.id)
        let b3 = record(bDir + "/\(b3Row.uuidString)/fileGone.vs.archive.mov", derivedFrom: original.id)

        // Outside the buffer, and a sibling folder that merely starts with the root's name.
        let outside = record("/Users/rickb/Movies/elsewhere/x.mov")
        let lookalike = record(sb.root.appendingPathComponent("buffer2/batch-1/x/y.mov").path, derivedFrom: original.id)
        model.records.append(contentsOf: [original, a1, a2, b1, b2, b3, outside, lookalike])

        let n = await model.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root)
        #expect(n == 3, "a1, a2 (batch gone) + b2 (row gone)")
        #expect(a1.isPurged && a2.isPurged && b2.isPurged)
        #expect(!b1.isPurged, "a live companion is never touched")
        #expect(!b3.isPurged, "its folders exist — the file's fate is the job's reconciliation, not launch's")
        #expect(!original.isPurged && !outside.isPurged && !lookalike.isPurged)
        #expect(fm.fileExists(atPath: b1Path), "nothing on disk is touched")

        // Idempotent.
        #expect(await model.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root) == 0)

        await model.mediaLedger.waitForPendingWrites()
        let lines = model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.by == .angel })
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.recordID, $0) })
        #expect(byID[a1.id]?.batchID == "batch-2026-09-10T10-00-00")
        #expect(byID[a1.id]?.detail[MediaLedgerEvent.Detail.reason] == VideoScanModel.ArchiveAngelLaunchReconcile.batchFolderGone)
        #expect(byID[b2.id]?.batchID == "batch-2026-09-19T12-49-52")
        #expect(byID[b2.id]?.detail[MediaLedgerEvent.Detail.reason] == VideoScanModel.ArchiveAngelLaunchReconcile.entryFolderGone)
    }

    @Test("an empty catalog or a catalog with nothing under the buffer does no work and stats nothing")
    func nothingUnderTheBuffer() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angellaunch2")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let root = sb.root.appendingPathComponent("buffer", isDirectory: true)
        model.records = [record("/Volumes/LaCie/Family/tape.mov")]
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let n = await model.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root) { _ in
            asked.withLock { $0 += 1 }
            return true
        }
        #expect(n == 0)
        #expect(asked.withLock { $0 } == 0)
    }
}
