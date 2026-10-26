// CatalogCodex145NewCopyTests.swift
// Codex cycle #145, finding 2 (docs/reviews/codex/
// codex-review-committer-refuse-and-name-2026-10-25.md): a record this
// session CREATES skipped the per-row check (it has no row to lock) — and
// its insert wrote every curated value it carried into the content's
// DIGEST-keyed display rows. A new copy of a content another writer had
// changed (Promote's `registerPromotedCopy` copies the source's curation
// onto a new record) wrote this session's stale note over theirs, even while
// the source row itself was HELD.
//
// The promise: a new copy of a content this session already holds is
// checked like its siblings — its shared SCALARS against the store's current
// values through the content's per-field baseline (the door and Reopen, one
// check: CatalogRowCheck.checkNewCopy); a group it did not edit is not
// written at all; a group it edited that another writer also changed refuses
// the save, and Reopen holds and names the new copy.
//
// Red/green (Debug, M4 Max):
//   newCopyOfAHeldRowDoesNotOverwriteTheirNote       RED on dfd4298ff (C's insert wrote "A's note" over "B's note") → GREEN
//   newCopyDoesNotWriteAnInheritedNoteOverTheirs     RED on dfd4298ff (C's insert wrote "base" over "B's note")     → GREEN
//
// Dimensions: LOGIC (held source + edited copy; clean source + inherited
// copy); TRUTH (store and relaunch keep the other writer's note; the new
// copy's row IS stored when nothing conflicts); ISOLATION (CutoverScene
// sandbox, a second repository as the other writer). The door in Core:
// CatalogCommitRowLockTests.doorChecksANewCopysSharedScalars. SCALE / MEDIA /
// SENSOR N/A.
//
// Suites (filter by SUITE): CatalogNewCopySharedCurationTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog commit — a new copy never writes over another writer's shared curation (codex #145 F2)", .serialized)
@MainActor
struct CatalogNewCopySharedCurationTests {

    private typealias Base = CatalogReopenReconcileTests

    /// Codex's reproduction: R held (both changed its note); A then adds
    /// copy C of R's content carrying A's note (as Promote would).
    @Test("R is held; a new copy C carrying A's note does not overwrite B's note; Reopen holds C too; a relaunch shows B's note")
    func newCopyOfAHeldRowDoesNotOverwriteTheirNote() async throws {
        let (scene, committer) = try await Base.launched("codex145_new_copy_held")
        defer { scene.cleanup() }
        let r = try scene.record(.healthy)
        let digest = try #require(CatalogCommit.digest(of: r))
        try await scene.otherWriterNotes(rowOf: r, "B's note")
        r.userNotes = "A's note"
        #expect(committer.commitNow() == false, "the generation check (or the door) refuses")
        await committer.reopen(at: scene.databaseURL)
        #expect(scene.heldLine(for: r)?.contains("notes") == true, Comment(rawValue: scene.sandbox.catalogLogText()))

        let c = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/fresh/promoted-copy.mov")
        CutoverScene.giveDigest(c, digest)
        #expect(c.userNotes == "A's note", "fixture: the copy carries the source's (unsaved) note")
        scene.model.records.append(c)
        #expect(committer.commitNow() == false, "the new copy's note is refused, not written")
        #expect(try await scene.reloaded(.healthy).userNotes == "B's note", "B's note survives the new copy's save")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLine(for: c) != nil, "the new copy is held and named: \(scene.sandbox.catalogLogText())")
        #expect(committer.commitNow() == false)
        #expect(try await scene.reloaded(.healthy).userNotes == "B's note")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).userNotes == "B's note")
    }

    /// The same class without any edit by A: the new copy only INHERITED
    /// the note the content had when this session loaded it. It is stored,
    /// and the inherited value is not written over B's.
    @Test("a new copy that did not edit its inherited note is stored and does not write that note over the other writer's")
    func newCopyDoesNotWriteAnInheritedNoteOverTheirs() async throws {
        let (scene, committer) = try await Base.launched("codex145_new_copy_clean")
        defer { scene.cleanup() }
        let r = try scene.record(.healthy)
        r.userNotes = "base"
        try #require(committer.commitNow(), "the content's note is \"base\" as this session loads and saves it")
        let inherited = r.userNotes
        let digest = try #require(CatalogCommit.digest(of: r))
        try await scene.otherWriterNotes(rowOf: r, "B's note")

        let c = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/fresh/inherited-copy.mov")
        CutoverScene.giveDigest(c, digest)
        #expect(c.userNotes == inherited)
        scene.model.records.append(c)
        #expect(committer.commitNow() == false, "the generation check refuses")
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLine(for: c) == nil, "C edited nothing shared: nothing to hold")
        #expect(committer.commitNow(), "C is stored")
        #expect(try await scene.reloaded(.healthy).userNotes == "B's note", "the inherited note is not written over B's")
        #expect(try await scene.reloadedRecord(c.id).userNotes == "B's note", "C's row is stored and shows the content's note")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).userNotes == "B's note")
    }
}
