// CatalogCommitArchiveProvenanceTests.swift
// P0 2026-10-22, the ROOT CAUSE. A FamilyArchive rescan re-minted 95
// archived Masters under new ids. Each old row was an import-era archive
// copy (`archive_copies.promoted_by = 'import'`, `source_file_id` NULL —
// its source row was quarantined at import and never stored). The live
// writer (`replaceArchiveCopy`) inserted the replacement's NEW
// `archive_copies` row with a hard-coded `'promote'`, so
// `archive_copies_need_source` refused every one: "an archive copy names
// its source". The app's records never carry `promoted_by` (the DTO mapping
// always says `.import`), so the provenance can only come from the store:
// the row the replacement replaces (the plan's explicit relation).
//
//   LOGIC   a fresh-id replacement of an import-era, NULL-source archive
//           copy lands, keeps `'import'`, and the old row is purged; a
//           replacement of a Promote copy stays `'promote'` and still names
//           the predecessor's source; a brand-new Promote copy with no
//           stored source is STILL refused (the trigger's protection), with
//           or without a replacement relation to a row that is no archive
//           copy.
//   SCALE   100 import-era archive copies replaced in ONE commit: all 100
//           land as 'import', all 100 old rows purged, within budget.
// Under Tests/…/Store/ because it reads the database with GRDB.
//
// Suites (filter by SUITE): CatalogCommitArchiveProvenanceTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)

@Suite("CatalogCommit — a replacement's archive copy keeps the provenance of the row it replaces (P0 2026-10-22)", .serialized)
struct CatalogCommitArchiveProvenanceTests {

    private static let verifiedAt: Int64 = 1_792_000_000

    /// Make the stored row `id` an archive copy as the store holds it.
    private func makeArchiveCopy(_ s: CommitScene, id: String, promotedBy: String, sourceFileID: String?) throws {
        try s.queue().write { db in
            try db.execute(sql: """
                INSERT INTO archive_copies (file_id, source_file_id, source_row_id, archived_at, fixity_verified_at, promoted_by)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, sourceFileID, sourceFileID ?? UUID().uuidString, Self.verifiedAt, Self.verifiedAt, promotedBy])
        }
    }

    /// A rescan's re-seen record: a fresh id at the stored row's path, its
    /// digest, and the archive fixity the merge carries over.
    private func reseen(_ s: CommitScene, id: String) async throws -> VideoRecord {
        let path: String = try #require(try s.scalar("SELECT full_path FROM files WHERE id = ?", [id]))
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [id]))
        let original = try #require(try await s.load().records[id])
        let fresh = try FreshRecord.copy(original, path: path)
        FreshRecord.giveDigest(fresh, digest)
        fresh.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: TimeInterval(Self.verifiedAt)),
                                            sizeBytes: fresh.sizeBytes)
        return fresh
    }

    private func provenance(_ s: CommitScene, _ id: UUID) throws -> (by: String?, source: String?) {
        try s.queue().read { db in
            let row = try Row.fetchOne(db, sql: "SELECT promoted_by, source_file_id FROM archive_copies WHERE file_id = ?",
                                       arguments: [id.uuidString])
            return (row?[0], row?[1])
        }
    }

    private func liveMasters(_ s: CommitScene) throws -> [String] {
        try s.queue().read { db in
            try String.fetchAll(db, sql: "SELECT id FROM files WHERE full_path LIKE '/Volumes/FamilyArchive/Masters/%' AND removal_state IS NULL")
        }
    }

    @Test("the incident: an import-era, NULL-source archive copy replaced under a fresh id lands as 'import' and the old row is purged")
    func importEraReplacementLands() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        try makeArchiveCopy(s, id: healthyID, promotedBy: "import", sourceFileID: nil)
        let fresh = try await reseen(s, id: healthyID)
        let old = try #require(UUID(uuidString: healthyID))
        let outcome = try await s.commit([fresh], purges: [old], replacements: [old: fresh.id])
        let landing = outcome.landing(fresh.id.uuidString)
        #expect(landing?.landed == true, "the replacement is stored, not refused: \(String(describing: landing))")
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        #expect(outcome.rows.first?.keptForReplacement == false)
        let copy = try provenance(s, fresh.id)
        #expect(copy.by == "import", "the replacement keeps the import-era provenance")
        #expect(copy.source == nil)
        #expect(try await s.load().records[fresh.id.uuidString]?.archiveFixity != nil)
    }

    @Test("a Promote copy replaced under a fresh id stays 'promote' and still names the predecessor's source")
    func promoteReplacementKeepsSource() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let source: String = try #require(try s.scalar("SELECT id FROM files WHERE id <> ? ORDER BY id LIMIT 1", [healthyID]))
        try makeArchiveCopy(s, id: healthyID, promotedBy: "promote", sourceFileID: source)
        let fresh = try await reseen(s, id: healthyID)
        fresh.derivedFrom = nil   // the fresh instance lost the link: the store's relation is the truth
        let old = try #require(UUID(uuidString: healthyID))
        let outcome = try await s.commit([fresh], purges: [old], replacements: [old: fresh.id])
        #expect(outcome.landing(fresh.id.uuidString)?.landed == true)
        #expect(outcome.rows.first?.landing == .removed(.purged(revision: 1)))
        let copy = try provenance(s, fresh.id)
        #expect(copy.by == "promote")
        #expect(copy.source == source)
    }

    @Test("a brand-new Promote copy with no stored source is STILL refused (no replacement relation)")
    func newPromoteWithoutSourceRefused() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        let template = try #require(try await s.load().records[healthyID])
        let copy = try FreshRecord.copy(template, path: "/Volumes/Fixture/Archive/new-master.mov")
        FreshRecord.giveDigest(copy, digest)
        copy.derivedFrom = UUID()   // a source catalog.sqlite does not hold
        copy.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: TimeInterval(Self.verifiedAt)),
                                           sizeBytes: copy.sizeBytes)
        let outcome = try await s.commit([copy], purges: [])
        #expect(outcome.landing(copy.id.uuidString).map { if case .refused(let w) = $0 { return w.contains("an archive copy names its source") }; return false } == true,
                "archive_copies_need_source still guards a genuinely new Promote copy")
        let stored: Int? = try s.scalar("SELECT count(*) FROM files WHERE id = ?", [copy.id.uuidString])
        #expect(stored == 0)
    }

    @Test("a replacement of a row that is NO archive copy inherits nothing: a sourceless archive copy is still refused, old row kept")
    func replacementOfPlainRowInheritsNothing() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let fresh = try await reseen(s, id: healthyID)
        fresh.derivedFrom = UUID()
        let old = try #require(UUID(uuidString: healthyID))
        let outcome = try await s.commit([fresh], purges: [old], replacements: [old: fresh.id])
        #expect(outcome.landing(fresh.id.uuidString).map { if case .refused(let w) = $0 { return w.contains("an archive copy names its source") }; return false } == true)
        #expect(outcome.rows.first?.keptForReplacement == true)
        let state: String? = try s.scalar("SELECT removal_state FROM files WHERE id = ?", [healthyID])
        #expect(state == nil)
    }

    @Test("sensor (source): the live archive-copy INSERT takes its provenance from the replaced row, never a bare 'promote' literal")
    func liveInsertHasNoBarePromoteLiteral() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/Store/GRDBCatalogRepository+Live.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(text.range(of: "func replaceArchiveCopy("))
        let end = try #require(text.range(of: "func replaceBackupDestinations(", range: start.upperBound..<text.endIndex))
        let body = String(text[start.upperBound..<end.lowerBound])
        #expect(!body.contains(", 'promote')"), "the hard-coded 'promote' INSERT is back (P0 2026-10-22 root cause)")
        #expect(body.contains("replacing"), "the INSERT must consult the rows the record replaces")
    }

    @Test("scale: 100 import-era archive copies replaced in ONE commit — all land as 'import', all 100 old rows purged, within budget")
    func scaleHundredImportEraReplacements() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let count = 100
        let template = try #require(try await s.load().records[healthyID])
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        var stored: [VideoRecord] = []
        for i in 0..<count {
            let rec = try FreshRecord.copy(template, path: "/Volumes/FamilyArchive/Masters/m\(i).mov")
            FreshRecord.giveDigest(rec, digest)
            stored.append(rec)
        }
        _ = try await s.commit(stored, purges: [])
        for rec in stored { try makeArchiveCopy(s, id: rec.id.uuidString, promotedBy: "import", sourceFileID: nil) }
        var fresh: [VideoRecord] = []
        var relation: [UUID: UUID] = [:]
        for rec in stored {
            let f = try FreshRecord.copy(rec, path: rec.fullPath)
            FreshRecord.giveDigest(f, digest)
            f.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: TimeInterval(Self.verifiedAt)),
                                            sizeBytes: f.sizeBytes)
            fresh.append(f)
            relation[rec.id] = f.id
        }
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = try await s.commit(fresh, purges: stored.map(\.id), replacements: relation)
        let elapsed = clock.now - started
        #expect(outcome.isCommitted)
        #expect(outcome.rows.prefix(count).allSatisfy { $0.landing == .removed(.purged(revision: 1)) && !$0.keptForReplacement },
                "no NOT REMOVED: every old row is purged with its replacement")
        #expect(fresh.allSatisfy { outcome.landing($0.id.uuidString)?.landed == true })
        let live = try liveMasters(s)
        #expect(Set(live) == Set(fresh.map(\.id.uuidString)))
        let imported: Int? = try s.scalar("""
            SELECT count(*) FROM archive_copies ac JOIN files f ON f.id = ac.file_id
             WHERE f.full_path LIKE '/Volumes/FamilyArchive/Masters/%' AND f.removal_state IS NULL
               AND ac.promoted_by = 'import' AND ac.source_file_id IS NULL
            """)
        #expect(imported == count)
        #expect(elapsed < .seconds(30))
    }
}
