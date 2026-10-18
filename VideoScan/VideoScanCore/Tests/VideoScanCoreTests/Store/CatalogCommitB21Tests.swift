// CatalogCommitB21Tests.swift
// Cutover B2.1 in Core — codex's B2 findings on the commit body and the
// live doors (docs/reviews/codex/codex-review-cutover-b2-write-side-switch-door-2026-10-17.md):
//   LOGIC     an unrelated people edit leaves another name's unresolved
//             conflict in place (P1-6); a derived kind the store refuses
//             leaves the row PARTIAL, not written (P2-7); a row without a
//             whole-file hash is held in `pending_rows` and leaves it when it
//             lands (gap 1); a purge tombstones the row and the load skips
//             it, never a DELETE (gap 3); intermediate marker revisions land
//             in order (gap 2); a dirty sibling writes only the curated
//             fields it changed since its own baseline (P1-1).
// Under Tests/…/Store/ because it reads the database with GRDB.
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitB21Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)

@Suite("CatalogCommit B2.1 — people deltas, partial rows, pending rows, purges, marker revisions, sibling baselines", .serialized)
struct CatalogCommitB21Tests {

    @Test("P1-6: adding Bob leaves Donna's unresolved confirmed/rejected conflict exactly as it was")
    func peopleConflictSurvivesUnrelatedEdit() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        try await s.queue().write { db in
            try db.execute(sql: """
                INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, 'Donna', 'confirmed', 1790000000, 1);
                INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, 'Donna', 'rejected', NULL, 1);
                """, arguments: [digest, digest])
        }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.confirmedByUserPeople.append(ConfirmedTag(name: "Bob", confirmedAt: Date(timeIntervalSince1970: 1_790_100_000)))
        let outcome = try await s.commit([h])
        #expect(outcome.isCommitted)
        let donna: Int? = try s.scalar("SELECT count(*) FROM people_tags WHERE digest = ? AND name = 'Donna' AND conflict = 1", [digest])
        #expect(donna == 2)
        let bob: Int? = try s.scalar("SELECT count(*) FROM people_tags WHERE digest = ? AND name = 'Bob' AND kind = 'confirmed'", [digest])
        #expect(bob == 1)
    }

    @Test("P2-7: a derived kind the store refuses leaves the row partial — not reported written")
    func refusedDerivedIsPartial() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        try await s.queue().write { db in
            try db.execute(sql: "CREATE TRIGGER test_no_captions BEFORE INSERT ON captions BEGIN SELECT RAISE(ABORT, 'injected caption refusal'); END")
        }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.userNotes = "kept"
        h.sceneCaptions = [SceneCaption(timestamp: 1, text: "a canoe")]
        h.sceneCaptionModel = "qwen2.5-vl"
        h.sceneCaptionDate = Date(timeIntervalSince1970: 1_790_200_000)
        let outcome = try await s.commit([h])
        #expect(outcome.isCommitted)
        let landing = outcome.landing(healthyID)
        #expect({ if case .written = landing { return false }; return true }())
        #expect(try await s.load().records[healthyID]?.userNotes == "kept")
    }

    // MARK: - Gap 1: pending rows

    @Test("gap 1: a row without a whole-file hash is HELD in pending_rows; when its hash lands it becomes a files row and the pending row goes")
    func pendingRowHeldThenStored() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let fresh = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: "/Volumes/Fixture/New/held.mov")
        let start = try s.generation()
        let held = try await s.commit([fresh])
        #expect(held.landing(fresh.id.uuidString) == .deferred(CatalogCommitWords.noDigest))
        #expect(held.rows.first?.heldPending == true)
        #expect(try s.generation() == start + 1)
        let pending: Int? = try s.scalar("SELECT count(*) FROM pending_rows WHERE id = ?", [fresh.id.uuidString])
        #expect(pending == 1)
        let again = try await s.commit([fresh])
        #expect(again == .nothingWritten(rows: again.rows), "an unchanged held row is not rewritten")
        FreshRecord.giveDigest(fresh, String(repeating: "c", count: 64))
        let stored = try await s.commit([fresh])
        #expect(stored.landing(fresh.id.uuidString)?.landed == true)
        let after: Int? = try s.scalar("SELECT count(*) FROM pending_rows")
        #expect(after == 0)
        let row: Int? = try s.scalar("SELECT count(*) FROM files WHERE id = ?", [fresh.id.uuidString])
        #expect(row == 1)
    }

    @Test("gap 1: the load hands back the held rows; the schema refuses a pending row whose id is a files row")
    func pendingRowsAtLoad() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let fresh = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: "/Volumes/Fixture/New/held2.mov")
        _ = try await s.commit([fresh])
        let snapshot = try await s.snapshot()
        #expect(snapshot.pending.map(\.id) == [fresh.id.uuidString])
        let back = try CatalogPendingRecord.record(try #require(snapshot.pending.first).json)
        #expect(back.fullPath == "/Volumes/Fixture/New/held2.mov")
        #expect(throws: (any Error).self) {
            try s.queue().write { db in
                try db.execute(sql: "INSERT INTO pending_rows (id, json, queued_at) VALUES (?, '{}', 1)", arguments: [healthyID])
            }
        }
    }

    // MARK: - Gap 3: purges

    @Test("gap 3: a purge tombstones the row (never a DELETE), the load skips it, a second purge is a no-op")
    func purgeTombstonesAndLoadSkips() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let id = try #require(UUID(uuidString: healthyID))
        let outcome = try await s.commit([], purges: [id])
        #expect(outcome.isCommitted)
        #expect(outcome.landing(healthyID) == .removed(.purged(revision: 1)))
        let reason: String? = try s.scalar("SELECT removal_reason FROM files WHERE id = ?", [healthyID])
        #expect(reason == "purged")
        let tombstones: Int? = try s.scalar("SELECT count(*) FROM tombstones WHERE file_id = ? AND reason = 'purged'", [healthyID])
        #expect(tombstones == 1)
        #expect(try await s.load().records[healthyID] == nil)
        let snapshot = try await s.snapshot()
        #expect(snapshot.purged == 1)
        let twice = try await s.commit([], purges: [id])
        #expect(twice.landing(healthyID) == .removed(.alreadyPurged))
    }

    @Test("gap 3 + B2.2: a purge of a held record tombstones its payload and KEEPS it; the load skips it; it coming back clears the tombstone")
    func purgeTombstonesPending() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let fresh = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: "/Volumes/Fixture/New/held3.mov")
        _ = try await s.commit([fresh])
        let outcome = try await s.commit([], purges: [fresh.id])
        #expect(outcome.landing(fresh.id.uuidString) == .removed(.pendingPurged))
        let kept: Int? = try s.scalar("SELECT count(*) FROM pending_rows WHERE id = ?", [fresh.id.uuidString])
        #expect(kept == 1, "the payload is kept, never deleted")
        let tombstoned: Int? = try s.scalar("SELECT count(*) FROM pending_purges WHERE id = ?", [fresh.id.uuidString])
        #expect(tombstoned == 1)
        #expect(try await s.snapshot().pending.isEmpty, "a tombstoned payload is not loaded")
        let twice = try await s.commit([], purges: [fresh.id])
        #expect(twice.landing(fresh.id.uuidString) == .removed(.alreadyPurged))
        fresh.userNotes = "it came back"
        _ = try await s.commit([fresh])
        let cleared: Int? = try s.scalar("SELECT count(*) FROM pending_purges")
        #expect(cleared == 0)
        #expect(try await s.snapshot().pending.map(\.id) == [fresh.id.uuidString])
    }

    @Test("gap 3: a purged row whose record comes back moves on one revision with its own tombstone, and says which")
    func purgedRowComesBack() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        _ = try await s.commit([], purges: [h.id])
        h.userNotes = "back again"
        let outcome = try await s.commit([h])
        #expect(outcome.landing(healthyID)?.landed == true)
        #expect(outcome.rows.first?.adoptedRevision == 2)
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil)
        #expect(try await s.load().records[healthyID]?.userNotes == "back again")
    }

    // MARK: - Gap 2: intermediate marker revisions

    @Test("gap 2: the snapshot of each marker revision, in order, lands each with its own tombstone")
    func intermediateRevisionsLand() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_300_000), reason: .userRemoved)
        h.removalRevision += 1
        let first = CommitScene.item(h)
        h.removal = nil
        h.removalRevision += 1
        let outcome = try await s.commitItems([first, CommitScene.item(h)])
        #expect(outcome.rows.map(\.landing.landed) == [true, true])
        let revisions: [Int] = try await s.queue().read { db in
            try Int.fetchAll(db, sql: "SELECT revision FROM tombstones WHERE file_id = ? ORDER BY revision", arguments: [healthyID])
        }
        #expect(revisions == [1, 2])
        #expect(try await s.load().records[healthyID]?.removal == nil)
    }

    // MARK: - P1-1: per-field baselines

    @Test("P1-1: a sibling dirty for another field, carrying a stale curated value, does not write it over the edit")
    func staleSiblingKeepsEdit() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[PoisonedCatalogFixture.id(.curatedConflictA)])
        let b = try #require(loaded.records[PoisonedCatalogFixture.id(.curatedConflictB)])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.userNotes = "A wrote this"
        b.setAsideReason = "damaged"
        let outcome = try await s.commitItems([CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)])
        #expect(outcome.isCommitted)
        #expect(try await s.load().records[a.id.uuidString]?.userNotes == "A wrote this")
    }
}

/// A new record built from a stored one: a new id and path, no whole-file hash.
enum FreshRecord {
    static func copy(_ source: VideoRecord, path: String) throws -> VideoRecord {
        let encoded = Data(try CatalogPendingRecord.json(VideoRecordDTO(source)).utf8)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["id"] = UUID().uuidString
        object["fullPath"] = path
        object["filename"] = (path as NSString).lastPathComponent
        object["contentFixity"] = nil
        object["archiveFixity"] = nil
        object["pairedWithID"] = nil
        let json = try #require(String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        return try CatalogPendingRecord.record(json)
    }

    static func giveDigest(_ record: VideoRecord, _ digest: String) {
        record.contentFixity = ContentFixity(digest: digest, byteCount: record.sizeBytes,
                                             stamp: FileIdentityStamp(device: 1, inode: 2, size: record.sizeBytes, mtimeNs: 3,
                                                                      ctimeNs: 4, volumeUUID: nil))
    }
}

extension CommitScene {
    static func item(_ record: VideoRecord, baseline: CatalogSharedCurated) -> CatalogCommit.Item {
        let snapshot = VideoRecordDTO(record)
        return CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot),
                                  sharedBaseline: baseline)
    }

    func commitItems(_ items: [CatalogCommit.Item], purges: [UUID] = []) async throws -> CatalogCommit.Outcome {
        let repository = GRDBCatalogRepository(host: "commit-test", durability: .volatileForTests)
        guard await repository.open(at: scene.databaseURL) == .readWrite else {
            await repository.close()
            throw FixtureFailure(words: "commit could not open")
        }
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: items, purges: purges), on: repository)
        await repository.close()
        return outcome
    }

    func commit(_ records: [VideoRecord], purges: [UUID]) async throws -> CatalogCommit.Outcome {
        try await commitItems(records.map { CommitScene.item($0) }, purges: purges)
    }

    func snapshot() async throws -> CatalogLoad.Snapshot {
        let repository = GRDBCatalogRepository(host: "commit-test", durability: .volatileForTests)
        _ = await repository.open(at: scene.databaseURL)
        do {
            let snapshot = try await CatalogLoad.read(repository)
            await repository.close()
            return snapshot
        } catch {
            await repository.close()
            throw error
        }
    }
}
