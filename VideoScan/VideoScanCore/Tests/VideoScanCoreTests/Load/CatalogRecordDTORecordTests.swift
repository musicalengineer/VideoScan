// CatalogRecordDTORecordTests.swift
// LOGIC (cutover B1): `CatalogRecordDTO.init(record: VideoRecord)` gives the
// SAME DTO the importer builds from that record's catalog.json row, for
// every field the contract keeps — pinned per fixture row and for a record
// with all 129 keys set — and the in-memory coders it rides on write and
// read exactly what JSONEncoder / JSONDecoder (the app's `.iso8601`
// catalog coders) write and read.
//
// Suites (filter by SUITE): CatalogJSONValueCoderTests · CatalogRecordDTORecordTests

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogJSONValueCoder — the in-memory coders match the catalog's JSON coders")
struct CatalogJSONValueCoderTests {

    private static func rich() -> VideoRecord {
        RichRecord.make(id: UUID(), path: "/Volumes/Fixture/Clips/rich.mov", digest: PoisonedCatalogFixture.digest("rich"),
                        sizeBytes: 4_096, pairWith: UUID(), otherRow: UUID())
    }

    @Test("the DOM encoder writes the tree JSONEncoder(.iso8601) writes, for a record with every key set")
    func encoderMatchesTheAppEncoder() throws {
        let record = Self.rich()
        let viaText = try AppCatalogCoding.row(record)
        let inMemory = try CatalogJSONValueEncoder().encode(VideoRecordDTO(record))
        #expect(inMemory == viaText)
    }

    @Test("the DOM decoder reads back the record JSONDecoder(.iso8601) reads, for a record with every key set")
    func decoderMatchesTheAppDecoder() throws {
        let row = try AppCatalogCoding.row(Self.rich())
        let viaText = try AppCatalogCoding.record(row)
        let inMemory = try VideoRecord(from: CatalogJSONValueDecoder.decoder(for: row))
        let readBack = try AppCatalogCoding.row(inMemory)
        let expected = try AppCatalogCoding.row(viaText)
        #expect(readBack == expected)
    }

    @Test("a Date is ISO-8601 whole seconds; a Float is its shortest decimal; an integral Double is an integer")
    func scalarShapes() throws {
        let encoder = CatalogJSONValueEncoder()
        #expect(try encoder.encode(Date(timeIntervalSince1970: 1_790_000_000.9)) == .string("2026-09-21T14:13:20Z"))
        #expect(try encoder.encode(Float(0.7)) == .double(0.7))
        #expect(try encoder.encode(3.0) == .int(3))
        #expect(try encoder.encode(UInt64.max) == .double(Double(UInt64.max)))
    }

    @Test("a non-finite number refuses, as JSONEncoder does")
    func nonFiniteRefuses() {
        #expect(throws: EncodingError.self) { try CatalogJSONValueEncoder().encode(Double.nan) }
    }

    @Test("the decoder refuses a type mismatch and a missing key with the coding errors JSONDecoder uses")
    func decoderRefusals() {
        let decoder = CatalogJSONValueDecoder()
        #expect(throws: DecodingError.self) { try decoder.decode(Int.self, from: .string("3")) }
        #expect(throws: DecodingError.self) { try decoder.decode(InferredDateRange.self, from: .object(["startYear": .int(1990)])) }
        #expect(throws: DecodingError.self) { try decoder.decode(Date.self, from: .string("summer 1990")) }
        #expect(throws: DecodingError.self) { try decoder.decode(Bool.self, from: .int(1)) }
    }

    @Test("JSON text parses into the tree the Codable reader builds")
    func fastParserMatchesTheCodableReader() throws {
        let text = #"{"a":1,"b":2.5,"c":"x","d":[true,null],"e":{"f":-7}}"#
        let codable = try JSONDecoder().decode(CatalogJSONValue.self, from: Data(text.utf8))
        #expect(CatalogJSONValue.parse(text) == codable)
    }
}

@Suite("CatalogRecordDTO(record:) — the DTO of a live record is the importer's DTO of its row")
struct CatalogRecordDTORecordTests {

    @Test("every row of the poisoned fixture (17 shapes + bulk rows): DTO(JSON row) == DTO(record decoded from that row), class by class")
    func everyFixtureRowPins() throws {
        let fixture = PoisonedCatalogFixture(healthyRows: 30)
        let catalog = try #require(try JSONDecoder().decode(CatalogJSONValue.self, from: fixture.catalogData)["records"]?.arrayValue)
        #expect(catalog.count == 47)
        let records = try catalog.map(AppCatalogCoding.record)
        resolvePairs(records)                     // the app's load rewires pairedWith before anything reads it
        for (row, record) in zip(catalog, records) {
            let fromJSON = CatalogRecordDTO(record: try AppCatalogCoding.json(row), migrationLoadedAt: 0)
            let fromRecord = try CatalogRecordDTO(record: record, migrationLoadedAt: 0)
            for c in KeptFields.classes(fromJSON, fromRecord) {
                #expect(c.equal, "row \(fromJSON.file.id): \(c.name)")
            }
        }
    }

    @Test("a record with every one of the 129 keys set (a trim, and a cleanup output): DTO(the bytes the app writes) == DTO(record), class by class")
    func theRichRecordPins() throws {
        let trim = RichRecord.make(id: UUID(), path: "/Volumes/Fixture/Clips/rich.mov", digest: PoisonedCatalogFixture.digest("rich"),
                                   sizeBytes: 4_096, pairWith: UUID(), otherRow: UUID())
        let cleanup = RichRecord.make(id: UUID(), path: "/Volumes/Fixture/Clips/rich-clean.mov", digest: PoisonedCatalogFixture.digest("rich-clean"),
                                      sizeBytes: 4_096, pairWith: UUID(), otherRow: UUID())
        cleanup.derivationKind = nil
        cleanup.trimInSeconds = nil
        cleanup.trimOutSeconds = nil
        cleanup.cleanupRecipeID = "denoise"
        cleanup.cleanupRecipeVersion = 2
        var keys = Set<String>()
        for record in [trim, cleanup] {
            let row = try AppCatalogCoding.row(record)
            keys.formUnion(try #require(row.objectValue).keys)
            let fromJSON = CatalogRecordDTO(record: try AppCatalogCoding.json(row), migrationLoadedAt: 0)
            let fromRecord = try CatalogRecordDTO(record: record, migrationLoadedAt: 0)
            for c in KeptFields.classes(fromJSON, fromRecord) {
                #expect(c.equal, "\(record.filename): \(c.name)")
            }
            #expect(fromRecord.knowledgeSources.count == CatalogDDL.KnowledgeField.allCases.count, "every curated field is carried")
            #expect(fromRecord.derivedUnverified.count == 16)
        }
        let missing = Set(VideoRecordJSON.Key.allCases.map(\.rawValue)).subtracting(keys)
        #expect(missing == ["purgedAt", "removal", "removalRevision"], "a live, never-removed row writes every other key")
    }
}
