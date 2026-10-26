// CatalogCodex143RefuseAndNameTests.swift
// Codex closing pass on #141 F2 (docs/reviews/codex/
// codex-review-committer-lost-writes-2026-10-25.md, cycle #143) and the
// fresh-eyes review: the orderings the first fix (a rebuild on Reopen) left
// open, pinned against the promise in CatalogCommitter.swift's header —
// a row another writer changed is HELD and NAMED, never written over,
// never rebuilt; the same check stands at the commit door.
//
//   Codex #2  a row edited AFTER Reopen's read-back and BEFORE the retry:
//             the door compares the row's lock inside the transaction and
//             refuses the WHOLE commit (nothing written, generation kept);
//             the next Reopen holds and names that row, saves the rest;
//   Codex #3  a record this session HOLDS (no whole-file hash) that the
//             other writer materialised as a row: the read-back checks it
//             too (expectation "still pending") — held, named, theirs kept;
//   idempotent  a held row stays held across a second Reopen, named again;
//   truth     a row ONLY this session wrote is never held — every fixture
//             row saved twice around another writer's generation, and a
//             dirty sibling's scalar after a scoped save (the per-field
//             baseline follows the store, codex #141 F3 kept for sets).
//
// Red/green (Debug, M4 Max) — RED on 549a9b798, GREEN here:
//   editAfterReadBackIsRefusedAtTheDoor            RED  retry commits; B's decision on Y gone          → GREEN refused, then held
//   heldRecordMaterialisedByTheOtherWriterIsHeld   RED  retry overwrites B's row; decision gone        → GREEN held, decision kept
//   conflictStaysHeldAcrossASecondReopen           RED  no HELD line exists (the rebuild)              → GREEN held twice
//   rowsOnlyThisSessionWroteAreNeverHeld           GREEN before (no holds existed) and after (no false hold)
//
// Dimensions: LOGIC (the three orderings, the second Reopen); TRUTH (store
// and relaunch show the other writer's values; memory never shows an
// unsaved value as saved); ISOLATION (CutoverScene sandbox, second
// repositories as the other writer, never Application Support); SCALE and
// the door's cost in Core (CatalogCommitRowLockTests); MEDIA N/A; SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenRefuseAndNameTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Another writer committed SOMETHING (an empty generation step): the
    /// catalog's generation moves without any row of ours changing.
    func otherWriterBumpsGeneration() async throws {
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let outcome = await repository.write(as: .ui) { _ in }
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's commit: \(outcome)") }
    }

    /// Another writer stores `record` as a `files` row (a twin of a record
    /// this session only HOLDS), with `digest` and a footage decision about
    /// `otherID` — what a second session does when its Fill In Full Hashes
    /// finishes first.
    func otherWriterMaterialises(_ record: VideoRecord, digest: String, decidingAbout otherID: UUID) async throws {
        let twin = try CatalogPendingRecord.record(try CatalogPendingRecord.json(VideoRecordDTO(record)))
        Self.giveDigest(twin, digest)
        twin.footageDecisions = [FootageDecision(otherID: otherID, verdict: .notSame, decidedAt: Date(timeIntervalSince1970: 1_790_600_000))]
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let snapshot = VideoRecordDTO(twin)
        let item = CatalogCommit.Item(id: twin.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .ui, items: [item]), on: repository)
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's materialisation: \(outcome)") }
    }

    /// A whole-file digest for a record that has none (what Fill In Full
    /// Hashes gives it).
    static func giveDigest(_ record: VideoRecord, _ digest: String) {
        record.contentFixity = ContentFixity(digest: digest, byteCount: record.sizeBytes,
                                             stamp: FileIdentityStamp(device: 1, inode: 2, size: record.sizeBytes, mtimeNs: 3,
                                                                      ctimeNs: 4, volumeUUID: nil),
                                             computedAt: Date(timeIntervalSince1970: 1_790_600_000))
    }

    /// The record `id` as a fresh load of catalog.sqlite gives it.
    func reloadedRecord(_ id: UUID) async throws -> VideoRecord {
        try #require(try await sqliteLoad().records.first { $0.id == id })
    }

    /// How many HELD lines name `record`.
    func heldLineCount(for record: VideoRecord) -> Int {
        sandbox.catalogLogText().components(separatedBy: "\n").filter { $0.contains("Catalog store: HELD \(record.id.uuidString)") }.count
    }
}

@Suite("Catalog Reopen / commit door — refuse and name: the orderings the rebuild left open (codex #143)", .serialized)
@MainActor
struct CatalogReopenRefuseAndNameTests {

    private typealias Base = CatalogReopenReconcileTests

    /// Codex #2. B decides on Y; A edits X and is blocked; Reopen checks X
    /// (fine). Before the retry A edits Y's note. The retry must NOT delete
    /// B's decision: the door compares Y's lock and refuses the whole save;
    /// the next Reopen holds Y, names it, and saves X.
    @Test("a row edited after the read-back and before the retry is refused at the door; Reopen then holds it and saves the rest")
    func editAfterReadBackIsRefusedAtTheDoor() async throws {
        let (scene, committer) = try await Base.launched("codex143_late_edit")
        defer { scene.cleanup() }
        let x = try scene.record(.healthy)
        let y = try scene.record(.stalePrint)
        try await scene.otherWriterDecides(rowOf: y, about: x.id)

        try await Base.editAndFailSave(scene, committer, timing: .debounceWindow) { x.userNotes = "X's note" }
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLine(for: x) == nil, "X was not touched by the other writer")

        y.userNotes = "late edit, after the read-back"
        #expect(committer.commitNow() == false, "the door refuses the whole save")
        let blocked = try #require(committer.blockedReason, "the committer is blocked again, with the door's words")
        #expect(blocked.contains("changed under this session"), Comment(rawValue: blocked))
        #expect(blocked.contains(y.id.uuidString), "the row is named: \(blocked)")
        let afterDoor = try await scene.reloaded(.stalePrint)
        #expect(afterDoor.footageDecisions.map(\.otherID) == [x.id], "B's decision on Y survives the refused save")
        #expect(afterDoor.userNotes != y.userNotes, "nothing of the refused save was written")
        #expect(try await scene.reloaded(.healthy).userNotes != "X's note", "nothing — not even X — was written: one transaction")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        let held = try #require(scene.heldLine(for: y), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(held.contains("footage decisions"), Comment(rawValue: held))
        #expect(committer.commitNow() == false, "Y is held: the save is not whole")
        #expect(try await scene.reloaded(.healthy).userNotes == "X's note", "X — untouched by the other writer — is saved")
        let back = try await scene.reloaded(.stalePrint)
        #expect(back.footageDecisions.map(\.otherID) == [x.id])
        #expect(back.userNotes != y.userNotes, "Y's late edit is held, not written")
        #expect(y.userNotes == "late edit, after the read-back", "memory keeps the person's value")

        try await scene.relaunch()
        #expect(try scene.record(.stalePrint).footageDecisions.map(\.otherID) == [x.id])
        #expect(try scene.record(.healthy).userNotes == "X's note")
    }

    /// Codex #3. A holds a new record without its hash; B (whose hash job
    /// finished first) stores the same id as a row with a footage decision;
    /// A then gets the hash and edits. Reopen must check the held record
    /// too — its expectation is "still pending" — and hold it.
    @Test("a held record the other writer materialised as a row is held and named; their row and decision survive")
    func heldRecordMaterialisedByTheOtherWriterIsHeld() async throws {
        let (scene, committer) = try await Base.launched("codex143_held")
        defer { scene.cleanup() }
        let other = try scene.record(.stalePrint)
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/fresh/held-by-this-session.mov")
        scene.model.records.append(fresh)
        #expect(committer.commitNow(), "a new record with no hash is held (durable at its payload)")
        #expect(committer.heldIDs.contains(fresh.id))

        let digest = String(repeating: "ab", count: 32)
        try await scene.otherWriterMaterialises(fresh, digest: digest, decidingAbout: other.id)
        #expect(try await scene.reloadedRecord(fresh.id).footageDecisions.map(\.otherID) == [other.id], "fixture: B's row and decision are stored")

        CutoverScene.giveDigest(fresh, digest)
        fresh.userNotes = "A's note on the held record"
        #expect(committer.commitNow() == false, "the generation check refuses")
        #expect(committer.blockedReason?.contains("another writer") == true, "the CAS or the door refuses: \(committer.blockedReason ?? "nil")")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        let held = try #require(scene.heldLine(for: fresh), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(held.contains("stored it as a row"), Comment(rawValue: held))
        #expect(committer.commitNow() == false, "the held record is not saved over their row")

        let back = try await scene.reloadedRecord(fresh.id)
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision survives")
        #expect(back.userNotes != fresh.userNotes, "A's note is not written over B's row")
        #expect(fresh.userNotes == "A's note on the held record", "memory keeps the person's value")

        try await scene.relaunch()
        let relaunched = try #require(scene.model.records.first { $0.id == fresh.id })
        #expect(relaunched.footageDecisions.map(\.otherID) == [other.id])
    }

    @Test("a held row stays held across a second Reopen (named again); another row edited meanwhile still saves")
    func conflictStaysHeldAcrossASecondReopen() async throws {
        let (scene, committer) = try await Base.launched("codex143_idempotent")
        defer { scene.cleanup() }
        let a = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)
        try await scene.otherWriterDecides(rowOf: a, about: other.id)
        try await Base.editAndFailSave(scene, committer, timing: .debounceWindow) { a.userNotes = "A's note" }

        await committer.reopen(at: scene.databaseURL)
        #expect(scene.heldLineCount(for: a) == 1)
        #expect(committer.commitNow() == false)

        other.userNotes = "the other row's note"
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLineCount(for: a) == 2, "said again at every Reopen: \(scene.sandbox.catalogLogText())")
        #expect(scene.heldLine(for: other) == nil, "the other row is not held")
        #expect(committer.commitNow() == false, "A is still held")

        #expect(try await scene.reloaded(.stalePrint).userNotes == "the other row's note", "the other row saved")
        let back = try await scene.reloaded(.healthy)
        #expect(back.footageDecisions.map(\.otherID) == [other.id])
        #expect(back.userNotes != "A's note")
        #expect(a.userNotes == "A's note", "memory keeps the person's value")
    }

    /// TRUTH. The lock is the store's own reading of the row, and a dirty
    /// sibling's scalar baseline follows the store (codex #141 F3 keeps the
    /// SET baseline only): a row only this session wrote never reads as
    /// changed by another writer — no false hold.
    @Test("rows only this session wrote are never held: every fixture row saved twice around another writer's generation; a dirty sibling after a scoped save")
    func rowsOnlyThisSessionWroteAreNeverHeld() async throws {
        let (scene, committer) = try await Base.launched("codex143_truth")
        defer { scene.cleanup() }
        let shapes: [PoisonedCatalogFixture.Shape] = [.healthy, .stalePrint, .tombstonedWithDigest, .curatedConflictA, .curatedConflictB]
        for shape in shapes { try scene.record(shape).starRating = 2 }       // the DDL keeps stars 1…3
        try #require(committer.commitNow(), "the first save lands: \(scene.sandbox.catalogLogText())")
        try await scene.otherWriterBumpsGeneration()
        for shape in shapes { try scene.record(shape).setAsideReason = "checked" }
        #expect(committer.commitNow() == false, "the generation check refuses")
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(!scene.sandbox.catalogLogText().contains("Catalog store: HELD"), "no row was held: \(scene.sandbox.catalogLogText())")
        #expect(committer.commitNow(), "every row saves")
        for shape in shapes { #expect(try await scene.reloaded(shape).setAsideReason == "checked", Comment(rawValue: shape.rawValue)) }

        // A dirty sibling's SCALAR after a scoped save of the other copy.
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.userNotes = "A's note"
        b.userNotes = "B's note"
        try #require(committer.commitNow(ids: [a.id]), "the scoped door saves A alone")
        try await scene.otherWriterBumpsGeneration()
        b.setAsideReason = "sibling"
        #expect(committer.commitNow() == false)
        await committer.reopen(at: scene.databaseURL)
        #expect(scene.heldLine(for: b) == nil, "B's own pending note is not a stranger's write: \(scene.sandbox.catalogLogText())")
        #expect(committer.commitNow(), "B saves")
        #expect(try await scene.reloaded(.curatedConflictB).userNotes == "B's note")
        #expect(try await scene.reloaded(.curatedConflictB).setAsideReason == "sibling")
    }
}
