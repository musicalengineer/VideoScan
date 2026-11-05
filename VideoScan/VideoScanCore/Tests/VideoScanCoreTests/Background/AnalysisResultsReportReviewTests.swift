// AnalysisResultsReportReviewTests.swift — review red tests for the Results
// sheet (branch feat/results-sheet, f2b42abd0). Each test names the line it
// pins and is RED on the code under review. Reuses AnalysisResultsReportTests'
// fixtures (same module).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AnalysisResultsReport — review (red on f2b42abd0)")
struct AnalysisResultsReportReviewTests {
    typealias T = AnalysisResultsReportTests

    /// MAJOR — pins GRDBCatalogRepository+AnalysisResults.swift:59-66 (`eraStillToDo`)
    /// against EraJob.swift:554 (`cached = journal.subjects(by:)`). The planner's
    /// "cached" rule is catalog rows OR journal lines; the sheet reads only the
    /// catalog, so for up to 5 minutes (JournalApplier.interval) — or for as long
    /// as a write hold / viewer session refuses the door — "Still to do" counts
    /// files the analyzer has already answered, and the ETA is built on it.
    @Test func stillToDoIsWhatThePlannerWouldPlanWhenTheJournalHoldsUnappliedVerdicts() async throws {
        let fixture = try await EraFixture.catalog((1...3).map { .init(n: $0, path: "/V/\($0).mov") })
        defer { fixture.remove() }
        let repository = try await T.open(fixture)
        try T.put(repository, try T.fused(1, 1991, 1995))                        // applied to the catalog
        let root = try EraFixture.stateRoot()
        let journal = ObservationJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
        _ = try journal.append(try T.fused(2, 1991, 1995))                        // answered; waiting in the journal
        let plan = try EraPlanner.plan(catalogURL: fixture.url, journal: journal, signer: T.seated, limit: nil, jobID: JobID(),
                                       isReadable: { _ in true })
        #expect(plan.videoContents - plan.cached == 1 && plan.units.map(\.digest) == [T.hex(3)], "the planner would plan content 3 only")
        let report = try await T.report(repository, root)
        let a = try #require(report.analyzers.first)
        #expect(a.stillToDo == plan.videoContents - plan.cached,
                "the sheet says 'not answered yet' (\(a.stillToDo ?? -1)) for a file the analyzer answered; the planner says \(plan.videoContents - plan.cached)")
        await repository.close()
    }

    /// MINOR — pins GRDBCatalogRepository+AnalysisResults.swift:34 (`value GLOB
    /// '[0-9]…'`) against MachineEraResolver.range (1800...2200). Two
    /// classifiers of "is this an era": the sheet says "Era found" for a value
    /// the inspector, search and Catalog Status all refuse (rule 4).
    @Test func anEraTheResolverRefusesIsNotEraFound() async throws {
        let fixture = try await EraFixture.catalog([.init(n: 1, path: "/V/1.mov")])
        defer { fixture.remove() }
        let repository = try await T.open(fixture)
        try T.put(repository, [try ObservationLine(subjectID: T.hex(1), field: "era.fused", value: "2300-2305", by: T.seated,
                                                   at: T.now - 10, confidence: 0.5,
                                                   evidence: ["validEraWindows": 1, "windows": [[0.0, 60.0]]], job: "J", unit: 1)])
        let shown = try await repository.read { try MachineEraResolver.eras(in: $0) }
        #expect(shown[T.hex(1)] == nil, "the inspector shows no era for 2300-2305")
        let report = try await T.report(repository, try EraFixture.stateRoot())
        let a = try #require(report.analyzers.first)
        #expect(a.eraFound == 0, "the sheet must not say 'Era found' for an era nothing else in the app shows")
        #expect(a.other == 1)
        await repository.close()
    }

    /// MINOR — pins AnalysisResultsReport.swift:165 (`triesInProgress` = every
    /// attempts entry for the signer). EraJob.swift:241-243 and :299-300 append
    /// the verdict, THEN clear the try; a crash or a failed `clear` between the
    /// two leaves an entry the planner never revisits (the content is cached).
    /// One content then sits in two exclusive lists ("given up" and "tries in
    /// progress") for ever.
    @Test func aTryWhoseVerdictLandedIsNotInProgress() async throws {
        let fixture = try await EraFixture.catalog([.init(n: 1, path: "/V/1.mov")])
        defer { fixture.remove() }
        let repository = try await T.open(fixture)
        try T.put(repository, [try T.giveUp(1)])
        let root = try EraFixture.stateRoot()
        try T.attempts(root, [(1, T.seated, 3, "8 of 8 frames would not decode")])
        let report = try await T.report(repository, root)
        let a = try #require(report.analyzers.first)
        #expect(a.gaveUp == 1)
        #expect(a.triesInProgress == 0, "a content with a verdict by this signer is not in progress")
        let snapshot = try EraAttemptStore.snapshot(stateRoot: root)
        let list = try await repository.read {
            try AnalysisResultsReport.files(reader: $0, signer: T.seated, outcome: .inProgress, attempts: snapshot)
        }
        #expect(list.rows.isEmpty)
        await repository.close()
    }
}
