// CatalogProvenanceAssertionsTests.swift
// Provenance assertions in catalog.sqlite (schema v1.13, migration
// `v9_provenance_assertions`; CatalogProvenanceAssertionRows.swift,
// GRDBCatalogRepository+ProvenanceAssertions.swift):
//   LOGIC      — an observation lands with its seq; the same (subject, field,
//                value, by, at) twice is ONE row (`.duplicate`); a digest that
//                is not content writes nothing; Rick's 'rejected' vetoes a
//                later machine re-proposal of that value (`.vetoed`, no row)
//                while another value still lands; a later 'confirmed' lifts it.
//   ARCHIVE    — an observation (era.*, ocr.date) lands on an archived
//                content; a name/date field is refused there (rule 3) and
//                lands on a non-archived one.
//   GUARDS     — UPDATE / DELETE refused with the trigger's words; the CHECKs
//                refuse a machine 'confirmed', a 'rick' 'inferred', an inferred
//                row without confidence, a confidence of 1.5, invalid JSON.
//   SUBJECT    — "sha256:<HEX>" and "<hex>" normalise to content.digest's
//                spelling; anything else is nil.
//   VERSION    — a schema-13 database opens as 14 with content intact; a v14
//                file is refused IN WORDS by the gate a v13 build ran (13).
// One condition per #expect. Synthetic digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogProvenanceAssertions")
struct CatalogProvenanceAssertionsTests {

    private static func hex(_ n: Int) -> String { String(format: "%064x", n) }
    static let machine = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return repository
    }

    private func seedContent(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                for n in 1...count {
                    try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [Self.hex(n)])
                }
                return .commit
            }
        }
    }

    static func draft(_ n: Int, field: String = "era.yearRange", value: String = "1991-1995", state: String = "inferred",
                      by: String = machine, at: Int64 = 1_761_990_000, confidence: Double? = 0.6) -> CatalogRow.ProvenanceAssertionDraft {
        CatalogRow.ProvenanceAssertionDraft(subjectKind: "content", subjectID: hex(n), field: field, value: value, state: state,
                                            by: by, at: at, confidence: confidence, evidenceJSON: #"{"window":[0,60]}"#)
    }

    /// Append inside one write; the landings in order.
    private func append(_ repository: GRDBCatalogRepository, _ drafts: [CatalogRow.ProvenanceAssertionDraft]) async throws -> [CatalogRow.ProvenanceAssertionLanding] {
        let box = LandingBox()
        let outcome = await repository.write(as: .ui) { tx in
            for d in drafts { box.append(try tx.appendProvenanceAssertion(d)) }
        }
        guard case .committed = outcome else {
            Issue.record("write: \(outcome)")
            return []
        }
        return box.items
    }

    private func count(_ repository: GRDBCatalogRepository) async throws -> Int {
        try await repository.read { try $0.provenanceAssertionCount() }
    }

    private func refusal(_ fixture: StoreFixture, _ sql: String) -> String? {
        do {
            try DatabaseQueue(path: fixture.url.path).inDatabase { db in try db.execute(sql: sql) }
            return nil
        } catch {
            return ChecksRun.words(error)
        }
    }

    // MARK: - Logic

    @Test func anObservationLandsAndTheSameLineTwiceIsOneRow() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        let first = try await append(repository, [Self.draft(1)])
        guard case .recorded = first.first else {
            Issue.record("expected recorded, got \(first)")
            await repository.close()
            return
        }
        let second = try await append(repository, [Self.draft(1)])
        #expect(second == [.duplicate])
        #expect(try await count(repository) == 1)
        // A different `at` is a different observation.
        let later = try await append(repository, [Self.draft(1, at: 1_761_990_001)])
        #expect(later.count == 1 && later != [.duplicate])
        #expect(try await count(repository) == 2)
        await repository.close()
    }

    @Test func aDigestThatIsNotContentWritesNothing() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = try await open(fixture)
        #expect(try await append(repository, [Self.draft(9)]) == [.contentMissing])
        #expect(try await count(repository) == 0)
        await repository.close()
    }

    @Test func rickRejectingAValueVetoesItsReProposalAndAConfirmLiftsIt() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = try await append(repository, [Self.draft(1, state: "rejected", by: "rick", confidence: nil)])
        let vetoed = try await append(repository, [Self.draft(1, at: 1_761_990_100), Self.draft(1, value: "1980-1985", at: 1_761_990_100)])
        #expect(vetoed.first == .vetoed)
        #expect(vetoed.count == 2 && vetoed[1] != .vetoed, "another value still lands: \(vetoed)")
        #expect(try await count(repository) == 2)
        _ = try await append(repository, [Self.draft(1, state: "confirmed", by: "rick", at: 1_761_990_200, confidence: nil)])
        let lifted = try await append(repository, [Self.draft(1, at: 1_761_990_300)])
        #expect(lifted.count == 1 && lifted != [.vetoed], "Rick's newest decision is 'confirmed': \(lifted)")
        await repository.close()
    }

    // MARK: - Archived contents (rule 3)

    private func markArchived(_ fixture: StoreFixture, _ n: Int) throws {
        // The smallest archived shape: one file row of the content, lifecycle Archived.
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
            try db.execute(sql: """
                INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                   digest_computed_at, digest_source, stream_type, lifecycle, archive_stage, volume_case_sensitive)
                VALUES ('\(String(format: "00000000-0000-0000-0000-%012X", n))', ?, '', '/a/\(n).mov', '/a/\(n).mov', '\(n).mov', 'mov', '/a', 100, 1, 'archiveFixity', 'Video+Audio', 'Archived', 'Archived', 0)
                """, arguments: [Self.hex(n)])
        }
    }

    @Test func anObservationLandsOnAnArchivedContentButANameOrDateDoesNot() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        try markArchived(fixture, 1)
        let repository = try await open(fixture)
        let observations = try await append(repository, [Self.draft(1), Self.draft(1, field: "era.fused"),
                                                          Self.draft(1, field: "era.none", value: "none"), Self.draft(1, field: "ocr.date", value: "1991-06-21")])
        #expect(observations.allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(observations)")
        #expect(try await append(repository, [Self.draft(1, field: "date", value: "1991-06-21")]) == [.archivedNameOrDate])
        #expect(try await append(repository, [Self.draft(1, field: "name", value: "Cape 1991")]) == [.archivedNameOrDate])
        let notArchived = try await append(repository, [Self.draft(2, field: "date", value: "1991-06-21")])
        #expect(notArchived.count == 1 && notArchived != [.archivedNameOrDate])
        await repository.close()
    }

    @Test func theFieldPolicyNamesObservationsAndNamesOrDates() {
        for field in ["era.yearRange", "era.fused", "era.none", "ocr.date"] { #expect(!ProvenanceAssertionFieldPolicy.isNameOrDate(field), "\(field)") }
        #expect(ProvenanceAssertionFieldPolicy.observationFields.contains(EraRecordMapper.noneField))
        for field in ["name", "name.display", "date", "date.recorded", "title", "tapeYear", "digitizedOn"] {
            #expect(ProvenanceAssertionFieldPolicy.isNameOrDate(field), "\(field)")
        }
    }

    // MARK: - Codex #187 (red first)

    @Test("F4: the same (subject, field, value, by, at) with different evidence is a distinct observation; the identical payload is a duplicate")
    func codex187F4DistinctEvidenceIsNotADuplicate() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        var other = Self.draft(1)
        other.evidenceJSON = #"{"window":[60,120]}"#
        let landed = try await append(repository, [Self.draft(1), other, Self.draft(1)])
        #expect(landed.count == 3)
        if landed.count == 3 {
            #expect(landed[1] != .duplicate, "different evidence lands")
            #expect(landed[2] == .duplicate, "the identical payload is a duplicate")
        }
        await repository.close()
    }

    @Test("F6: a file under the designated Master Archive root counts as archived even with Cataloged / None flags")
    func codex187F6ArchiveRootCounts() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
            try db.execute(sql: """
                INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                   digest_computed_at, digest_source, stream_type, lifecycle, archive_stage, volume_case_sensitive)
                VALUES ('00000000-0000-0000-0000-000000000001', ?, '', '/Volumes/Arch/Breen_Family_Archive/1990s/a.mov',
                        '/volumes/arch/breen_family_archive/1990s/a.mov', 'a.mov', 'mov', '/Volumes/Arch/Breen_Family_Archive/1990s',
                        100, 1, 'archiveFixity', 'Video+Audio', 'Cataloged', 'None', 0)
                """, arguments: [Self.hex(1)])
            try db.execute(sql: #"UPDATE catalog_state SET master_archive = '{"rootPath":"/Volumes/Arch/Breen_Family_Archive","targetPath":"/Volumes/Arch","designatedAt":"2026-01-01T00:00:00Z"}' WHERE singleton = 1"#)
        }
        let repository = try await open(fixture)
        #expect(try await append(repository, [Self.draft(1, field: "date", value: "1991-06-21")]) == [.archivedNameOrDate])
        let observation = try await append(repository, [Self.draft(1)])
        #expect(observation.count == 1 && observation != [.archivedNameOrDate], "observations still land")
        await repository.close()
    }

    @Test("F7: a draft the CHECKs refuse is a per-line .storeRefused, not a thrown batch")
    func codex187F7StoreRefusalIsPerLine() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        var bad = Self.draft(1)
        bad.subjectKind = "file"
        let landed = try await append(repository, [bad, Self.draft(1)])
        #expect(landed.count == 2)
        if case .storeRefused(let words)? = landed.first { #expect(words.contains("CHECK")) } else { Issue.record("\(landed)") }
        #expect(try await count(repository) == 1, "the neighbour landed")
        await repository.close()
    }

    // MARK: - Guards

    @Test func theTableIsAppendOnlyAndItsChecksHold() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = try await append(repository, [Self.draft(1)])
        await repository.close()
        let cols = "INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json) VALUES"
        let d = Self.hex(1)
        #expect(refusal(fixture, "UPDATE provenance_assertions SET value = 'x'")?.contains("append-only") == true)
        #expect(refusal(fixture, "DELETE FROM provenance_assertions")?.contains("append-only") == true)
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'confirmed', '\(Self.machine)', 1, 0.5, '{}')") != nil, "only Rick decides")
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'inferred', 'rick', 1, 0.5, '{}')") != nil, "only the machine infers")
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'inferred', '\(Self.machine)', 1, NULL, '{}')") != nil, "inferred needs confidence")
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'inferred', '\(Self.machine)', 1, 1.5, '{}')") != nil, "confidence in [0,1]")
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'inferred', '\(Self.machine)', 1, 0.5, 'not json')") != nil, "evidence is JSON")
        #expect(refusal(fixture, "\(cols) ('file', '\(d)', 'f', 'v', 'inferred', '\(Self.machine)', 1, 0.5, '{}')") != nil, "subject kinds")
        #expect(refusal(fixture, "\(cols) ('content', '\(d)', 'f', 'v', 'inferred', 'bot:x', 1, 0.5, '{}')") != nil, "by is rick or machine:*")
    }

    // MARK: - Subject spelling

    @Test func aDigestInAnySpellingIsContentDigestsSpelling() {
        let lower = Self.hex(0xabc)
        #expect(ProvenanceAssertionSubject.contentID("sha256:" + lower) == lower)
        #expect(ProvenanceAssertionSubject.contentID("SHA256:" + lower.uppercased()) == lower)
        #expect(ProvenanceAssertionSubject.contentID(lower) == lower)
        #expect(ProvenanceAssertionSubject.contentID("sha256:" + lower.dropLast()) == nil)
        #expect(ProvenanceAssertionSubject.contentID("v1:" + lower) == nil)
        #expect(ProvenanceAssertionSubject.contentID(String(repeating: "g", count: 64)) == nil)
    }

    // MARK: - Version

    @Test func aSchemaThirteenDatabaseOpensAsFourteenWithEveryContentRowIntact() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v112 = DatabaseMigrator()
        v112.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.12')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.12', 'create', 0, 0)")
        }
        let later: [(String, [String])] = [
            (CatalogDataSchema.migrationID, CatalogDataSchema.statements),
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
            (CatalogDecisionTablesSchema.migrationID, CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump),
            (CatalogProvenanceRolesSchema.migrationID, CatalogProvenanceRolesSchema.statements + CatalogProvenanceRolesSchema.versionBump),
        ]
        for (id, statements) in later {
            v112.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v112.migrate(queue)
        try queue.inDatabase { db in
            for n in 1...3 {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [Self.hex(n)])
            }
        }
        #expect(try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") } == 13)
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        #expect(try await count(repository) == 0)
        let landed = try await append(repository, [Self.draft(2)])
        #expect(landed.count == 1 && landed != [.contentMissing])
        await repository.close()
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state"),
             try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM content"))
        }
        #expect(after.0 == 14)
        #expect(after.1 == 14)
        #expect(after.2 == 3)
    }

    /// The version gate a v13 build ran (unchanged code since v1.7, with
    /// that build's number) refuses this build's file in words.
    @Test func aFourteenFileIsRefusedInWordsByTheGateAThirteenBuildRan() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let words: String? = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            do {
                try GRDBCatalogRepository.checkSchemaVersion(db, understands: CatalogProvenanceRolesSchema.schemaVersion)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        #expect(words?.contains("schema version 14 is newer than this build understands (13) — open it with a newer VideoScan") == true, "\(words ?? "nil")")
        // And this build accepts it.
        let ok: Bool = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try? GRDBCatalogRepository.checkSchemaVersion(db)) != nil
        }
        #expect(ok)
    }
}

private final class LandingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CatalogRow.ProvenanceAssertionLanding] = []
    func append(_ l: CatalogRow.ProvenanceAssertionLanding) { lock.lock(); storage.append(l); lock.unlock() }
    var items: [CatalogRow.ProvenanceAssertionLanding] { lock.lock(); defer { lock.unlock() }; return storage }
}
