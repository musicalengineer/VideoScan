// CatalogRecordDTOTests.swift
// LOGIC + CONTRACT pins for the importer's record mapping (step D′):
//   * every golden fixture v1–v6 decodes into VideoRecordJSON → DTOs with zero
//     data loss: every key of the fixture row is a typed key with a fate, or
//     is retained in `raw` — proved by RE-ENCODING the DTO and comparing key
//     sets (brief deliverable 1);
//   * the 129 keys and their fates equal contract §a, read from the contract
//     file at test time;
//   * every DDL vocabulary enum equals its CHECK list, read from the DDL file
//     at test time;
//   * the identity, migration, knowledge and derived rules (contract §e, §f).
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Import DTO — golden fixtures v1–v6")
struct CatalogRecordDTOGoldenTests {

    @Test func everyGoldenFixtureDecodesWithTheExpectedHeader() throws {
        for f in ImportGoldenFixtures.all {
            let catalog = try ImportTestSupport.catalog(f.json)
            #expect(catalog.version == f.version, "\(f.name)")
            #expect(catalog.records.count == f.rows, "\(f.name)")
        }
    }

    @Test func absentVersionAndGenerationReadAsOneAndZero() throws {
        let catalog = try ImportTestSupport.catalog(ImportGoldenFixtures.v1)
        #expect(catalog.version == 1)
        #expect(catalog.generation == 0)
    }

    @Test func aNumericSavedAtIsKeptVerbatim() throws {
        let catalog = try ImportTestSupport.catalog(ImportGoldenFixtures.v2NumericSavedAt)
        #expect(catalog.savedAt == CatalogJSONValue.int(0))
    }

    @Test func noGoldenRowHasAnUndecodableOrUnknownKey() throws {
        for f in ImportGoldenFixtures.all where f.name != "v6Poisoned" {
            for r in try ImportTestSupport.catalog(f.json).records {
                #expect(r.undecodable.isEmpty, "\(f.name): \(r.undecodable)")
                #expect(r.unknownKeys.isEmpty, "\(f.name): \(r.unknownKeys)")
            }
        }
    }

    /// Zero data loss: the re-encoded DTO's `raw` carries exactly the fixture
    /// row's keys, with the same values.
    @Test func reEncodedDTOKeepsEveryFixtureKeyAndValue() throws {
        for f in ImportGoldenFixtures.all {
            for r in try ImportTestSupport.catalog(f.json).records {
                let dto = CatalogRecordDTO(record: r, migrationLoadedAt: 0)
                let reencoded = try CatalogJSONValue.of(dto)
                let rawBack = reencoded["raw"]?.objectValue ?? [:]
                #expect(Set(rawBack.keys) == Set(r.raw.keys), "\(f.name)")
                #expect(rawBack == r.raw, "\(f.name)")
            }
        }
    }

    /// Every key a fixture row carries is one of the 129 and has a fate; the
    /// typed keys each landed somewhere in the DTO or are a declared drop.
    @Test func everyFixtureKeyIsATypedKeyWithAFate() throws {
        let known = Set(VideoRecordJSON.Key.allCases.map(\.rawValue))
        for f in ImportGoldenFixtures.all where f.name != "v6Poisoned" {
            for r in try ImportTestSupport.catalog(f.json).records {
                let missing = Set(r.raw.keys).subtracting(known)
                #expect(missing.isEmpty, "\(f.name): \(missing.sorted())")
            }
        }
    }

    @Test func theFullRowCarriesAll129Keys() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        #expect(row.raw.count == 129)
    }

    @Test func theFullRowMapsEveryProbeExtraKey() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(Set(dto.file.probeExtra.keys) == Set(CatalogRecordDTO.probeExtraKeys.map(\.rawValue)))
    }

    @Test func theFullRowCarriesEveryCuratedField() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(dto.curatedFields == CatalogDDL.KnowledgeField.allCases)
    }

    @Test func theFullRowHasOneKnowledgeSourcePerCuratedField() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(dto.knowledgeSources.map(\.field) == dto.curatedFields)
    }

    @Test func theFullRowHasAnAgreeingDigestAndContentRow() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(dto.digestState == .known(digest: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                                          source: .contentFixity))
        #expect(dto.content?.byteCount == 123_456_789)
    }

    @Test func theFullRowBindsItsSha256SoundPrint() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(dto.soundPrint?.digest == dto.digestState.digest)
    }

    @Test func thePoisonedMarkersDoNotCostARow() throws {
        let catalog = try ImportTestSupport.catalog(ImportGoldenFixtures.v6Poisoned)
        #expect(catalog.records.count == 3)
        for r in catalog.records {
            #expect(r.undecodable == ["removal"])
        }
    }

    /// The app's migration (RemovalMarker.migrated): `42` → nothing; a string
    /// marker + purgedAt → removedFromCatalog legacyPurged; a Manually Deleted
    /// label → removedFromCatalog legacyDeletedLabel at the load time.
    @Test func poisonedMarkersMigrateLikeTheApp() throws {
        let rows = try ImportTestSupport.catalog(ImportGoldenFixtures.v6Poisoned).records
        let dtos = rows.map { CatalogRecordDTO(record: $0, migrationLoadedAt: 1_000) }
        #expect(dtos[0].removal == nil)
        #expect(dtos[1].removal?.removalReason == "legacyPurged")
        #expect(dtos[1].removal?.removalState == "removedFromCatalog")
        #expect(dtos[2].removal?.removalReason == "legacyDeletedLabel")
        #expect(dtos[2].removal?.removalSince == 1_000)
    }

    @Test func theV6GoldenKeepsItsStoredMarker() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.v6).records.first)
        let dto = CatalogRecordDTO(record: row, migrationLoadedAt: 0)
        #expect(dto.removal?.migrated == false)
        #expect(dto.removal?.removalReason == "legacyPurged")
    }
}

@Suite("Import DTO — contract §a pins")
struct CatalogRecordDTOContractTests {

    @Test func theMirrorHasTheContracts129Keys() throws {
        let rows = ImportTestSupport.inventory(try ImportTestSupport.text(ImportTestSupport.contractURL))
        // The contract lists the keys in its own order (by role); the mirror
        // follows VideoRecord.CodingKeys. Same 129 keys, compared as sets.
        #expect(rows.count == 129)
        #expect(Set(rows.map(\.key)) == Set(VideoRecordJSON.Key.allCases.map(\.rawValue)))
        #expect(VideoRecordJSON.Key.allCases.count == 129)
    }

    @Test func everyKeysFateEqualsTheContract() throws {
        let rows = ImportTestSupport.inventory(try ImportTestSupport.text(ImportTestSupport.contractURL))
        for row in rows {
            let key = try #require(VideoRecordJSON.Key(rawValue: row.key), "\(row.key)")
            #expect(CatalogRecordDTO.fate(of: key) == ImportTestSupport.fateClass(row.fate), "#\(row.number) \(row.key)")
        }
    }

    @Test func theCuratedFieldsAreTheDDLKnowledgeFields() throws {
        let ddl = try ImportTestSupport.text(ImportTestSupport.ddlURL)
        let list = ImportTestSupport.ddlCheckList(ddl, table: "knowledge_sources", column: "field")
        #expect(list == CatalogDDL.KnowledgeField.allCases.map(\.rawValue))
    }
}

@Suite("Import DTO — DDL vocabularies")
struct CatalogDDLVocabularyTests {

    @Test func everyEnumEqualsItsDDLCheckList() throws {
        let ddl = try ImportTestSupport.text(ImportTestSupport.ddlURL)
        for v in CatalogDDL.vocabularies {
            let list = ImportTestSupport.ddlCheckList(ddl, table: v.location.table, column: v.location.column)
            #expect(list == v.rawValues, "\(v.location.table).\(v.location.column)")
        }
    }

    @Test func thePlaceConfidenceListEqualsTheDateList() throws {
        let ddl = try ImportTestSupport.text(ImportTestSupport.ddlURL)
        let list = ImportTestSupport.ddlCheckList(ddl, table: "user_places", column: "confidence")
        #expect(list == CatalogDDL.DateConfidence.allCases.map(\.rawValue))
    }

    @Test func theDuplicateConfidenceListEqualsThePairList() throws {
        let ddl = try ImportTestSupport.text(ImportTestSupport.ddlURL)
        let list = ImportTestSupport.ddlCheckList(ddl, table: "duplicate_members", column: "confidence")
        #expect(list == CatalogDDL.Confidence.allCases.map(\.rawValue))
    }

    @Test func theTombstoneStatesEqualTheFileStates() throws {
        let ddl = try ImportTestSupport.text(ImportTestSupport.ddlURL)
        let list = ImportTestSupport.ddlCheckList(ddl, table: "tombstones", column: "state")
        #expect(list == CatalogDDL.RemovalState.allCases.map(\.rawValue))
    }

    @Test func thePresenceClassMatchesTheGeneratedColumn() throws {
        let presence: Set<CatalogDDL.ReasonCode> = [.auditGone, .auditNeverSeen, .auditCouldNotCheck,
                                                     .noWholeFileDigest, .removedNoDigest]
        for code in CatalogDDL.ReasonCode.allCases {
            #expect(code.isPresenceReason == presence.contains(code), "\(code.rawValue)")
        }
    }
}

@Suite("Import DTO — identity and knowledge rules")
struct CatalogRecordDTOMappingTests {

    private func dto(_ object: [String: CatalogJSONValue]) throws -> CatalogRecordDTO {
        let data = try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object(object))
        let r = try VideoRecordJSON.makeDecoder().decode(VideoRecordJSON.self, from: data)
        return CatalogRecordDTO(record: r, migrationLoadedAt: 0)
    }

    private let hexA = String(repeating: "a", count: 64)
    private let hexB = String(repeating: "b", count: 64)

    private func fixity(_ digest: String, byteCount: Int64) -> CatalogJSONValue {
        .object(["algorithm": .string("sha256"), "digest": .string(digest), "byteCount": .int(byteCount),
                 "stamp": .object(["device": .int(1), "inode": .int(2), "size": .int(byteCount), "mtimeNs": .int(3)]),
                 "computedAt": .string("2026-09-20T00:00:00Z")])
    }

    private func archive(_ digest: String, size: Int64) -> CatalogJSONValue {
        .object(["algorithm": .string("sha256"), "digest": .string(digest),
                 "verifiedAt": .string("2026-08-15T00:00:00Z"), "sizeBytes": .int(size)])
    }

    @Test func aSampledHashIsNeverIdentity() throws {
        let d = try dto(["id": .string("A"), "sizeBytes": .int(10), "contentHash": .string("v1:abc")])
        #expect(d.digestState == CatalogRecordDTO.DigestState.none)
        #expect(d.file.sampledHash == "v1:abc")
    }

    @Test func aContentFixityOfAnotherSizeIsNotIdentity() throws {
        let d = try dto(["sizeBytes": .int(20), "contentFixity": fixity(hexA, byteCount: 10)])
        #expect(d.digestState == CatalogRecordDTO.DigestState.none)
    }

    @Test func anArchiveOnlyFixityIsIdentityWithNoStamp() throws {
        let d = try dto(["sizeBytes": .int(10), "archiveFixity": archive(hexA, size: 10)])
        #expect(d.digestState == .known(digest: hexA, source: .archiveFixity))
        #expect(d.file.stampInode == nil)
    }

    @Test func twoFixitiesThatDisagreeGiveNoDigest() throws {
        let d = try dto(["sizeBytes": .int(10), "contentFixity": fixity(hexA, byteCount: 10),
                         "archiveFixity": archive(hexB, size: 10)])
        #expect(d.digestState == .disagree(digests: [hexA, hexB]))
        #expect(d.file.contentDigest == nil)
    }

    @Test func anUppercaseDigestIsLowered() throws {
        let d = try dto(["sizeBytes": .int(10), "contentFixity": fixity(hexA.uppercased(), byteCount: 10)])
        #expect(d.digestState.digest == hexA)
    }

    @Test func aMissingCtimeReadsAsUnknown() throws {
        let d = try dto(["sizeBytes": .int(10), "contentFixity": fixity(hexA, byteCount: 10)])
        #expect(d.file.stampCtimeNs == -1)
    }

    @Test func aV1SoundPrintIsNotImported() throws {
        let stamp: CatalogJSONValue = .object([
            "computedAt": .string("2026-10-14T00:00:00Z"), "engineVersion": .int(3), "contentDigest": .string("v1:abc"),
            "sizeBytes": .int(10), "outcome": .string("noAudio"), "analyzedSeconds": .int(0),
            "complete": .bool(true), "landmarks": .int(0), "bytes": .int(0)])
        let d = try dto(["sizeBytes": .int(10), "audioFingerprint": stamp])
        #expect(d.soundPrint == nil)
    }

    @Test func defaultCuratedValuesAreNotCarried() throws {
        let d = try dto(["userNotes": .string(""), "tags": .array([]), "mediaDisposition": .string("Unreviewed"),
                         "starRating": .int(0)])
        #expect(d.curatedFields.isEmpty)
    }

    @Test func anUndecodableCuratedValueIsStillAKnowledgeSource() throws {
        let d = try dto(["familyMusic": .string("not an object")])
        #expect(d.undecodable == ["familyMusic"])
        #expect(d.knowledgeSources.map(\.field) == [.familyMusic])
        #expect(d.knowledgeSources.first?.valueJSON == CatalogJSONValue.string("not an object"))
    }

    @Test func lineageIsOneValueOfItsKeys() throws {
        let d = try dto(["derivedFrom": .string("11111111-1111-1111-1111-111111111111"),
                         "derivationKind": .string("trim"), "trimInSeconds": .int(1), "trimOutSeconds": .int(9)])
        let lineage = try #require(d.knowledgeSources.first { $0.field == .lineage })
        #expect(lineage.valueJSON.objectValue?.count == 4)
        #expect(d.curated.lineage?.kind == CatalogDDL.LineageKind.trim)
    }

    @Test func aCleanupWithNoKindIsNamedFromItsRecipe() throws {
        let d = try dto(["derivedFrom": .string("11111111-1111-1111-1111-111111111111"),
                         "cleanupRecipeID": .string("denoise"), "cleanupRecipeVersion": .int(1)])
        #expect(d.curated.lineage?.kind == CatalogDDL.LineageKind.cleanup)
    }

    @Test func aDerivationWithNoKindIsUnrecorded() throws {
        let d = try dto(["derivedFrom": .string("11111111-1111-1111-1111-111111111111")])
        #expect(d.curated.lineage?.kind == CatalogDDL.LineageKind.unrecorded)
    }

    @Test func everyDerivedValueImportsUnverifiedInArrayOrder() throws {
        let d = try dto(["sceneCaptions": .array([.object(["timestamp": .int(1), "text": .string("a")]),
                                                   .object(["timestamp": .int(2), "text": .string("b")])]),
                         "detectedPeople": .array([.string("Donna")])])
        #expect(d.derivedUnverified.map(\.kind) == [.scene, .scene, .detectedPerson])
        #expect(d.derivedUnverified.map(\.seq) == [0, 1, 0])
    }

    @Test func aDonorDateKeepsItsContext() throws {
        let d = try dto(["inferredDateSource": .string("propagated from 11111111-1111-1111-1111-111111111111"),
                         "inferredDateReason": .string("same tape")])
        #expect(d.regenContext.map(\.kind) == [.donorDate])
        #expect(d.regenContext.first?.reason == "same tape")
    }

    @Test func thePathFoldKeepsDiacriticsAndFoldsCase() {
        #expect(CatalogRecordDTO.pathFold("/V/É.mov") == CatalogRecordDTO.pathFold("/V/é.mov"))
        #expect(CatalogRecordDTO.pathFold("/V/é.mov") != CatalogRecordDTO.pathFold("/V/e.mov"))
    }

    @Test func aRowIDIsCanonicalUppercase() throws {
        let d = try dto(["id": .string("abcdefab-0000-4000-8000-000000000001")])
        #expect(d.file.id == "ABCDEFAB-0000-4000-8000-000000000001")
    }
}

@Suite("Import DTO — scale")
struct CatalogRecordDTOScaleTests {
    /// Budget, not measured on the Mac yet (cloud brief, no toolchain): ~10 µs a
    /// row is the order of the comparable decode in CatalogStore; 100k rows in
    /// 20 s leaves a wide margin. Re-baseline on the M4 and tighten.
    static let budget: Duration = .seconds(20)

    @Test func hundredThousandRowsMapWithinBudget() throws {
        let row = try #require(try ImportTestSupport.catalog(ImportGoldenFixtures.full129).records.first)
        let rows = Array(repeating: row, count: 100_000)
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var curated = 0
        for r in rows { curated += CatalogRecordDTO(record: r, migrationLoadedAt: 0).curatedFields.count }
        let elapsed = clock.now - start
        #expect(curated == 100_000 * CatalogDDL.KnowledgeField.allCases.count)
        expectWithinTimingBudget("import DTO map 100k rows", measured: elapsed, budget: Self.budget, loadBefore: loadBefore)
    }
}
