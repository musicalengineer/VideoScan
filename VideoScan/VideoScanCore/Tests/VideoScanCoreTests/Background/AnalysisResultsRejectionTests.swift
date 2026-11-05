// AnalysisResultsRejectionTests.swift — Codex review 2026-11-05 (P0 TRUTH):
// GRDBCatalogRepository+AnalysisResults.swift:129 classified a machine
// `era.fused` value Rick had REJECTED afterwards as "Era found", counted and
// listed. The rule is MachineEraResolver's (the inspector's, the dossier's):
// the newest readable fused value per signer; a later `rejected` row on the
// same value hides it. A rejected value is its own outcome, "Rejected by you",
// counted and listed from the same classification as the others.
// Reuses AnalysisResultsReportTests' fixtures (same module). Synthetic rows only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AnalysisResultsReport — Rick's rejection (Codex 11/05)")
struct AnalysisResultsRejectionTests {
    typealias T = AnalysisResultsReportTests

    /// 1 rejected · 2 found · 3 an older value rejected, the newest stands.
    /// (The store refuses a machine re-assertion of a vetoed value, so
    /// "rejected, then said again" cannot occur.)
    static func scene() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await EraFixture.catalog((1...3).map { .init(n: $0, path: "/V/\($0).mov") })
        let repository = try await T.open(fixture)
        try T.put(repository, try T.fused(1, 1990, 1995) + T.fused(2, 1991, 1995)
                  + T.fused(3, 1980, 1984, at: T.now - 120) + T.fused(3, 1986, 1989))
        try T.reject(repository, 1, value: "1990-1995")
        try T.reject(repository, 3, value: "1980-1984")
        return (fixture, repository)
    }

    @Test func aValueRickRejectedIsNotEraFoundInTheCountOrTheList() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let shown = try await repository.read { try MachineEraResolver.eras(in: $0) }
        #expect(shown[T.hex(1)] == nil && shown.count == 2, "the inspector shows no era for content 1")
        let report = try await T.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.analyzed == 3)
        #expect(a.eraFound == 2, "a value Rick rejected is not 'Era found'")
        let found = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .eraFound, attempts: nil)
        }
        #expect(Set(found.rows.map(\.digest)) == Set([2, 3].map(T.hex)), "the Era found list never names the rejected file")
        #expect(found.rows.first { $0.digest == T.hex(3) }?.value == "late 1980s (1986–1989)", "the standing value, not the rejected one")
        await repository.close()
    }

    @Test func aRejectedValueIsItsOwnOutcomeCountedAndListedFromOneClassification() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let report = try await T.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.rejected == 1 && a.other == 0, "the numbers add up: 2 found + 1 rejected = 3 analyzed")
        #expect(AnalysisResultsReport.Outcome.rejected.title == "Rejected by you")
        let list = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .rejected, attempts: nil)
        }
        #expect(list.rows.map(\.digest) == [T.hex(1)])
        #expect(list.rows.first?.value == "rejected by you: early 1990s (1990–1995)")
        for outcome in AnalysisResultsReport.Outcome.allCases where outcome != .inProgress && outcome != .stillToDo {
            let rows = try await repository.read {
                try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: outcome, attempts: nil)
            }
            #expect(rows.rows.count == a.count(outcome), "the \(outcome) list is as long as its count")
        }
        await repository.close()
    }

    /// TRUTH — the SQL classification is the resolver's: every "Era found" row
    /// names exactly the era MachineEraResolver shows for that signer.
    @Test func eraFoundIsWhatTheResolverShows() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let shown = try await repository.read { try MachineEraResolver.eras(in: $0) }
        let resolver = Dictionary(uniqueKeysWithValues: shown.compactMap { digest, eras in
            eras.first { $0.by == T.seated }.map { (digest, AnalysisResultsReport.eraWords("\($0.lo)-\($0.hi)")) }
        })
        let found = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .eraFound, attempts: nil)
        }
        #expect(Dictionary(uniqueKeysWithValues: found.rows.map { ($0.digest, $0.value) }) == resolver)
        await repository.close()
    }

    /// SCALE / memory — review 11/05 (C): "Still to do" read every unanswered
    /// content's file row, then cut to `limit`. The LIMIT is in SQL now: no
    /// read hands back more than limit + 1 + |journal| rows.
    @Test func stillToDoNeverReadsMoreRowsThanItShows() async throws {
        let fixture = try await EraFixture.catalog((1...40).map { .init(n: $0, path: String(format: "/V/%02d.mov", $0)) })
        defer { fixture.remove() }
        let repository = try await T.open(fixture)
        let root = try EraFixture.stateRoot()
        let journal = ObservationJournal(directory: EraPlanner.journalDirectory(stateRoot: root))
        _ = try journal.append(try T.fused(1, 1991, 1995))               // answered; waiting in the journal
        let list = try await repository.read { reader in
            let spy = CountingResultsReader(reader)
            let list = try AnalysisResultsReport.files(reader: spy, signer: T.seated, outcome: .stillToDo, attempts: nil,
                                                      journal: journal, limit: 5)
            #expect(spy.mostRows <= 5 + 1 + 1, "a read handed back \(spy.mostRows) rows for a 5-row list")
            return list
        }
        #expect(list.rows.map(\.filename) == ["02.mov", "03.mov", "04.mov", "05.mov", "06.mov"], "01 is answered in the journal")
        #expect(list.truncated)
        await repository.close()
    }
}

/// Forwards to the real reader and remembers the largest row count any list read returned.
final class CountingResultsReader: CatalogAnalysisResultsReading {
    let base: any CatalogAnalysisResultsReading
    private(set) var mostRows = 0
    init(_ base: any CatalogAnalysisResultsReading) { self.base = base }
    private func seen<C: Collection>(_ c: C) -> C { mostRows = max(mostRows, c.count); return c }
    func analyzerOutcomeCounts() throws -> [CatalogRow.AnalyzerOutcomeCounts] { try base.analyzerOutcomeCounts() }
    func eraUnansweredInCatalog(signer: String) throws -> [String] { seen(try base.eraUnansweredInCatalog(signer: signer)) }
    func eraUnansweredFiles(signer: String, limit: Int) throws -> [CatalogRow.AnalyzerOutcomeFile] {
        seen(try base.eraUnansweredFiles(signer: signer, limit: limit))
    }
    func analyzerAnswered(signer: String, digests: [String]) throws -> Set<String> { try base.analyzerAnswered(signer: signer, digests: digests) }
    func analyzerFirstVerdicts(signer: String, since: Int64) throws -> Int { try base.analyzerFirstVerdicts(signer: signer, since: since) }
    func eraFusedRowsOfDatedContents(_ body: (String, String, [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws {
        try base.eraFusedRowsOfDatedContents(body)
    }
    func analyzerOutcomeFiles(signer: String, kind: CatalogRow.AnalyzerVerdictKind, limit: Int) throws -> [CatalogRow.AnalyzerOutcomeFile] {
        seen(try base.analyzerOutcomeFiles(signer: signer, kind: kind, limit: limit))
    }
    func analyzerFiles(digests: [String]) throws -> [CatalogRow.AnalyzerOutcomeFile] { seen(try base.analyzerFiles(digests: digests)) }
}
