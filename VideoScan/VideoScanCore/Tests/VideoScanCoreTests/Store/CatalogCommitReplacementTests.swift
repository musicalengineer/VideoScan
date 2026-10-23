// CatalogCommitReplacementTests.swift
// P0 2026-10-22 — a purge never lands when the record that replaces it is
// not stored. At 18:05:37 a rescan of /Volumes/FamilyArchive re-minted 644
// records under new ids and asked the store to purge the 641 old ones. The
// commit (generation 681) purged all 641 FIRST, on their own, then refused
// 95 replacements — archive copies whose `archive_copies` row named a
// source the store did not hold (`archive_copies_need_source`). 95 archived
// Masters were left with NO live catalog row, their files on disk.
//
//   LOGIC     a replacement the store refuses (an injected refusal, and the
//             exact incident trigger) leaves the old row LIVE and reports
//             the purge as refused; a replacement that lands, or is held
//             for its hash, still lets the purge land (no regression); a
//             purge with no replacement at its path lands as before.
//   SCALE     2,000 replaced rows, every replacement refused: 0 purged, all
//             2,000 live, within a time budget (the pairing is one indexed
//             read per purge).
// Under Tests/…/Store/ because it reads the database with GRDB.
//
// Suites (filter by SUITE): CatalogCommitReplacementTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)

@Suite("CatalogCommit — a purge never lands when its replacement is not stored (P0 2026-10-22)", .serialized)
struct CatalogCommitReplacementTests {

    /// The stored healthy row's path and digest, and a fresh record at the
    /// SAME path under a new id carrying that digest (a rescan's re-seen record).
    private func reseen(_ s: CommitScene) async throws -> (fresh: VideoRecord, path: String, digest: String) {
        let path: String = try #require(try s.scalar("SELECT full_path FROM files WHERE id = ?", [healthyID]))
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        let loaded = try await s.load()
        let fresh = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: path)
        FreshRecord.giveDigest(fresh, digest)
        return (fresh, path, digest)
    }

    private func liveRows(_ s: CommitScene, path: String) throws -> Int? {
        try s.scalar("SELECT count(*) FROM files WHERE full_path = ? AND removal_state IS NULL", [path])
    }

    @Test("a refused replacement keeps the old row live and the purge is reported refused")
    func refusedReplacementKeepsOldRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (fresh, path, _) = try await reseen(s)
        try await s.queue().write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_refuse_reseen BEFORE INSERT ON files WHEN NEW.id = '\(fresh.id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected refusal of the replacement'); END
                """)
        }
        let outcome = try await s.commit([fresh], purges: [try #require(UUID(uuidString: healthyID))],
                                          replacements: [try #require(UUID(uuidString: healthyID)): fresh.id])
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil)
        #expect(try liveRows(s, path: path) == 1)
        let purgeLanding = outcome.rows.first?.landing
        #expect({ if case .refused = purgeLanding { return true }; return false }())
        #expect(outcome.rows.first?.keptForReplacement == true, "the app is told never to re-send this purge alone")
        #expect(outcome.landing(fresh.id.uuidString).map { if case .refused = $0 { return true }; return false } == true)
    }

    @Test("the incident: an archive copy whose source the store does not hold is refused, and its old row stays live")
    func archiveCopyWithoutStoredSourceKeepsOldRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (fresh, path, digest) = try await reseen(s)
        fresh.derivationKind = VideoRecord.archivePromotionDerivationKind
        fresh.derivedFrom = UUID()   // a source row catalog.sqlite never held (quarantined at import)
        fresh.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: 1_792_000_000),
                                            sizeBytes: fresh.sizeBytes)
        let outcome = try await s.commit([fresh], purges: [try #require(UUID(uuidString: healthyID))],
                                          replacements: [try #require(UUID(uuidString: healthyID)): fresh.id])
        let freshLanding = outcome.landing(fresh.id.uuidString)
        #expect(freshLanding.map { if case .refused(let w) = $0 { return w.contains("an archive copy names its source") }; return false } == true,
                "refused by archive_copies_need_source, nothing else")
        let kept = outcome.rows.first
        #expect(kept?.keptForReplacement == true)
        #expect(kept.map { if case .refused(let w) = $0.landing { return w.contains("an archive copy names its source") }; return false } == true)
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil)
        #expect(try liveRows(s, path: path) == 1)
        #expect(try await s.load().records[healthyID] != nil)
    }

    @Test("a replacement that lands still purges the old row (rescan refresh unchanged)")
    func landedReplacementPurges() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let (fresh, path, _) = try await reseen(s)
        let outcome = try await s.commit([fresh], purges: [try #require(UUID(uuidString: healthyID))],
                                          replacements: [try #require(UUID(uuidString: healthyID)): fresh.id])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        #expect(outcome.rows.first?.keptForReplacement == false)
        #expect(outcome.landing(fresh.id.uuidString)?.landed == true)
        let live: String? = try s.scalar("SELECT id FROM files WHERE full_path = ? AND removal_state IS NULL", [path])
        #expect(live == fresh.id.uuidString)
    }

    @Test("a replacement HELD for its hash still purges the old row (pending survives a relaunch)")
    func heldReplacementPurges() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let path: String = try #require(try s.scalar("SELECT full_path FROM files WHERE id = ?", [healthyID]))
        let loaded = try await s.load()
        let fresh = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: path)   // no digest
        let outcome = try await s.commit([fresh], purges: [try #require(UUID(uuidString: healthyID))],
                                          replacements: [try #require(UUID(uuidString: healthyID)): fresh.id])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        let held: Int? = try s.scalar("SELECT count(*) FROM pending_rows WHERE id = ?", [fresh.id.uuidString])
        #expect(held == 1)
    }

    @Test("a purge with no replacement at its path lands as before, beside a refused unrelated row")
    func lonePurgeLands() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let other = try FreshRecord.copy(try #require(loaded.records[healthyID]), path: "/Volumes/Fixture/Elsewhere/x.mov")
        FreshRecord.giveDigest(other, "not-a-digest")   // refused: not a whole-file digest
        let outcome = try await s.commit([other], purges: [try #require(UUID(uuidString: healthyID))])
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
    }

    @Test("sensor (source): the commit body groups each purge with its explicit replacement — no path matching")
    func bodyPairsPurgesWithReplacements() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/Commit/CatalogCommitBody.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "func run() throws {"))
        let end = try #require(text.range(of: "try settleSets()", range: start.upperBound..<text.endIndex))
        let body = String(text[start.upperBound..<end.lowerBound])
        #expect(body.contains("replacementGroups()"), "run() must group purges with the records that replace them")
        #expect(body.contains("replace(group)"), "a replaced row is purged only together with its replacement")
        #expect(!body.contains("for id in plan.purges {"), "the old unconditional purge loop is back (P0 2026-10-22)")
        #expect(!text.contains("pathKey"), "the replacement is the plan's explicit relation, never a path match (codex #123)")
    }

    @Test("scale: 2,000 replaced rows whose replacements are ALL refused — none purged, within budget")
    func scaleAllRefusedNonePurged() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let count = 2_000
        let template = try #require(try await s.load().records[healthyID])
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        // 2,000 stored rows at their own paths (same content), committed once.
        var stored: [VideoRecord] = []
        for i in 0..<count {
            let rec = try FreshRecord.copy(template, path: "/Volumes/Fixture/Scale/f\(i).mov")
            FreshRecord.giveDigest(rec, digest)
            stored.append(rec)
        }
        _ = try await s.commit(stored, purges: [])
        try await s.queue().write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_refuse_scale BEFORE INSERT ON files WHEN NEW.full_path LIKE '/Volumes/Fixture/Scale/%'
                BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
                """)
        }
        var fresh: [VideoRecord] = []
        for rec in stored {
            let f = try FreshRecord.copy(rec, path: rec.fullPath)
            FreshRecord.giveDigest(f, digest)
            fresh.append(f)
        }
        let clock = ContinuousClock()
        let started = clock.now
        var relation: [UUID: UUID] = [:]
        for (old, new) in zip(stored, fresh) { relation[old.id] = new.id }
        let outcome = try await s.commit(fresh, purges: stored.map(\.id), replacements: relation)
        let elapsed = clock.now - started
        let live: Int? = try s.scalar("SELECT count(*) FROM files WHERE full_path LIKE '/Volumes/Fixture/Scale/%' AND removal_state IS NULL")
        #expect(live == count)
        #expect(outcome.rows.prefix(count).allSatisfy { if case .refused = $0.landing { return true }; return false })
        #expect(elapsed < .seconds(30))
    }
}
