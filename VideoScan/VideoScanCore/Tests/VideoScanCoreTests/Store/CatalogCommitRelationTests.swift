// CatalogCommitRelationTests.swift
// codex #123 on f59f6d841 (docs/reviews/codex/codex-review-p0-purge-replacement-2026-10-22.md):
// pairing a purge with "the item at the same path" lost rows in three plan
// shapes. The commit plan now carries the EXPLICIT relation (purged id →
// the record that replaces it), said by the door that made the swap.
//
//   F1  a PENDING predecessor (held, no hash) purged beside a refused
//       replacement keeps its pending payload;
//   F2  on a case-sensitive volume, /…/reunion.mov landing never lets the
//       purge of /…/Reunion.mov stand when Reunion's own replacement is refused;
//   F3  two ordered snapshots of the replacement, both refused: the old row stays;
//   INCIDENT  one generation mixing writes, holds and 100 REAL-trigger refusals
//       (`archive_copies_need_source`, no injected trigger): zero rows lost,
//       the exact refusal reason on every kept purge;
//   NOT-IN-COMMIT  a replacement absent from the commit: kept while the store
//       does not hold it; purged once it does.
// codex #124 (docs/reviews/codex/codex-review-p0-purge-relation-verify-2026-10-23.md):
//   F1  a replacement whose snapshots land but END purged (a live snapshot
//       then a purge snapshot; an already-purged row sent unchanged) never
//       lets the old row go — red at 3197ef431;
//   F3  the INCIDENT mix now has pending predecessors and repeated refused
//       snapshots, and counts written / held / refused separately — red by
//       mutation against the path-paired design's blind spots.
// (F4 — the committer keeps the relation — is app side: CatalogKeptPurgeRetryTests.)
// Each of F1–F3 was RED at f59f6d841 (old API, path-inferred pairing).
//
// Suites (filter by SUITE): CatalogCommitRelationTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)
private let caseSensitiveVolume = "C0FFEE00-0000-4000-8000-0000000000C5"

extension CommitScene {
    /// A commit with an explicit replacement relation (purged id → replacement id).
    func commitItems(_ items: [CatalogCommit.Item], purges: [UUID],
                     replacements: [UUID: UUID]) async throws -> CatalogCommit.Outcome {
        let repository = GRDBCatalogRepository(host: "commit-test", durability: .volatileForTests)
        guard await repository.open(at: scene.databaseURL) == .readWrite else {
            await repository.close()
            throw FixtureFailure(words: "commit could not open")
        }
        let plan = CatalogCommit.Plan(door: .save, items: items, purges: purges, replacements: replacements)
        let outcome = await CatalogCommit.run(plan, on: repository)
        await repository.close()
        return outcome
    }

    func commit(_ records: [VideoRecord], purges: [UUID], replacements: [UUID: UUID]) async throws -> CatalogCommit.Outcome {
        try await commitItems(records.map { CommitScene.item($0) }, purges: purges, replacements: replacements)
    }

    /// Rows standing for `path`: live `files` rows + pending payloads not purged.
    func representedAt(_ path: String) throws -> Int {
        let live: Int? = try scalar("SELECT count(*) FROM files WHERE full_path = ? AND removal_state IS NULL", [path])
        let held: Int? = try scalar("""
            SELECT count(*) FROM pending_rows WHERE json_extract(json, '$.fullPath') = ?
               AND id NOT IN (SELECT id FROM pending_purges)
            """, [path])
        return (live ?? 0) + (held ?? 0)
    }

    func refuseInsert(of id: UUID) async throws {
        try await queue().write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_refuse_\(id.uuidString.replacingOccurrences(of: "-", with: "")) BEFORE INSERT ON files
                WHEN NEW.id = '\(id.uuidString)' BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
                """)
        }
    }
}

@Suite("CatalogCommit — the explicit replacement relation (codex #123)", .serialized)
struct CatalogCommitRelationTests {

    private func base(_ s: CommitScene) async throws -> (a: VideoRecord, path: String, digest: String) {
        let path: String = try #require(try s.scalar("SELECT full_path FROM files WHERE id = ?", [healthyID]))
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        return (try #require(try await s.load().records[healthyID]), path, digest)
    }

    /// An import-era archive copy whose source catalog.sqlite never held:
    /// its insert is refused by `archive_copies_need_source` (the incident).
    private func incidentCopy(of template: VideoRecord, path: String, digest: String) throws -> VideoRecord {
        let r = try FreshRecord.copy(template, path: path)
        r.derivationKind = VideoRecord.archivePromotionDerivationKind
        r.derivedFrom = UUID()
        r.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: 1_792_000_000),
                                        sizeBytes: r.sizeBytes)
        return r
    }

    @Test("F1: a pending predecessor purged beside a refused replacement keeps its pending payload")
    func pendingPredecessorKept() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: path)                        // held: no whole-file hash
        _ = try await s.commit([b], purges: [a.id], replacements: [a.id: b.id])
        #expect(try s.representedAt(path) == 1, "precondition: B is held at the path, A purged with it")
        let c = try FreshRecord.copy(a, path: path)
        FreshRecord.giveDigest(c, digest)
        try await s.refuseInsert(of: c.id)
        let outcome = try await s.commit([c], purges: [b.id], replacements: [b.id: c.id])
        #expect(try s.representedAt(path) == 1, "B's pending payload is NOT tombstoned")
        let tombstoned: Int? = try s.scalar("SELECT count(*) FROM pending_purges WHERE id = ?", [b.id.uuidString])
        #expect(tombstoned == 0)
        #expect(outcome.rows.first?.keptForReplacement == true)
    }

    @Test("F2: on a case-sensitive volume a sibling differing only in case never satisfies the purge")
    func caseSensitiveSiblingDoesNotSatisfyThePurge() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (template, _, digest) = try await base(s)
        try await s.queue().write { db in
            try db.execute(sql: """
                INSERT INTO volumes (volume_uuid, last_name, mount_type, remote_server, case_sensitive)
                VALUES ('\(caseSensitiveVolume)', 'CS', 'apfs', '', 1)
                """)
        }
        let path = "/Volumes/CS/Clips/Reunion.mov"
        let other = "/Volumes/CS/Clips/reunion.mov"
        let a = try FreshRecord.copy(template, path: path)
        a.scanContext.volumeUUID = caseSensitiveVolume
        FreshRecord.giveDigest(a, digest)
        _ = try await s.commit([a], purges: [])
        let b = try FreshRecord.copy(a, path: other)                      // a different, new file: lands
        b.scanContext.volumeUUID = caseSensitiveVolume
        FreshRecord.giveDigest(b, digest)
        let c = try FreshRecord.copy(a, path: path)                       // A's real replacement: refused
        c.scanContext.volumeUUID = caseSensitiveVolume
        FreshRecord.giveDigest(c, digest)
        try await s.refuseInsert(of: c.id)
        _ = try await s.commit([b, c], purges: [a.id], replacements: [a.id: c.id])
        #expect(try s.representedAt(other) == 1, "precondition: B stored at its own path")
        #expect(try s.representedAt(path) == 1, "A keeps the row for /…/Reunion.mov")
    }

    @Test("F3: two ordered snapshots of the replacement, both refused — the old row stays")
    func repeatedSnapshotsKeepTheOldRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: path)
        FreshRecord.giveDigest(b, digest)
        try await s.refuseInsert(of: b.id)
        let first = CommitScene.item(b)
        b.userNotes = "second snapshot"
        let outcome = try await s.commitItems([first, CommitScene.item(b)], purges: [a.id], replacements: [a.id: b.id])
        #expect(try s.representedAt(path) == 1)
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil)
        #expect(outcome.rows.first?.keptForReplacement == true)
    }

    @Test("F3 control: of two ordered snapshots one lands — the purge stands")
    func oneOfTwoSnapshotsLanding() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: path)
        FreshRecord.giveDigest(b, digest)
        let first = CommitScene.item(b)
        b.userNotes = "second snapshot"
        let outcome = try await s.commitItems([first, CommitScene.item(b)], purges: [a.id], replacements: [a.id: b.id])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        let live: String? = try s.scalar("SELECT id FROM files WHERE full_path = ? AND removal_state IS NULL", [path])
        #expect(live == b.id.uuidString)
        let notes: String? = try s.scalar("SELECT json_extract(value_json, '$') FROM row_knowledge WHERE file_id = ? AND field = 'userNotes' ORDER BY rowid DESC LIMIT 1", [b.id.uuidString])
        #expect(notes == "second snapshot", "snapshots ran in order")
    }

    /// The incident's mix, in ONE generation, in the shapes the path-paired
    /// design (f59f6d841) could not see (codex #124 finding 3): half of every
    /// group's predecessors are PENDING rows (held, no hash — no live path to
    /// pair on), and every refused replacement is sent as TWO snapshots
    /// (repeated snapshots were never paired). Groups of 100: written · held
    /// · refused by the real `archive_copies_need_source` trigger.
    @Test("INCIDENT: one generation, 100 written + 100 held + 100 REAL-trigger refusals, pending predecessors, repeated snapshots — zero rows lost")
    func incidentShapeLosesNothing() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (template, _, digest) = try await base(s)
        let n = 100
        var olds: [VideoRecord] = []
        for i in 0..<(3 * n) {
            let r = try FreshRecord.copy(template, path: "/Volumes/Fixture/FamilyArchive/30_Video/m\(i).mkv")
            if (i / 3) % 2 == 0 { FreshRecord.giveDigest(r, digest) }      // live row; else a pending predecessor
            olds.append(r)
        }
        _ = try await s.commit(olds, purges: [])
        let pendingOlds: Int? = try s.scalar("SELECT count(*) FROM pending_rows")
        #expect(pendingOlds == 3 * n / 2, "precondition: half the predecessors are pending rows")
        var items: [CatalogCommit.Item] = []
        var repeats: [CatalogCommit.Item] = []
        var relation: [UUID: UUID] = [:]
        var writtenIDs = Set<UUID>(), heldIDs = Set<UUID>(), refusedIDs = Set<UUID>()
        for (i, old) in olds.enumerated() {
            let f: VideoRecord
            switch i % 3 {
            case 0:
                f = try FreshRecord.copy(old, path: old.fullPath); FreshRecord.giveDigest(f, digest)
                writtenIDs.insert(f.id)
            case 1:
                f = try FreshRecord.copy(old, path: old.fullPath)
                heldIDs.insert(f.id)
            default:
                f = try incidentCopy(of: old, path: old.fullPath, digest: digest)
                refusedIDs.insert(f.id)
            }
            items.append(CommitScene.item(f))
            if i % 3 == 2 {
                f.userNotes = "second snapshot"
                repeats.append(CommitScene.item(f))
            }
            relation[old.id] = f.id
        }
        let outcome = try await s.commitItems(items + repeats, purges: olds.map(\.id), replacements: relation)

        let lost = try olds.filter { try s.representedAt($0.fullPath) != 1 }
        #expect(lost.isEmpty, "\(lost.count) paths lost their catalog row (or doubled)")
        let purgeRows = Array(outcome.rows.prefix(olds.count))
        let itemRows = Array(outcome.rows.dropFirst(olds.count))
        #expect(itemRows.count == 4 * n)
        let reason = "an archive copy names its source"

        let written = itemRows.filter { if case .written = $0.landing { return true }; return false }
        #expect(written.count == n, "exactly 100 replacements written")
        #expect(Set(written.map(\.id)) == writtenIDs)
        let held = itemRows.filter { if case .deferred = $0.landing { return $0.heldPending }; return false }
        #expect(held.count == n, "exactly 100 replacements held for their hash")
        #expect(Set(held.map(\.id)) == heldIDs)
        let refused = itemRows.filter { if case .refused(let w) = $0.landing { return w.contains(reason) }; return false }
        #expect(refused.count == 2 * n, "both snapshots of each of the 100 refused replacements are refused by the trigger")
        #expect(Set(refused.map(\.id)) == refusedIDs)

        let kept = purgeRows.filter(\.keptForReplacement)
        #expect(kept.count == n, "exactly the 100 refused replacements kept their old rows")
        #expect(Set(kept.map(\.id)) == Set(olds.enumerated().filter { $0.offset % 3 == 2 }.map(\.element.id)))
        #expect(kept.allSatisfy { if case .refused(let w) = $0.landing { return w.contains(reason) }; return false },
                "every kept purge names the trigger's reason")
        #expect(purgeRows.filter { $0.landing == .removed(.purged(revision: 1)) }.count == n,
                "the live predecessors of written and held replacements are purged")
        #expect(purgeRows.filter { $0.landing == .removed(.pendingPurged) }.count == n,
                "the pending predecessors of written and held replacements are tombstoned")
        #expect(outcome.isCommitted)
    }

    // MARK: - codex #124 finding 1: the replacement must END stored

    @Test("#124 F1: the replacement's live snapshot then its purge snapshot — the old row stays, the pair is refused")
    func replacementPurgedLaterInTheGroupKeepsTheOldRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: path)
        FreshRecord.giveDigest(b, digest)
        let live = CommitScene.item(b)
        b.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_300_000), reason: .purged)
        b.removalRevision = 1
        let outcome = try await s.commitItems([live, CommitScene.item(b)], purges: [a.id], replacements: [a.id: b.id])
        #expect(try s.representedAt(path) == 1, "the file keeps a catalog row")
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil, "and it is A's, live")
        #expect(outcome.rows.first?.keptForReplacement == true)
        let bRows: Int? = try s.scalar("SELECT count(*) FROM files WHERE id = ?", [b.id.uuidString])
        #expect(bRows == 0, "B's snapshots were undone with the purge")
        #expect(outcome.rows.dropFirst().allSatisfy { if case .refused = $0.landing { return true }; return false },
                "B's rows are not reported stored (the app keeps them changed)")
    }

    @Test("#124 F1: an already-purged replacement sent unchanged never lets the old row go")
    func alreadyPurgedReplacementUnchangedKeepsTheOldRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: "/Volumes/Fixture/Clips/elsewhere.mov")
        FreshRecord.giveDigest(b, digest)
        _ = try await s.commit([b], purges: [])
        b.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_300_000), reason: .purged)
        b.removalRevision = 1
        _ = try await s.commit([b], purges: [])
        let bState: String? = try s.scalar("SELECT removal_reason FROM files WHERE id = ?", [b.id.uuidString])
        #expect(bState == CatalogRow.purgeReason, "precondition: B's stored row carries the purge marker")
        let outcome = try await s.commit([b], purges: [a.id], replacements: [a.id: b.id])
        #expect(try s.representedAt(path) == 1, "A keeps the row for its file")
        #expect(outcome.rows.first?.keptForReplacement == true)
    }

    @Test("#124 F1 control: a replacement that ends In the Trash is still the file's row — the purge stands")
    func replacementEndingInTrashLetsThePurgeStand() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: path)
        FreshRecord.giveDigest(b, digest)
        let live = CommitScene.item(b)
        b.removal = .inTrash(movedAt: Date(timeIntervalSince1970: 1_790_300_000), trashPath: nil, reason: .catalogTrash)
        b.lifecycleStage = .trashed
        b.removalRevision = 1
        let outcome = try await s.commitItems([live, CommitScene.item(b)], purges: [a.id], replacements: [a.id: b.id])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        #expect(outcome.rows.last?.landing.landed == true, "the Trash snapshot lands")
        let bState: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [b.id.uuidString])
        #expect(bState == CatalogDDL.RemovalState.inTrash.rawValue, "B is stored, In the Trash")
    }

    @Test("NOT-IN-COMMIT: a replacement absent from this commit and not stored keeps the old row")
    func replacementAbsentAndUnstoredKeeps() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, path, _) = try await base(s)
        let outcome = try await s.commit([], purges: [a.id], replacements: [a.id: UUID()])
        #expect(try s.representedAt(path) == 1)
        #expect(outcome.rows.first?.keptForReplacement == true)
    }

    @Test("NOT-IN-COMMIT: a replacement the store already holds lets the purge stand alone")
    func replacementAlreadyStoredPurges() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (a, _, digest) = try await base(s)
        let b = try FreshRecord.copy(a, path: "/Volumes/Fixture/Clips/renamed.mov")
        FreshRecord.giveDigest(b, digest)
        _ = try await s.commit([b], purges: [])
        let outcome = try await s.commit([], purges: [a.id], replacements: [a.id: b.id])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
    }
}
