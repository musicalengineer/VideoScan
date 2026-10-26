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
// First fix (549a9b798): Reopen REBUILT the row from the store and swapped
// the instance in. Codex's closing pass (docs/reviews/codex/
// codex-review-committer-lost-writes-2026-10-25.md, 6 findings) and the
// fresh-eyes review (the two pins in CatalogReopenReconcileReviewTests)
// rejected the rebuild: refuse rather than guess (CLAUDE.md rule 2).
//
// THE PROMISE now (cycle #143, CatalogCommitter.swift header): Reopen reads
// back every record the next commit could submit; a row the store still
// holds as this session last saw it may be saved; a row another writer
// changed is HELD — out of every commit, dirty in memory with the person's
// values, named in catalog.log ("HELD <id> — the catalog changed under you:
// <file> — …; it differs from this session in: <parts> …") — until a
// relaunch. Nothing is rebuilt, nothing of theirs is overwritten. The same
// check stands at the commit door (the per-row lock, Core).
//
// Red/green (Debug, M4 Max) — RED on 549a9b798 (the rebuild), GREEN here:
//   reopenKeepsBothWritersChanges(debounceWindow)  RED  commitNow() true, A's note stored, no HELD line  → GREEN held + named
//   reopenKeepsBothWritersChanges(writeHold)       RED  the same                                           → GREEN held + named
//   reopenLeavesAnUntouchedRowsEditWhole           GREEN before and after (pins: an untouched row saves whole)
//   reopenHoldsTheRowWhereBothChangedANonSharedPart RED  memory rebuilt (setAside nil), note stored      → GREEN memory kept, row held
//   reopenKeepsThisSessionsRemovalMarker (review)  RED  4 issues on the rebuild; re-targeted to the promise → GREEN
//   reopenNamesTheOtherWritersNoteWhenBothChangedIt (review) RED  "A's note" stored, B's unnamed         → GREEN B's note kept
//   reopenLeavesASessionCommittedRowAlone (review) GREEN before and after (pins: no false conflict on a row only we wrote)
//
// Dimensions: LOGIC (both timings of rule 8 — debounce window and write
// hold — the untouched row, the row-scoped conflict, the shared-scalar
// conflict, the marker); TRUTH (what the store holds after the save and
// after a relaunch is the other writer's, and memory never shows a value
// as saved that was not); ISOLATION (CutoverScene sandbox, a second
// repository as the other writer, never Application Support); SCALE and
// the door in Core (CatalogCommitRowLockTests); MEDIA N/A; SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenReconcileTests ·
// CatalogReopenReconcileReviewTests · CatalogReopenReconcileRoundTripReviewTests

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

    /// The HELD line Reopen writes for `record` (codex #143), or nil.
    func heldLine(for record: VideoRecord) -> String? {
        sandbox.catalogLogText().components(separatedBy: "\n").last { $0.contains("HELD \(record.id.uuidString)") }
    }
}

@Suite("Catalog Reopen after another writer — their commit survives; a row both changed is held and named, never rebuilt (codex #141 F2 → #143)",
       .serialized)
@MainActor
struct CatalogReopenReconcileTests {

    /// When this session's edit happens (rule 8's two retained-edit cases).
    enum EditTiming: String, CaseIterable, Sendable {
        case debounceWindow, writeHold
    }

    /// A launched scene whose launch-migration commit has landed, so the
    /// next generation step is the other writer's.
    static func launched(_ label: String) async throws -> (CutoverScene, CatalogCommitter) {
        let scene = try CutoverScene.make(label)
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        try #require(committer.commitNow(), "the launch commit lands before the other writer acts")
        return (scene, committer)
    }

    /// A edits `edit()` at `timing`; the first save must fail the
    /// generation check and block the committer.
    static func editAndFailSave(_ scene: CutoverScene, _ committer: CatalogCommitter, timing: EditTiming,
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
        // The generation CAS, or — when the other writer changed the very row we submit — the door (codex #143).
        #expect(blocked.contains("another writer"), Comment(rawValue: blocked))
    }

    @Test("B's decision survives; A's note on the SAME row (debounce window / write hold) is held and named, not saved — memory keeps it, a relaunch shows the catalog's values",
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
        #expect(committer.blockedReason == nil, "Reopen lifts the block for the rows that may be saved")
        let held = try #require(scene.heldLine(for: a), "the row both writers changed is named: \(scene.sandbox.catalogLogText())")
        #expect(held.contains("footage decisions"), Comment(rawValue: held))
        #expect(held.contains("relaunch"), Comment(rawValue: held))
        #expect(committer.commitNow() == false, "a held row is changed and not stored: the save is not whole")

        let back = try await scene.reloaded(.healthy)
        #expect(back.userNotes != "A's note", "A's note is NOT saved over the row B changed")
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision survives A's Reopen + save")
        let shown = try scene.record(.healthy)
        #expect(shown.userNotes == "A's note", "memory keeps the person's value — nothing is rebuilt")
        #expect(shown.footageDecisions.isEmpty, "memory is NOT refreshed from the store (said: relaunch)")
        #expect(committer.changedRecordCount() == 1, "the held row stays changed")

        try await scene.relaunch()
        let relaunched = try scene.record(.healthy)
        #expect(relaunched.userNotes != "A's note")
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
        #expect(scene.heldLine(for: a) == nil, "the other writer touched none of this session's changed rows: nothing is held")
        #expect(committer.commitNow())

        let back = try await scene.reloaded(.healthy)
        #expect(back.userNotes == "A's note")
        #expect(back.setAsideReason == "damaged", "a row nobody else touched is saved whole")
        #expect(try await scene.reloaded(.stalePrint).footageDecisions.map(\.otherID) == [a.id])
        #expect(!scene.sandbox.catalogLogText().contains("Catalog store: HELD"), "no row was held")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).setAsideReason == "damaged")
        #expect(try scene.record(.stalePrint).footageDecisions.map(\.otherID) == [a.id])
    }

    @Test("both changed one row (their decision, our note + set-aside): the row is held and named with the parts; memory keeps ours, the store keeps theirs, nothing is guessed")
    func reopenHoldsTheRowWhereBothChangedANonSharedPart() async throws {
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
        let held = try #require(scene.heldLine(for: a), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(held.contains("footage decisions"), "theirs is named: \(held)")
        #expect(held.contains("setAsideReason") || held.contains("file facts"), "ours is named: \(held)")
        #expect(held.contains("userNotes"), "ours is named: \(held)")
        #expect(committer.commitNow() == false)

        let back = try await scene.reloaded(.healthy)
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision survives")
        #expect(back.userNotes != "A's note", "A's note is not written over B's row")
        #expect(back.setAsideReason == nil, "A's set-aside is not written over B's row")
        let shown = try scene.record(.healthy)
        #expect(shown.setAsideReason == "damaged", "memory keeps the person's value; it is not shown as saved")
        #expect(shown.userNotes == "A's note")
        #expect(shown.footageDecisions.isEmpty, "memory is not rebuilt from the store")
    }
}

// MARK: - Fresh-eyes review 2026-10-25 (RED on 549a9b798; re-targeted to the promise where the rebuild was assumed)

@MainActor
extension CutoverScene {

    /// Another writer: a second repository sets the SHARED notes of
    /// `record`'s content — the same display-row write the commit body
    /// makes (`writeDisplayValue`), advancing the generation.
    func otherWriterNotes(rowOf record: VideoRecord, _ notes: String) async throws {
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let digest = try #require(CatalogCommit.digest(of: record), "the fixture row carries a whole-file digest")
        var edited = try CatalogRecordDTO(record: record, migrationLoadedAt: 0).curated
        edited.userNotes = notes
        let curated = edited
        let outcome = await repository.write(as: .ui) { tx in
            try tx.writeDisplayValue(digest: digest, field: .userNotes, curated, setAt: 1_790_600_000)
        }
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's commit: \(outcome)") }
    }
}

@Suite("Catalog Reopen after another writer — review pins (2026-10-25)", .serialized)
@MainActor
struct CatalogReopenReconcileReviewTests {

    private static func launched(_ label: String) async throws -> (CutoverScene, CatalogCommitter) {
        let scene = try CutoverScene.make(label)
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        try #require(committer.commitNow(), "the launch commit lands before the other writer acts")
        return (scene, committer)
    }

    /// The reviewer's pin against the rebuild ("catalog wins" dropped this
    /// session's marker and cleared `markerDirty`). Under the promise the
    /// row is HELD: the file IS in the Trash and memory keeps saying so;
    /// the other writer's decision stays in the store; the marker is NOT
    /// written over their row (a footage decision missing in memory cannot
    /// be attributed — theirs added, or ours removed?); the HELD line names
    /// the removal marker and the decision; a person's further marker
    /// change on the held row is refused at its door.
    @Test("this session's Trash marker (a disk fact) stays in memory; the row the other writer changed is held and named — the marker is not written over their decision")
    func reopenKeepsThisSessionsRemovalMarker() async throws {
        let (scene, committer) = try await Self.launched("codex141_review_marker")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)
        #expect(a.removal == nil)

        try await scene.otherWriterDecides(rowOf: a, about: other.id)
        let marker = RemovalMarker.inTrash(movedAt: Date(timeIntervalSince1970: 1_790_600_100),
                                           trashPath: "/Users/rick/.Trash/\(a.filename)", reason: .duplicate)
        #expect(VideoScanModel.stampRemoval(a, marker, kind: .diskFact) == nil, "a disk fact is never refused by a block")
        #expect(a.removal?.state == .inTrash)
        #expect(committer.commitNow() == false, "the generation check refuses the marker's commit")
        let blocked = try #require(committer.blockedReason)
        // The generation CAS, or — when the other writer changed the very row we submit — the door (codex #143).
        #expect(blocked.contains("another writer"), Comment(rawValue: blocked))

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil, "Reopen lifts the block for the rows that may be saved")
        let held = try #require(scene.heldLine(for: a), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(held.contains("removal marker"), Comment(rawValue: held))
        #expect(held.contains("footage decisions"), Comment(rawValue: held))
        #expect(committer.commitNow() == false, "the held row is not saved")

        let shown = try scene.record(.healthy)
        #expect(shown.removal?.state == .inTrash, "memory: the file is in the Trash; the record still says so (never rebuilt)")
        #expect(shown.removal?.trashPath == marker.trashPath, "memory: where it went is the only road back")
        let back = try await scene.reloaded(.healthy)
        #expect(back.removal == nil, "store: the marker is NOT written over the row the other writer changed")
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "store: the other writer's decision survives")
        // A person's marker change on the held row is refused at its door, with words.
        let request = RemovalMarker.removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_600_200), reason: .duplicate)
        let undo = VideoScanModel.stampRemoval(a, request, kind: .request)
        #expect(undo?.contains("changed under you") == true, "a request on a held row is refused: \(undo ?? "nil")")
        #expect(a.removal?.state == .inTrash, "the refused change touched nothing")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).removal == nil, "a relaunch shows the catalog's values")
        #expect(try scene.record(.healthy).footageDecisions.map(\.otherID) == [other.id])
    }

    /// Pins the shared-scalar check: a SHARED scalar group both writers
    /// changed is never overwritten unnamed. Either outcome is acceptable —
    /// keep the catalog's value (refuse / conflict) or write ours and NAME
    /// theirs in catalog.log — but not a silent overwrite.
    @Test("both writers changed the notes: the other writer's note is kept, or its loss is named in the log")
    func reopenNamesTheOtherWritersNoteWhenBothChangedIt() async throws {
        let (scene, committer) = try await Self.launched("codex141_review_notes")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)

        try await scene.otherWriterNotes(rowOf: a, "B's note")
        #expect(try await scene.reloaded(.healthy).userNotes == "B's note", "fixture: the other writer's note is in the store")

        a.userNotes = "A's note"
        #expect(committer.commitNow() == false, "the generation check refuses")
        #expect(committer.blockedReason?.contains("another writer") == true, "the CAS or the door refuses: \(committer.blockedReason ?? "nil")")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        _ = committer.commitNow()

        let back = try await scene.reloaded(.healthy)
        let log = scene.sandbox.catalogLogText()
        #expect(back.userNotes == "B's note" || log.contains("B's note"),
                "the other writer's note was overwritten without being named — store now holds «\(back.userNotes)»; log: \(log)")
        #expect(scene.heldLine(for: a)?.contains("notes") == true, "the row is held and the group named: \(log)")
    }
}

@Suite("Catalog Reopen after another writer — review pins, round trip (2026-10-25)", .serialized)
@MainActor
struct CatalogReopenReconcileRoundTripReviewTests {

    /// Pins the lock's provenance: the per-row lock the committer keeps is
    /// the STORE's own reading of the row (CatalogRowLock, from the row it
    /// read back), never a fingerprint of memory — so a row ONLY this
    /// session wrote never reads as "changed by another writer", and its
    /// later row-scoped edit (set-aside) saves whole.
    @Test("a row only this session committed is not held on Reopen: its later set-aside edit survives whole")
    func reopenLeavesASessionCommittedRowAlone() async throws {
        let scene = try CutoverScene.make("codex141_review_roundtrip")
        defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        try #require(committer.commitNow())
        let a = try scene.record(.healthy)
        let theirs = try scene.record(.stalePrint)

        // This session commits `a` once: its baseline is now what the store read back after the write.
        a.starRating = 2
        try #require(committer.commitNow())
        #expect(committer.changedRecordCount() == 0)

        try await scene.otherWriterDecides(rowOf: theirs, about: a.id)      // another row, not `a`
        a.setAsideReason = "damaged"
        #expect(committer.commitNow() == false, "the generation check refuses")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLine(for: a) == nil, "`a` was held although only this session ever wrote it: \(scene.sandbox.catalogLogText())")
        #expect(committer.commitNow())
        #expect(try scene.record(.healthy).setAsideReason == "damaged", "memory keeps the edit")
        #expect(try await scene.reloaded(.healthy).setAsideReason == "damaged", "the store takes the edit")
        #expect(try await scene.reloaded(.healthy).starRating == 2)
    }
}
