// AnalysisResultsReportCoverageTests.swift — fresh-eyes coverage review of the
// Results sheet (main 9c86c7369..2c8fa9777, 2026-11-05). RED on 2c8fa9777;
// names the lines it pins. Reuses AnalysisResultsReportTests' fixtures (same
// module).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AnalysisResultsReport — coverage review (red on 2c8fa9777)")
struct AnalysisResultsReportCoverageTests {
    typealias T = AnalysisResultsReportTests

    /// TRUTH — pins GRDBCatalogRepository+AnalysisResults.swift:36 and
    /// :125-131 (the "Era found" classification and the row's value read the
    /// newest INFERRED `era.fused` row by the signer; Rick's `rejected` row
    /// is never consulted) against AnalysisResultsReport.swift:315 (`eraWords`
    /// of that value). On the same sheet the agreement count goes through
    /// MachineEraResolver's selection and honours the rejection, and the file
    /// dossier opened from the same row (Show Dossier) says "Era: rejected by
    /// you". One file, one sheet, two answers: the row shows the era Rick
    /// vetoed as the analyzer's standing answer with nothing saying so.
    @Test func anEraRickRejectedIsNotListedAsAPlainEraFound() async throws {
        let fixture = try await EraFixture.catalog([.init(n: 1, path: "/V/a/Alpha.mov", userYear: "1990")])
        defer { fixture.remove() }
        let repository = try await T.open(fixture)
        try T.put(repository, try T.fused(1, 1991, 1995))
        try T.reject(repository, 1, value: "1991-1995")

        // Nothing else in the app shows this era any more.
        let shown = try await repository.read { try MachineEraResolver.eras(in: $0) }
        #expect(shown[T.hex(1)] == nil, "the inspector, search and Catalog Status show no era")
        let fileID = String(format: "00000000-0000-0000-0000-%012X", 1)
        let now = Date()
        let dossier = try await repository.read { try FileDossier.read(reader: $0, fileID: fileID, now: now) }
        #expect(dossier?.patterns.line("Era")?.value == "rejected by you", "the dossier beside the row says so")

        let report = try await T.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.agreement.total == 0, "the sheet's own agreement line already leaves the rejected era out")

        // Adapted on fix/codex-1105: the vetoed era is not in "Era found" at all
        // (Rick's preference, the Codex 11/05 fix) but in its own list, "Rejected
        // by you", whose row says so. The original asked only that the row not
        // read as a plain era found; this keeps that and pins where it went.
        let list = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .eraFound, attempts: nil)
        }
        #expect(list.rows.isEmpty, "Era found lists \(list.rows.map(\.filename)): a vetoed era shown as the analyzer's answer")
        let vetoed = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .rejected, attempts: nil)
        }
        let row = try #require(vetoed.rows.first)
        #expect(row.value.localizedCaseInsensitiveContains("rejected"), "\(row.value)")
        await repository.close()
    }
}
