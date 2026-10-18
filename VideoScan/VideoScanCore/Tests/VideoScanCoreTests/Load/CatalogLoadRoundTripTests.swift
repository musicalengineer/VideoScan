// CatalogLoadRoundTripTests.swift
// The ROUND-TRIP sensor (cutover B1, catalog_cutover_f_prime §8 TRUTH):
// the poisoned fixture's catalog.json → CatalogImporter (commit, temp
// folder) → CatalogLoad.read → a record per `files` row built by the
// record's own decoder over `jsonRow()` → CatalogRecordDTO(record:) equals
// the importer's DTO of the JSON row, class by class, for every main-table
// shape; quarantined shapes do NOT become records; the two copies whose
// curated values disagree load with those fields EMPTY; a row with all 129
// keys set round-trips every class but the two pair fields the importer
// does not keep (pinned, so a fix flips the test). SCALE: 100k rows load
// within a load-aware budget.
//
// Suites (filter by SUITE): CatalogLoadRoundTripTests · CatalogLoadScaleTests

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogLoadRoundTrip — import, load, and the DTO of each loaded record is the DTO of its JSON row", .serialized)
struct CatalogLoadRoundTripTests {

    typealias Shape = PoisonedCatalogFixture.Shape

    private static func importAndLoad(_ scene: ImporterScene) async throws -> LoadedCatalog {
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        return try await LoadedCatalog.load(scene)
    }

    @Test("every main-table shape (healthy, tombstoned, stale print): every kept field class round-trips")
    func everyMainShapeRoundTrips() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let loaded = try await Self.importAndLoad(scene)
        for shape in [Shape.healthy, .tombstonedWithDigest, .stalePrint] {
            let ordinal = try #require(scene.fixture.ordinals(of: shape).first)
            let original = try importedDTO(scene, ordinal: ordinal)
            let back = try loaded.dto(PoisonedCatalogFixture.id(shape))
            for c in KeptFields.classes(original, back) where c.name != "legacy pair ids" {
                #expect(c.equal, "\(shape.rawValue): \(c.name)")
            }
        }
    }

    @Test("the pair ids round-trip; the pair CONFIDENCE does not (the importer keeps only the ids — pinned)")
    func pairIDsRoundTripConfidenceDoesNot() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let loaded = try await Self.importAndLoad(scene)
        let back = try loaded.dto(PoisonedCatalogFixture.id(.stalePrint))
        #expect(back.legacyPairIDs?.pairGroupID == PoisonedCatalogFixture.pairGroupID)
        #expect(back.legacyPairIDs?.pairedWithID == PoisonedCatalogFixture.id(.healthy))
        #expect(back.legacyPairIDs?.pairConfidence == nil, "catalog.json said High; legacy_pair_ids has no column for it")
    }

    @Test("quarantined shapes never become records; the open quarantine is counted")
    func quarantineIsNotRecords() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let loaded = try await Self.importAndLoad(scene)
        let quarantined = Shape.allCases.filter { PoisonedCatalogFixture.expected($0).reason != nil }
        for shape in quarantined {
            #expect(loaded.records[PoisonedCatalogFixture.id(shape)] == nil, Comment(rawValue: shape.rawValue))
        }
        #expect(loaded.records.count == 5)
        #expect(loaded.snapshot.counts.quarantineOpen == 12)
        #expect(loaded.snapshot.counts.files == 5)
    }

    @Test("two copies that disagree on stars and date load with both fields EMPTY; everything else round-trips; conflicts are counted")
    func conflictingCopiesLoadEmpty() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let loaded = try await Self.importAndLoad(scene)
        let curatedClasses: Set<String> = ["curated (§10b)", "curated field list", "knowledge sources"]
        for shape in [Shape.curatedConflictA, .curatedConflictB] {
            let record = try #require(loaded.records[PoisonedCatalogFixture.id(shape)])
            #expect(record.starRating == 0, Comment(rawValue: shape.rawValue))
            #expect(record.userDate == nil, Comment(rawValue: shape.rawValue))
            #expect(record.userDateConfidence == nil, Comment(rawValue: shape.rawValue))
            let ordinal = try #require(scene.fixture.ordinals(of: shape).first)
            for c in KeptFields.classes(try importedDTO(scene, ordinal: ordinal), try loaded.dto(record.id.uuidString))
            where !curatedClasses.contains(c.name) {
                #expect(c.equal, "\(shape.rawValue): \(c.name)")
            }
        }
        #expect(loaded.snapshot.counts.conflicts == 2, "stars + user_dates on the shared digest")
        let row = try #require(loaded.snapshot.rows.first { $0.file.id == PoisonedCatalogFixture.id(.curatedConflictA) })
        #expect(row.shown.conflicts == [.starRating, .userDate])
    }

    @Test("the display pass runs once: the first load fills the tables at one new generation, the second finds them filled")
    func displayPassRunsOnce() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let first = try await Self.importAndLoad(scene)
        guard case .filled(let rows, let conflicts, let unreadable, _) = first.snapshot.displayPass else {
            Issue.record("first load: \(first.snapshot.displayPass)"); return
        }
        #expect(rows == 3, "deadLink's star (its row is quarantined; the value waits on its digest) + the shared digest's stars and date")
        #expect(conflicts == 2)
        #expect(unreadable == 0)
        let second = try await LoadedCatalog.load(scene)
        #expect(second.snapshot.displayPass == .alreadyFilled)
        #expect(second.snapshot.generation == first.snapshot.generation)
    }

    @Test("a row with all 129 keys set: every kept class round-trips except the pair confidence and combined-from id (pinned)")
    func theRichRowRoundTrips() async throws {
        let scene = try ImporterScene.make(); defer { scene.remove() }
        let id = try #require(UUID(uuidString: PoisonedCatalogFixture.id(.healthy)))
        let rich = RichRecord.make(id: id, path: PoisonedCatalogFixture.path(.healthy),
                                   digest: PoisonedCatalogFixture.digest(Shape.healthy.rawValue),
                                   sizeBytes: PoisonedCatalogFixture.sizeBytes,
                                   pairWith: try #require(UUID(uuidString: PoisonedCatalogFixture.id(.stalePrint))),
                                   otherRow: try #require(UUID(uuidString: PoisonedCatalogFixture.id(.curatedConflictA))))
        let row = try #require(try AppCatalogCoding.row(rich).objectValue)
        try scene.replaceRow(.healthy) { $0 = row }
        let loaded = try await Self.importAndLoad(scene)
        let ordinal = try #require(scene.fixture.ordinals(of: .healthy).first)
        let original = try importedDTO(scene, ordinal: ordinal)
        let back = try loaded.dto(id.uuidString)
        for c in KeptFields.classes(original, back) where c.name != "legacy pair ids" {
            #expect(c.equal, Comment(rawValue: c.name))
        }
        #expect(back.legacyPairIDs?.pairedWithID == original.legacyPairIDs?.pairedWithID)
        #expect(back.legacyPairIDs?.pairGroupID == original.legacyPairIDs?.pairGroupID)
        #expect(back.legacyPairIDs?.pairConfidence == nil, "not kept by the importer: Correlate re-derives it")
        #expect(back.legacyPairIDs?.combinedFromPairID == nil, "not kept by the importer: a Combine output loses its link")
        let record = try #require(loaded.records[id.uuidString])
        #expect(record.derivedProvenanceUnverified == false, "the flag is the app's to set from the row's count")
        let loadedRow = try #require(loaded.snapshot.rows.first { $0.file.id == id.uuidString })
        #expect(loadedRow.unverifiedDerived == 16)
    }
}
