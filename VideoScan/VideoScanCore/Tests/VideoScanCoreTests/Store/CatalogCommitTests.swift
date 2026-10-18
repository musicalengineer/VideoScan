// CatalogCommitTests.swift
// The write side of the cutover (B2): a record edited in memory is written
// back to catalog.sqlite through ONE `repository.write`, and a reload gives
// it back — and nothing else moved.
//   LOGIC     — the live round trip: import the poisoned fixture, load, edit
//               a star, a date, a tag, a disposition, trash a row, set
//               derivedFrom on one, commit, reopen, load: the edits are there,
//               every other row's DTO is unchanged, generation_history has
//               one row per commit naming its door; an unchanged commit
//               writes nothing; the copies' conflict survives an unrelated
//               edit; an untouched unverified value stays unverified; a
//               Combine output keeps its link; a record with no whole-file
//               hash is deferred with words; the designation guard holds.
//   ISOLATION — a read-only store refuses with its words and nothing moves;
//               an injected trigger refusal refuses ONE row (its neighbours
//               land), and alone it leaves the database unchanged.
//   TRUTH     — P0 facts (the marker, the audit stamp, the fixity, the
//               archive copy) survive an edit + commit + reload.
//
// Lives under Tests/…/Store/ because it reads the database with a plain
// GRDB queue (the sensor allows `import GRDB` only here and in Sources/…/Store/).
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitRoundTripTests · CatalogCommitIsolationTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

// MARK: - Support

struct CommitScene {
    let scene: ImporterScene

    static func make(healthyRows: Int = 0) async throws -> CommitScene {
        let scene = try ImporterScene.make(healthyRows: healthyRows)
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        return CommitScene(scene: scene)
    }

    func remove() { scene.remove() }

    func load() async throws -> LoadedCatalog { try await LoadedCatalog.load(scene) }

    static func item(_ record: VideoRecord) -> CatalogCommit.Item {
        let snapshot = VideoRecordDTO(record)
        return CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot))
    }

    /// Open, commit `records` as `door`, close.
    func commit(_ records: [VideoRecord], door: CatalogWriter = .save,
                designation: CatalogCommit.Designation = .leave) async throws -> CatalogCommit.Outcome {
        let repository = GRDBCatalogRepository(host: "commit-test", durability: .volatileForTests)
        let opened = await repository.open(at: scene.databaseURL)
        guard opened == .readWrite else {
            await repository.close()
            throw FixtureFailure(words: "commit could not open: \(opened)")
        }
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: door, items: records.map(Self.item), designation: designation),
                                              on: repository)
        await repository.close()
        return outcome
    }

    func queue() throws -> DatabaseQueue { try DatabaseQueue(path: scene.databaseURL.path) }

    func scalar<T: DatabaseValueConvertible>(_ sql: String, _ arguments: StatementArguments = []) throws -> T? {
        try queue().read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    func generation() throws -> Int { try scalar("SELECT generation FROM generations WHERE id = 1") ?? -1 }

    func writers(after generation: Int) throws -> [String] {
        try queue().read { db in
            try String.fetchAll(db, sql: "SELECT writer FROM generation_history WHERE generation > ? ORDER BY generation", arguments: [generation])
        }
    }
}

extension CatalogCommit.Outcome {
    var rows: [CatalogCommit.RowResult] {
        switch self {
        case .committed(_, let rows), .nothingWritten(let rows), .refused(_, let rows): return rows
        case .generationMismatch: return []
        }
    }

    var isCommitted: Bool {
        if case .committed = self { return true }
        return false
    }

    func landing(_ id: String) -> CatalogCommit.Landing? {
        rows.first { $0.id.uuidString == id }?.landing
    }
}

private let healthyID = PoisonedCatalogFixture.id(.healthy)
private let staleID = PoisonedCatalogFixture.id(.stalePrint)
private let tombstonedID = PoisonedCatalogFixture.id(.tombstonedWithDigest)
private let conflictA = PoisonedCatalogFixture.id(.curatedConflictA)
private let conflictB = PoisonedCatalogFixture.id(.curatedConflictB)

// MARK: - Round trip

@Suite("CatalogCommitRoundTrip — edit, commit, reopen, load: the edits are there and nothing else moved", .serialized)
struct CatalogCommitRoundTripTests {

    @Test("star, date, tag, disposition, trash, derivedFrom: committed, reloaded, and every other row unchanged")
    func liveRoundTrip() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let before = try await s.load()
        let start = try s.generation()
        let healthy = try #require(before.records[healthyID])
        healthy.starRating = 2
        healthy.userDate = "1987-07"
        healthy.userDateConfidence = "known"
        healthy.tags = ["Family Reunion"]
        healthy.mediaDisposition = .important
        let stale = try #require(before.records[staleID])
        stale.removal = .inTrash(movedAt: Date(timeIntervalSince1970: 1_790_100_000), trashPath: "/Volumes/Fixture/.Trashes/501/s.mov",
                                 reason: RemovalReason(rawValue: "catalogTrash"))
        stale.removalRevision += 1
        stale.lifecycleStage = .trashed
        let parent = UUID()
        let conflictRecord = try #require(before.records[conflictA])
        conflictRecord.derivedFrom = parent
        conflictRecord.derivationKind = "trim"
        conflictRecord.trimInSeconds = 1
        conflictRecord.trimOutSeconds = 5

        let outcome = try await s.commit([healthy, stale, conflictRecord])
        #expect(outcome.isCommitted)
        #expect(outcome.landing(healthyID)?.landed == true)
        #expect(outcome.landing(staleID)?.landed == true)
        #expect(outcome.landing(conflictA)?.landed == true)

        let after = try await s.load()
        let h = try #require(after.records[healthyID])
        #expect(h.starRating == 2)
        #expect(h.userDate == "1987-07")
        #expect(h.userDateConfidence == "known")
        #expect(h.tags == ["Family Reunion"])
        #expect(h.mediaDisposition == .important)
        let t = try #require(after.records[staleID])
        #expect(t.removal?.state == .inTrash)
        #expect(t.lifecycleStage == .trashed)
        let tombstones: Int? = try s.scalar("SELECT count(*) FROM tombstones WHERE file_id = ? AND door = 'app:save'", [staleID])
        #expect(tombstones == 1)
        let c = try #require(after.records[conflictA])
        #expect(c.derivedFrom == parent)
        #expect(c.derivationKind == "trim")
        #expect(c.trimOutSeconds == 5)
        // Every row nobody touched: its DTO is what it was.
        for id in before.records.keys where ![healthyID, staleID, conflictA].contains(id) {
            #expect(KeptFields.normalized(try before.dto(id)) == KeptFields.normalized(try after.dto(id)), Comment(rawValue: id))
        }
        #expect(try s.writers(after: start) == ["save"])
    }

    @Test("generation_history: one row per commit, each naming its door")
    func oneHistoryRowPerCommit() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let start = try s.generation()
        let healthy = try #require(loaded.records[healthyID])
        healthy.starRating = 1
        _ = try await s.commit([healthy], door: .save)
        healthy.userNotes = "the lake house"
        _ = try await s.commit([healthy], door: .quit)
        healthy.tags = ["Gold"]
        _ = try await s.commit([healthy], door: .acknowledged)
        #expect(try s.writers(after: start) == ["save", "quit", "acknowledged"])
        let evidence: Int? = try s.scalar("SELECT count(*) FROM row_knowledge WHERE file_id = ? AND source GLOB 'app:*'", [healthyID])
        #expect(evidence == 3)
    }

    @Test("an unchanged record writes nothing and advances no generation")
    func unchangedWritesNothing() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let start = try s.generation()
        let outcome = try await s.commit(Array(loaded.records.values))
        #expect(outcome == .nothingWritten(rows: outcome.rows))
        #expect(outcome.rows.allSatisfy { $0.landing == .unchanged })
        #expect(try s.generation() == start)
    }

    @Test("an unrelated edit on one conflicting copy leaves the copies' conflict in place")
    func conflictSurvivesUnrelatedEdit() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[conflictA])
        a.setAsideReason = "damaged"
        let outcome = try await s.commit([a])
        #expect(outcome.isCommitted)
        let conflicts: Int? = try s.scalar("SELECT count(*) FROM stars WHERE conflict = 1")
        #expect(conflicts == 1)
        let after = try await s.load()
        #expect(after.records[conflictB]?.starRating == 0)
        #expect(after.records[conflictA]?.setAsideReason == "damaged")
    }

    @Test("a person's star on one copy resolves the conflict for every copy of that content")
    func personResolvesConflict() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[conflictA])
        a.starRating = 3
        let outcome = try await s.commit([a])
        #expect(outcome.landing(conflictA) == .written(curated: [.starRating], notes: []))
        let after = try await s.load()
        #expect(after.records[conflictB]?.starRating == 3)
    }

    @Test("an untouched unverified caption stays unverified after an edit beside it; a changed caption is written bound")
    func derivedProvenance() async throws {
        let s = try await CommitScene.make(healthyRows: 1); defer { s.remove() }
        let loaded = try await s.load()
        let bulkID = PoisonedCatalogFixture.bulkID(0)          // imported with one caption (unverified)
        let h = try #require(loaded.records[bulkID])
        #expect(h.sceneCaptions.count == 1)
        h.userNotes = "a note beside the caption"
        _ = try await s.commit([h])
        let boundAfterEdit: Int? = try s.scalar("SELECT count(*) FROM captions")
        #expect(boundAfterEdit == 0)
        #expect(try await s.load().records[bulkID]?.sceneCaptions.first?.text == "bulk caption 0")
        h.sceneCaptions = [SceneCaption(timestamp: 2, text: "a canoe")]
        h.sceneCaptionModel = "qwen2.5-vl"
        h.sceneCaptionDate = Date(timeIntervalSince1970: 1_790_200_000)
        let outcome = try await s.commit([h])
        #expect(outcome.isCommitted)
        let bound: Int? = try s.scalar("SELECT count(*) FROM captions WHERE text = 'a canoe'")
        #expect(bound == 1)
        let after = try await s.load()
        #expect(after.records[bulkID]?.sceneCaptions.first?.text == "a canoe")
        #expect(after.records[bulkID]?.sceneCaptionModel == "qwen2.5-vl")
    }

    @Test("the pair confidence and a Combine output's link round-trip (import and commit)")
    func pairLinkRoundTrips() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        #expect(loaded.records[staleID]?.pairConfidence == .high)
        let h = try #require(loaded.records[healthyID])
        let source = UUID()
        h.combinedFromPairID = source
        _ = try await s.commit([h])
        let after = try await s.load()
        #expect(after.records[healthyID]?.combinedFromPairID == source)
        #expect(after.records[staleID]?.pairConfidence == .high)
    }

    @Test("a record with no whole-file hash is deferred with words; nothing is written")
    func noDigestIsDeferred() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let fresh = VideoRecord(id: UUID())
        fresh.filename = "new.mov"
        fresh.fullPath = "/Volumes/Fixture/New/new.mov"
        let start = try s.generation()
        let outcome = try await s.commit([fresh])
        #expect(outcome.landing(fresh.id.uuidString) == .deferred(CatalogCommitWords.noDigest))
        #expect(try s.generation() == start)
    }

    @Test("a new record with a whole-file hash is inserted and loads back")
    func newRowIsInserted() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let other = UUID()
        let digest = String(repeating: "e", count: 64)
        let fresh = RichRecord.make(id: UUID(), path: "/Volumes/Fixture/New/rich.mov", digest: digest, sizeBytes: 8_192,
                                    pairWith: other, otherRow: other)
        fresh.archiveFixity = nil       // a new archive copy names a source row the catalog holds
        fresh.archivedAt = nil
        let outcome = try await s.commit([fresh])
        #expect(outcome.landing(fresh.id.uuidString)?.landed == true)
        if case .written(_, let notes) = outcome.landing(fresh.id.uuidString) {
            #expect(notes.isEmpty, Comment(rawValue: notes.joined(separator: "\n")))
        }
        let after = try await s.load()
        let back = try #require(after.records[fresh.id.uuidString])
        // Every kept field class of the new row comes back as it went in —
        // but the pair: its partner is not in this catalog, so the loaded
        // record holds the partner's id unresolved (the encoder writes only a
        // resolved partner). The link itself is checked member by member.
        for c in KeptFields.classes(try CatalogRecordDTO(record: fresh, migrationLoadedAt: 0), try after.dto(fresh.id.uuidString))
        where c.name != "legacy pair ids" {
            #expect(c.equal, Comment(rawValue: c.name))
        }
        #expect(back.pendingPairedWithID == other)
        #expect(back.pairConfidence == .high)
        #expect(back.combinedFromPairID == fresh.combinedFromPairID)
        #expect(back.starRating == 3)
        #expect(back.userNotes == "Donna at the lake")
        #expect(back.derivedFrom == other)
        #expect(back.sceneCaptions.count == 2)
    }

    @Test("the designation: set lands; removed without Clear is refused; removed after Clear lands")
    func designationGuard() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let json = #"{"rootPath":"/Volumes/Archive/Breen_Family_Archive","targetPath":"/Volumes/Archive"}"#
        let set = try await s.commit([], door: .cutover, designation: .current(json: json, clearAuthorized: false))
        #expect(set.isCommitted)
        let stored: String? = try s.scalar("SELECT master_archive FROM catalog_state")
        #expect(stored == json)
        let lost = try await s.commit([], designation: .current(json: nil, clearAuthorized: false))
        #expect(lost == .refused(lost.refusedWords ?? "", rows: []))
        #expect(lost.refusedWords?.contains("GH #167") == true)
        let kept: String? = try s.scalar("SELECT master_archive FROM catalog_state")
        #expect(kept == json)
        let cleared = try await s.commit([], designation: .current(json: nil, clearAuthorized: true))
        #expect(cleared.isCommitted)
        let none: String? = try s.scalar("SELECT master_archive FROM catalog_state")
        #expect(none == nil)
    }

    @Test("TRUTH: the removal marker, the audit stamp and the content fixity survive an edit + commit + reload")
    func p0FactsSurvive() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let t = try #require(loaded.records[tombstonedID])
        let h = try #require(loaded.records[healthyID])
        let markerBefore = t.removal
        let stampBefore = h.auditSeenOn
        let fixityBefore = h.contentFixity
        t.userNotes = "kept in the Trash on purpose"
        h.userNotes = "the dock"
        _ = try await s.commit([t, h])
        let after = try await s.load()
        #expect(after.records[tombstonedID]?.removal == markerBefore)
        #expect(after.records[tombstonedID]?.userNotes == "kept in the Trash on purpose")
        #expect(after.records[healthyID]?.auditSeenOn == stampBefore)
        #expect(after.records[healthyID]?.contentFixity == fixityBefore)
    }

    @Test("a marker that changed twice in one save is refused for that row with words; the other rows land")
    func markerJumpIsRefused() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.removal = .removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_300_000), reason: RemovalReason(rawValue: "test"))
        h.removalRevision += 1
        h.removal = nil
        h.removalRevision += 1
        let other = try #require(loaded.records[conflictB])
        other.userNotes = "still saved"
        let outcome = try await s.commit([h, other])
        #expect(outcome.isCommitted)
        #expect(outcome.landing(healthyID) == .refused(CatalogCommitWords.markerJump(stored: 0, now: 2)))
        #expect(outcome.landing(conflictB)?.landed == true)
    }
}

extension CatalogCommit.Outcome {
    var refusedWords: String? {
        if case .refused(let words, _) = self { return words }
        return nil
    }
}

// MARK: - Isolation

@Suite("CatalogCommitIsolation — a refusal leaves memory dirty and the database as it was", .serialized)
struct CatalogCommitIsolationTests {

    @Test("a read-only store (restored below its high-water) refuses with its words; nothing moves")
    func readOnlyRefuses() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let start = try s.generation()
        try CatalogHighWater.write(start + 5, besideDatabaseAt: s.scene.databaseURL, durability: .fast)
        let h = try #require(loaded.records[healthyID])
        h.starRating = 3
        let repository = GRDBCatalogRepository(host: "commit-test", durability: .volatileForTests)
        let opened = await repository.open(at: s.scene.databaseURL)
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: [CommitScene.item(h)]), on: repository)
        await repository.close()
        if case .readOnly = opened {} else { Issue.record("expected a read-only open, got \(opened)") }
        #expect(outcome.refusedWords?.contains("restoredBelowHighWater") == true)
        #expect(try s.generation() == start)
        let stars: Int? = try s.scalar("SELECT count(*) FROM stars WHERE digest = (SELECT content_digest FROM files WHERE id = ?)", [healthyID])
        #expect(stars == 0)
    }

    @Test("an injected refusal LATE in one row (after its file row and display row) undoes that whole row only; its neighbour lands")
    func injectedRefusalIsOneRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        try await s.queue().write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_injected_refusal BEFORE INSERT ON row_knowledge WHEN NEW.file_id = '\(healthyID)'
                BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
                """)
        }
        let h = try #require(loaded.records[healthyID])
        h.notes = "machine note"
        h.starRating = 2
        let b = try #require(loaded.records[conflictB])
        b.notes = "another machine note"
        let outcome = try await s.commit([h, b])
        #expect(outcome.isCommitted)
        #expect(outcome.landing(healthyID).map { if case .refused(let w) = $0 { return w.contains("injected refusal") } else { return false } } == true)
        #expect(outcome.landing(conflictB)?.landed == true)
        let note: String? = try s.scalar("SELECT machine_notes FROM files WHERE id = ?", [healthyID])
        #expect(note?.isEmpty == true)
        let stars: Int? = try s.scalar("SELECT count(*) FROM stars WHERE digest = (SELECT content_digest FROM files WHERE id = ?)", [healthyID])
        #expect(stars == 0)
        let neighbour: String? = try s.scalar("SELECT machine_notes FROM files WHERE id = ?", [conflictB])
        #expect(neighbour == "another machine note")
    }

    @Test("alone, the refused row leaves the database unchanged: no generation, no evidence row")
    func injectedRefusalAloneChangesNothing() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        try await s.queue().write { db in
            try db.execute(sql: """
                CREATE TRIGGER test_injected_refusal BEFORE INSERT ON stars WHEN NEW.rating = 2
                BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
                """)
        }
        let start = try s.generation()
        let h = try #require(loaded.records[healthyID])
        h.starRating = 2
        let outcome = try await s.commit([h])
        #expect(outcome == .nothingWritten(rows: outcome.rows))
        #expect(try s.generation() == start)
        let evidence: Int? = try s.scalar("SELECT count(*) FROM row_knowledge WHERE source GLOB 'app:*'")
        #expect(evidence == 0)
    }
}
