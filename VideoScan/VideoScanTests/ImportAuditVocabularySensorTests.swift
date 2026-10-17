// ImportAuditVocabularySensorTests.swift
// SENSOR for bug 1 of Rick's first Import to SQLite dry run (2026-10-17,
// catalog.log 17:52:41: "catalog-audit.json result 26 says
// \"neverSeenByAnAudit\", which this importer does not know"). The app's
// audit marker writes `CatalogAuditResult.rawValue` per row; the importer
// (VideoScanCore AuditMarkerJSON) must know exactly those words — no fewer
// (a real marker is refused) and no more (a word the app never writes is
// accepted silently). `notAsked` is counted in bulk and never written on a
// row, so it is not a per-row word.
//   SENSOR — `AuditMarkerJSON.knownResultWords` == the per-row cases of
//            `CatalogAuditResult`; every per-row row, encoded by the app's
//            own `CatalogAuditRowResult` encoder, decodes in the importer
//            with a gate class; the app's link detail is the `link` class.
//   SENSOR — the judged path (bug 3, importer N1 "names no judged path"):
//            a non-present row built the way the job builds it, inside a
//            finished run record, encoded by the marker's OWN encoder,
//            reaches the importer's `AuditMarkerJSON.Row.judgedPath`; a
//            present row carries none; the importer's preflight refuses
//            nothing in the file and its gate facts are whole. This pins
//            the two sides to one key.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Import to SQLite — the audit vocabulary sensor")
struct ImportAuditVocabularySensorTests {

    /// Results the app writes on a ROW (bulk-only `notAsked` excluded).
    static let perRowResults = CatalogAuditResult.allCases.filter { $0 != .notAsked }

    /// The detail the app writes when a link in the path made a row not
    /// provable (VideoScanModel+CatalogAudit.swift `.notProvable`, words
    /// from CatalogAuditPlan.swift `.link`).
    static let appLinkDetail = "not at its path, but that is not proof here: a link in the path — not provable — not marked"

    @Test func theImporterKnowsExactlyTheAppsPerRowWords() {
        #expect(AuditMarkerJSON.knownResultWords == Set(Self.perRowResults.map(\.rawValue)))
    }

    @Test func theBulkOnlyWordIsNotARowWord() {
        #expect(!AuditMarkerJSON.knownResultWords.contains(CatalogAuditResult.notAsked.rawValue))
    }

    @Test("every row the app encodes decodes in the importer with a gate class", arguments: perRowResults)
    func everyAppRowHasAGateClass(result: CatalogAuditResult) throws {
        let row = CatalogAuditRowResult(id: UUID(), result: result, detail: result == .present ? nil : result.words)
        let data = try JSONEncoder().encode(row)
        let read = try JSONDecoder().decode(AuditMarkerJSON.Row.self, from: data)
        #expect(read.gateClass != nil)
    }

    static let judged = "/Volumes/Archive1/Family/1987/Christmas tape.mov"

    /// A finished run record holding one row per per-row result, each built
    /// by the job's own initializer, encoded by the marker's own encoder.
    @MainActor
    static func appMarkerBytes() throws -> (Data, [CatalogAuditResult: UUID]) {
        var record = CatalogAuditRunRecord(startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                                           finishedAt: Date(timeIntervalSince1970: 1_760_000_060), outcome: .completed)
        var ids: [CatalogAuditResult: UUID] = [:]
        for result in perRowResults {
            let id = UUID()
            ids[result] = id
            let apply = CatalogAuditApply(result: result, detail: result.words)
            record.noteRow(CatalogAuditRowResult(id: id, apply: apply, seenOn: nil, judgedPath: judged))
        }
        record.counts = Dictionary(uniqueKeysWithValues: perRowResults.map { ($0.rawValue, 1) })
        record.catalogGeneration = 7
        return (try CatalogAuditRunMarker.encoder.encode(record), ids)
    }

    @Test("a non-present row's judged path, written by the app's encoder, arrives in the importer's row",
          arguments: perRowResults.filter { $0 != .present })
    @MainActor
    func theJudgedPathArrivesInTheImporter(result: CatalogAuditResult) throws {
        let (data, ids) = try Self.appMarkerBytes()
        let read = try AuditMarkerJSON.decode(data)
        let id = try #require(ids[result]).uuidString
        let row = try #require(read.rows?.first { $0.id == id })
        #expect(row.judgedPath == Self.judged)
    }

    @Test @MainActor
    func aPresentRowCarriesNoJudgedPath() throws {
        let (data, ids) = try Self.appMarkerBytes()
        let read = try AuditMarkerJSON.decode(data)
        let id = try #require(ids[.present]).uuidString
        let row = try #require(read.rows?.first { $0.id == id })
        #expect(row.judgedPath == nil)
    }

    @Test @MainActor
    func theImportersPreflightRefusesNothingInTheAppsMarker() throws {
        let (data, _) = try Self.appMarkerBytes()
        #expect(try AuditMarkerJSON.decode(data).faults.isEmpty)
    }

    @Test @MainActor
    func theImportersGateFactsOfTheAppsMarkerAreWhole() throws {
        let (data, _) = try Self.appMarkerBytes()
        let facts = try AuditMarkerJSON.decode(data).facts
        #expect(facts.hasRowResults)
        #expect(facts.savedGeneration == 7)
        #expect(facts.outcome == "completed")
        #expect(!facts.partial)
        #expect(facts.finishedAt != nil)
        #expect(facts.unknownResultWords.isEmpty)
    }

    @Test func theAppsLinkDetailIsTheLinkClass() throws {
        let row = CatalogAuditRowResult(id: UUID(), result: .couldNotCheck, detail: Self.appLinkDetail)
        let read = try JSONDecoder().decode(AuditMarkerJSON.Row.self, from: try JSONEncoder().encode(row))
        #expect(read.gateClass == .link)
    }
}
