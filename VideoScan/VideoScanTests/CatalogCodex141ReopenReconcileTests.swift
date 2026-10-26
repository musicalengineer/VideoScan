// CatalogCodex141ReopenReconcileTests.swift
// Codex cycle #141, finding 2 (docs/reviews/codex/
// codex-review-catalog-store-consistency-2026-10-25.md): Catalog ▸ Reopen
// SQLite Catalog accepted a NEWER generation without looking at what the
// other writer had committed. The interleaving:
//   1. A loads generation g (a record with no footage decision);
//   2. B — a second repository on the same catalog.sqlite — commits a
//      footage decision for that record at g+1;
//   3. A edits the record's note inside the debounce window (or under a
//      MOPS-16 write hold);
//   4. A's save fails the generation check — correct, A is blocked;
//   5. A chooses Reopen: the expected generation becomes g+1, the records
//      and baselines stay at g;
//   6. the retry diffs A's stale record against the store: the missing
//      decision reads as an edit and B's decision is DELETED (g+2);
//   7. a relaunch keeps the loss.
//
// Red/green (Debug, M4 Max):
//   reopenKeepsBothWritersChanges(debounceWindow)   RED  back.footageDecisions == []  → GREEN [other]
//   reopenKeepsBothWritersChanges(writeHold)        RED  back.footageDecisions == []  → GREEN [other]
//   reopenKeepsTheCatalogsValueWhereBothChanged…    RED  decisions [] / setAside "damaged" → GREEN [other] / nil
//   reopenLeavesAnUntouchedRowsEditWhole            GREEN before and after (pins: no over-reach)
// Fix: CatalogCommitter+Reconcile.swift — when the reopened store's
// generation is not the one this session knew, every CHANGED record is
// checked against the store's row; a row the other writer changed too is
// rebuilt from the store with this session's own shared-curated edits
// (the per-field baseline knows them) re-applied; the rest is the
// catalog's, named in the log.
//
// Dimensions: LOGIC (both timings of rule 8 — debounce window and write
// hold — the untouched row, the reverse conflict); TRUTH (what the store
// holds after the save and after a relaunch is what memory shows);
// ISOLATION (CutoverScene sandbox, a second repository as the other
// writer, never Application Support); SCALE in Core (CatalogCommitScale
// Tests — the commit pipeline is unchanged); MEDIA N/A; SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenReconcileTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Another writer: a second repository on the same catalog.sqlite
    /// commits a footage decision for `record` about `otherID`, advancing
    /// the generation past this session's.
    func otherWriterDecides(rowOf record: VideoRecord, about otherID: UUID) async throws {
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let digest = try #require(CatalogCommit.digest(of: record), "the fixture row carries a whole-file digest")
        let rowID = record.id.uuidString
        let json = """
        {"rowID":"\(rowID)","otherRowID":"\(otherID.uuidString)","verdict":"notSame","decidedAt":1790600000}
        """
        let row = try JSONDecoder().decode(CatalogRecordDTO.FootageDecisionRow.self, from: Data(json.utf8))
        let outcome = await repository.write(as: .ui) { tx in
            try tx.replaceFootageDecisions(rowID: rowID, digest: digest, [row])
        }
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's commit: \(outcome)") }
    }
}

@Suite("Catalog Reopen after another writer — this session's edit and the other writer's commit both survive (codex #141 F2)",
       .serialized)
@MainActor
struct CatalogReopenReconcileTests {

    /// When this session's edit happens (rule 8's two retained-edit cases).
    enum EditTiming: String, CaseIterable, Sendable {
        case debounceWindow, writeHold
    }

    /// A launched scene whose launch-migration commit has landed, so the
    /// next generation step is the other writer's.
    private static func launched(_ label: String) async throws -> (CutoverScene, CatalogCommitter) {
        let scene = try CutoverScene.make(label)
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        try #require(committer.commitNow(), "the launch commit lands before the other writer acts")
        return (scene, committer)
    }

    /// A edits `edit()` at `timing`; the first save must fail the
    /// generation check and block the committer.
    private static func editAndFailSave(_ scene: CutoverScene, _ committer: CatalogCommitter, timing: EditTiming,
                                        _ edit: () -> Void) async throws {
        switch timing {
        case .debounceWindow:
            edit()
            scene.model.saveCatalogDebounced()
            try await scene.settle()                              // the timer fires: the commit is refused
        case .writeHold:
            let owner = CatalogWriteHoldOwner()
            _ = await scene.model.catalogStore.holdWrites(reason: "a job is reading the catalog", owner: owner)
            edit()
            #expect(scene.model.saveCatalogNow() == false, "held: the commit waits")
            scene.model.catalogStore.releaseWriteHold()
            #expect(scene.model.saveCatalogNow() == false, "the hold is gone; the generation check refuses")
        }
        let blocked = try #require(committer.blockedReason, "the first save must be refused by the generation check")
        #expect(blocked.contains("another writer committed generation"), Comment(rawValue: blocked))
    }

    @Test("A's note (debounce window / write hold) and B's footage decision both survive Reopen + save, the reload and a relaunch",
          arguments: EditTiming.allCases)
    func reopenKeepsBothWritersChanges(_ timing: EditTiming) async throws {
        let (scene, committer) = try await Self.launched("codex141_reopen_\(timing.rawValue)")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)
        #expect(a.footageDecisions.isEmpty)

        try await scene.otherWriterDecides(rowOf: a, about: other.id)
        try await Self.editAndFailSave(scene, committer, timing: timing) { a.userNotes = "A's note" }
        #expect(try await scene.reloaded(.healthy).userNotes != "A's note", "nothing was written by the refused save")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil, "Reopen lifts the block")
        #expect(committer.commitNow(), "the retained edit lands after Reopen")

        let back = try await scene.reloaded(.healthy)
        #expect(back.userNotes == "A's note", "A's note survives")
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision survives A's Reopen + save")
        let shown = try scene.record(.healthy)
        #expect(shown.userNotes == "A's note")
        #expect(shown.footageDecisions.map(\.otherID) == [other.id], "memory shows B's decision too")
        #expect(committer.changedRecordCount() == 0)

        try await scene.relaunch()
        let relaunched = try scene.record(.healthy)
        #expect(relaunched.userNotes == "A's note")
        #expect(relaunched.footageDecisions.map(\.otherID) == [other.id])
    }

    @Test("a row the other writer did NOT touch keeps this session's whole edit (note and a row-scoped field); the other writer's row keeps its decision")
    func reopenLeavesAnUntouchedRowsEditWhole() async throws {
        let (scene, committer) = try await Self.launched("codex141_reopen_untouched")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)
        let theirs = try scene.record(.stalePrint)

        try await scene.otherWriterDecides(rowOf: theirs, about: a.id)
        try await Self.editAndFailSave(scene, committer, timing: .debounceWindow) {
            a.userNotes = "A's note"
            a.setAsideReason = "damaged"
        }

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(committer.commitNow())

        let back = try await scene.reloaded(.healthy)
        #expect(back.userNotes == "A's note")
        #expect(back.setAsideReason == "damaged", "a row nobody else touched is saved whole")
        #expect(try await scene.reloaded(.stalePrint).footageDecisions.map(\.otherID) == [a.id])
        #expect(!scene.sandbox.catalogLogText().contains("Reopen reconciled"), "no row was reconciled: the other writer touched none of this session's changed rows")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).setAsideReason == "damaged")
        #expect(try scene.record(.stalePrint).footageDecisions.map(\.otherID) == [a.id])
    }

    @Test("both changed one row: this session's shared edit (note) is kept, the catalog's value wins for a part the baseline cannot attribute (set-aside), and the log names the row")
    func reopenKeepsTheCatalogsValueWhereBothChangedANonSharedPart() async throws {
        let (scene, committer) = try await Self.launched("codex141_reopen_reverse")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)

        try await scene.otherWriterDecides(rowOf: a, about: other.id)
        try await Self.editAndFailSave(scene, committer, timing: .debounceWindow) {
            a.userNotes = "A's note"
            a.setAsideReason = "damaged"
        }

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(committer.commitNow())

        let back = try await scene.reloaded(.healthy)
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision survives")
        #expect(back.userNotes == "A's note", "A's shared edit is kept: the baseline knows it was A's")
        #expect(back.setAsideReason == nil, "the catalog's value wins where the baseline cannot say who changed it")
        let shown = try scene.record(.healthy)
        #expect(shown.setAsideReason == nil, "memory shows the catalog's value, not a value that was not saved")
        #expect(shown.footageDecisions.map(\.otherID) == [other.id])
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Reopen reconciled \(a.id.uuidString)"), Comment(rawValue: log))
        #expect(log.contains("Kept this session's edits to: notes"), Comment(rawValue: log))
    }
}
