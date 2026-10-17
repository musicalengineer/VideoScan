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

    @Test func theAppsLinkDetailIsTheLinkClass() throws {
        let row = CatalogAuditRowResult(id: UUID(), result: .couldNotCheck, detail: Self.appLinkDetail)
        let read = try JSONDecoder().decode(AuditMarkerJSON.Row.self, from: try JSONEncoder().encode(row))
        #expect(read.gateClass == .link)
    }
}
