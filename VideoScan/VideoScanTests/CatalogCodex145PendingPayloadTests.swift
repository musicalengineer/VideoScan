// CatalogCodex145PendingPayloadTests.swift
// Codex cycle #145, finding 1 (docs/reviews/codex/
// codex-review-committer-refuse-and-name-2026-10-25.md): a record this
// session HOLDS in `pending_rows` (no whole-file hash yet) carried the
// expectation "still pending" with no version. Another writer that saved a
// CHANGED payload for the same id (its own note, still without a hash)
// passed both Reopen's read-back and the commit door, and this session's
// retry replaced their payload — unnamed.
//
// The promise: a held payload is expected at the hash of the JSON the store
// holds for it (`CatalogRowLock.ofPending`, read at launch and after every
// put); a different payload is "changed under you" — HELD and named, never
// written over.
//
// Red/green (Debug, M4 Max):
//   pendingPayloadChangedByAnotherWriterIsHeld  RED on dfd4298ff (no HELD line; A's payload replaced B's) → GREEN
//
// Dimensions: LOGIC (pending → changed pending, Reopen then retry); TRUTH
// (the store and a relaunch show the other writer's payload; memory keeps
// the person's value); ISOLATION (CutoverScene sandbox, a second repository
// as the other writer). The door's own check: Core CatalogCommitRowLockTests
// .doorRefusesChangedPending. SCALE / MEDIA / SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenPendingPayloadTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Another writer holds `record` (still no whole-file hash) with its own
    /// payload: a twin with `change` applied, committed through a second
    /// repository — `putPendingRow` replaces the payload.
    func otherWriterHolds(_ record: VideoRecord, _ change: (VideoRecord) -> Void) async throws {
        let twin = try CatalogPendingRecord.record(try CatalogPendingRecord.json(VideoRecordDTO(record)))
        change(twin)
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let snapshot = VideoRecordDTO(twin)
        let item = CatalogCommit.Item(id: twin.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .ui, items: [item]), on: repository)
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's held payload: \(outcome)") }
    }
}

@Suite("Catalog Reopen — a held payload another writer changed is held and named, never replaced (codex #145 F1)", .serialized)
@MainActor
struct CatalogReopenPendingPayloadTests {

    private typealias Base = CatalogReopenReconcileTests

    @Test("pending → changed pending: A's retry does not replace B's payload; the record is held and named; B's note survives a relaunch")
    func pendingPayloadChangedByAnotherWriterIsHeld() async throws {
        let (scene, committer) = try await Base.launched("codex145_pending")
        defer { scene.cleanup() }
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/fresh/held-by-both.mov")
        scene.model.records.append(fresh)
        try #require(committer.commitNow(), "a new record with no hash is held (durable at its payload)")
        try #require(committer.heldIDs.contains(fresh.id))

        try await scene.otherWriterHolds(fresh) { $0.userNotes = "B's note" }
        #expect(try await scene.reloadedRecord(fresh.id).userNotes == "B's note", "fixture: B's payload is stored")

        fresh.userNotes = "A's note"
        #expect(committer.commitNow() == false, "the generation check (or the door) refuses")
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        let held = try #require(scene.heldLine(for: fresh), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(held.contains("held payload"), Comment(rawValue: held))
        #expect(committer.commitNow() == false, "the held record is not saved over B's payload")

        #expect(try await scene.reloadedRecord(fresh.id).userNotes == "B's note", "B's payload is intact")
        #expect(fresh.userNotes == "A's note", "memory keeps the person's value")

        try await scene.relaunch()
        let relaunched = try #require(scene.model.records.first { $0.id == fresh.id })
        #expect(relaunched.userNotes == "B's note")
    }
}
