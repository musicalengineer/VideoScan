// PruneApplyTests.swift
// "Archived — what next?" → Apply (2026-09-19). A real promote in a
// sandbox makes the fixity-verified archive copy; a second copy of the
// same content on the sources volume is the "extra" the plan would trash.
// Tests use `.permanent` so fixtures never reach the real Trash; the sheet
// always passes `.toTrash` (the same routine, the other flavour).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archived — what next? → Apply", .serialized)
@MainActor
struct PruneApplyTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let ids: [UUID]
        let shown: PrunePlan
        let trash: PrunePlan.CopyRef
        let keeper: PrunePlan.CopyRef
        let archivePath: String
    }

    /// Source A promoted; A2 is a byte-identical copy elsewhere on the
    /// sources volume; a cloud copy is attested so the family is covered;
    /// keep-one keeps one working copy and puts the other in the plan.
    private func fixture(_ label: String) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_a.mov"),
                                                       bytes: 40 * 1024, seed: 7)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA), "fixture: promote made an archive copy")

        let dupDir = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let a2 = dupDir.appendingPathComponent("test_prune_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let recA2 = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1992")
        // Same bytes → same content key: in the real catalog the scanner
        // sets the hash; here the fixture does, on all three copies.
        for r in [recA, recA2, archive] { r.contentHash = "v1:test-prune-a" }
        model.records.append(recA2)
        let ids = [recA.id, recA2.id]
        await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: ids).flush?.value

        let shown = await model.prunePlan(for: ids, options: .init(), isOnline: { _ in true })
        try #require(shown.trashCount == 1, "fixture: one extra copy in the plan — \(shown)")
        let family = try #require(shown.families.first { !$0.trash.isEmpty })
        return Fixture(sb: sb, model: model, ids: ids, shown: shown, trash: family.trash[0],
                       keeper: try #require(family.keeper), archivePath: archive.fullPath)
    }

    private func apply(_ f: Fixture) async -> VideoScanModel.PruneApplyOutcome {
        await f.model.applyPrune(shown: f.shown, recordIDs: f.ids, options: .init(), batchID: "test-batch",
                                 mode: .permanent)
    }

    @Test func theExtraCopyGoesTheArchiveAndTheKeeperStay() async throws {
        let f = try await fixture("prune_ok"); defer { f.sb.cleanup() }
        let out = await apply(f)
        #expect(out.trashed == 1 && out.held.isEmpty && out.failed.isEmpty, "\(out)")
        #expect(!FileManager.default.fileExists(atPath: f.trash.fullPath))
        #expect(FileManager.default.fileExists(atPath: f.keeper.fullPath), "the working copy kept")
        #expect(FileManager.default.fileExists(atPath: f.archivePath), "the archive copy untouched")
        #expect(f.model.record(forID: f.trash.id)?.purgedAt != nil, "the catalog says it is gone")
        await f.model.mediaLedger.waitForPendingWrites()
        let kinds = f.model.mediaLedger.allEvents().map(\.event)
        #expect(kinds.contains(.approval) && kinds.contains(.copyDeleted), "\(kinds)")
        let approval = try #require(f.model.mediaLedger.allEvents().first { $0.event == .approval })
        #expect(approval.by == .rick && approval.detail[MediaLedgerEvent.Detail.count] == "1")
    }

    @Test func aNoteAddedSinceThePlanHoldsTheCopy() async throws {
        let f = try await fixture("prune_note"); defer { f.sb.cleanup() }
        f.model.record(forID: f.trash.id)?.userNotes = "Mom's favourite — keep this one"
        let out = await apply(f)
        #expect(out.trashed == 0 && out.held.count == 1, "\(out)")
        #expect(out.held[0].contains("plan changed"))
        #expect(FileManager.default.fileExists(atPath: f.trash.fullPath))
    }

    @Test func aMissingArchiveCopyHoldsEverything() async throws {
        let f = try await fixture("prune_noarchive"); defer { f.sb.cleanup() }
        try FileManager.default.removeItem(atPath: f.archivePath)
        let out = await apply(f)
        #expect(out.trashed == 0 && out.held.count == 1, "\(out)")
        #expect(out.held[0].contains("archive copy is not on disk"), "\(out.held)")
        #expect(FileManager.default.fileExists(atPath: f.trash.fullPath), "never trash the last copy")
    }

    @Test func aKeeperRewrittenOnDiskHoldsTheCopy() async throws {
        let f = try await fixture("prune_keeper"); defer { f.sb.cleanup() }
        try Data(count: 10).write(to: URL(fileURLWithPath: f.keeper.fullPath))
        let out = await apply(f)
        #expect(out.trashed == 0 && out.held.first?.contains("working copy to keep") == true, "\(out)")
        #expect(FileManager.default.fileExists(atPath: f.trash.fullPath))
    }

    @Test func readOnlyViewersNeverDelete() async throws {
        let f = try await fixture("prune_ro"); defer { f.sb.cleanup() }
        f.model.isReadOnly = true
        let out = await apply(f)
        #expect(out.trashed == 0)
        #expect(FileManager.default.fileExists(atPath: f.trash.fullPath))
    }

    @Test func applyIsOfferedOnlyWithSomethingToMoveOnce() {
        typealias S = ArchivedWhatNextSheet
        #expect(S.canApply(trashCount: 2, applying: false, applied: false, readOnly: false))
        #expect(!S.canApply(trashCount: 0, applying: false, applied: false, readOnly: false))
        #expect(!S.canApply(trashCount: 2, applying: true, applied: false, readOnly: false))
        #expect(!S.canApply(trashCount: 2, applying: false, applied: true, readOnly: false))
        #expect(!S.canApply(trashCount: 2, applying: false, applied: false, readOnly: true))
    }

    /// Sensor: Apply is a plan in front of the ONE Trash routine — it owns
    /// no file deletion, and the sheet never asks for permanent deletion.
    @Test func sensorApplyOwnsNoFileDeletionAndTheSheetOnlyTrashes() throws {
        func source(_ name: String) throws -> String {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: dir.appendingPathComponent("VideoScan").appendingPathComponent(name), encoding: .utf8)
        }
        let apply = try source("VideoScanModel+PruneApply.swift")
        #expect(apply.contains("await deleteConfirmedJunk(targets, mode: mode)"), "the ONE existing Trash routine")
        #expect(!apply.contains("trashItem("), "no file deletion of its own")
        #expect(!apply.contains("removeItem("), "no file deletion of its own")
        let sheet = try source("ArchivedWhatNextSheet.swift")
        #expect(sheet.contains("model.applyPrune(shown: shown"), "Apply is wired")
        #expect(!sheet.contains(".permanent"), "the sheet only ever moves to the Trash")
    }
}
