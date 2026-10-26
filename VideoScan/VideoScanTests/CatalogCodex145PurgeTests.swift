// CatalogCodex145PurgeTests.swift
// Codex cycle #145, finding 3 (docs/reviews/codex/
// codex-review-committer-refuse-and-name-2026-10-25.md): a PURGE carried a
// bare id. The door checked only `plan.items`; Reopen read back only records
// still in memory (a purged record has left it); `duePurges` neither checked
// the row's lock nor excluded a HELD id. A queued purge therefore replaced
// the other writer's newer removal marker (their Trash path — the only road
// back) and took the row out of every later load.
//
// The promise: a purge carries the row's expected lock and is checked at
// the door inside the same transaction (a mismatch refuses the whole save);
// Reopen's read-back covers the queued purges too; a purge of a held id is
// never sent until a relaunch.
//
// Red/green (Debug, M4 Max):
//   queuedPurgeDoesNotReplaceTheOtherWritersMarker  RED on dfd4298ff (R purged: B's marker replaced, R gone from the load) → GREEN
//   purgeOfAHeldRowIsNotSent                         RED on dfd4298ff (the held row was purged)                           → GREEN
//
// Dimensions: LOGIC (queued under a write hold, then CAS, Reopen, retry;
// a held id purged); TRUTH (the store and a relaunch keep the other writer's
// marker and trash path; the row stays loaded); ISOLATION (CutoverScene
// sandbox, a second repository as the other writer). The door in Core:
// CatalogCommitRowLockTests.doorRefusesAPurgeOfAChangedRow. SCALE / MEDIA /
// SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenQueuedPurgeTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Another writer moves `record`'s file to the Trash and records it: the
    /// next removal-marker revision, with where the file went.
    func otherWriterTrashes(_ record: VideoRecord, trashPath: String) async throws {
        let twin = try CatalogPendingRecord.record(try CatalogPendingRecord.json(VideoRecordDTO(record)))
        Self.giveDigestOf(record, to: twin)
        twin.removalRevision += 1
        twin.removal = RemovalMarker.inTrash(movedAt: Date(timeIntervalSince1970: 1_790_600_300), trashPath: trashPath,
                                             reason: .duplicate)
        twin.lifecycleStage = .trashed                      // the DDL pairs an inTrash marker with lifecycle 'Trashed'
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let snapshot = VideoRecordDTO(twin)
        let item = CatalogCommit.Item(id: twin.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .ui, items: [item]), on: repository)
        await repository.close()
        guard case .committed(_, let rows) = outcome, rows.first?.landing.landed == true else {
            throw CutoverFailure(words: "the other writer's marker: \(outcome)")
        }
    }

    /// The pending-record JSON round trip keeps the fixities; this keeps it
    /// explicit that the twin names the same content.
    private static func giveDigestOf(_ record: VideoRecord, to twin: VideoRecord) {
        twin.contentFixity = record.contentFixity
        twin.archiveFixity = record.archiveFixity
    }
}

@Suite("Catalog purge — a queued purge is checked against the row it removes; a held row is never purged (codex #145 F3)", .serialized)
@MainActor
struct CatalogReopenQueuedPurgeTests {

    private typealias Base = CatalogReopenReconcileTests

    @Test("A queues R's removal under a write hold; B trashes R; A's purge fails, Reopen holds R, the retry leaves B's marker current and R loaded")
    func queuedPurgeDoesNotReplaceTheOtherWritersMarker() async throws {
        let (scene, committer) = try await Base.launched("codex145_purge_queued")
        defer { scene.cleanup() }
        let r = try scene.record(.healthy)
        let trashPath = "/Users/rick/.Trash/B-moved-\(r.filename)"

        let owner = CatalogWriteHoldOwner()
        _ = await scene.model.catalogStore.holdWrites(reason: "a job is reading the catalog", owner: owner)
        scene.model.records.removeAll { $0.id == r.id }
        committer.purge(ids: [r.id], reason: "removed from the catalog (test)")
        try await scene.otherWriterTrashes(r, trashPath: trashPath)
        scene.model.catalogStore.releaseWriteHold()
        #expect(committer.commitNow() == false, "the generation check (or the door) refuses the purge")

        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil)
        #expect(scene.heldLine(for: r) != nil, "the queued purge's row is checked and held: \(scene.sandbox.catalogLogText())")
        #expect(committer.commitNow() == false, "the held purge is not sent: the save is not whole")

        let back = try await scene.reloaded(.healthy)
        #expect(back.removal?.state == .inTrash, "B's marker is current")
        #expect(back.removal?.trashPath == trashPath, "B's trash path — the road back — is kept")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).removal?.trashPath == trashPath)
    }

    @Test("a door purges a row Reopen already holds: the purge is not sent; the other writer's decision and the row stay")
    func purgeOfAHeldRowIsNotSent() async throws {
        let (scene, committer) = try await Base.launched("codex145_purge_held")
        defer { scene.cleanup() }
        let r = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)
        try await scene.otherWriterDecides(rowOf: r, about: other.id)
        try await Base.editAndFailSave(scene, committer, timing: .debounceWindow) { r.userNotes = "A's note" }
        await committer.reopen(at: scene.databaseURL)
        try #require(scene.heldLine(for: r) != nil, Comment(rawValue: scene.sandbox.catalogLogText()))

        scene.model.records.removeAll { $0.id == r.id }
        committer.purge(ids: [r.id], reason: "removed from the catalog (test)")
        #expect(committer.commitNow() == false, "the held purge is not sent: the save is not whole")

        let back = try await scene.reloaded(.healthy)
        #expect(back.removal == nil, "R is not purged")
        #expect(back.footageDecisions.map(\.otherID) == [other.id], "B's decision stays")
    }
}
