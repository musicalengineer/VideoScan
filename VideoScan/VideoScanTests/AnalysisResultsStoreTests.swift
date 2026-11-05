// AnalysisResultsStoreTests.swift — Content Analysis ▸ Results (the app
// half: AnalysisResultsStore.swift, AnalysisResultsSheet.swift). Core's
// AnalysisResultsReportTests own the numbers (logic, truth, scale, isolation).
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH      journal lines → the launch pass commits them → the PRODUCTION
//              store (this session's repository, `background/` beside the
//              catalog) reads: era found 1 with its words, given up 1 with
//              the exact reason, 1 try in progress from the scene's own
//              attempts file; every row's record id passes the reveal door's
//              guard (canNavigateToRecord); the catalog is unchanged
//              (no row added, generation the same) and the attempts file
//              keeps its bytes.
//   LOGIC      the seated analyzer is selected first; a failed read says so
//              in place of the numbers (and logs once); a stale list request
//              that lands late is dropped; a row not in the catalog is not
//              revealed and says why.
//   SENSOR     AnalysisResultsSheetSensorTests (below): no records walk in
//              the sheet or the store; the store holds no SQL and no write;
//              no `extension VideoScanModel`; the panel opens the sheet; the
//              reveal goes through showInCatalog(recordID:).
//   SCALE      Core (100k contents). MEDIA N/A — no media is opened.
//   WRITER quartet N/A — a reader.
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let seatedBy = SeatedApproach.eraA2.signer

@MainActor
private func resultsScene(_ label: String) async throws -> (CutoverScene, healthy: VideoRecord, other: VideoRecord) {
    let scene = try CutoverScene.make(label)
    try await scene.importCatalog()
    let preview = try await scene.sqliteLoad()
    let healthyID = PoisonedCatalogFixture.id(.healthy)
    let healthy = try #require(preview.records.first { $0.id.uuidString == healthyID }.flatMap(CatalogCommit.digest(of:)))
    let other = try #require(preview.records.compactMap(CatalogCommit.digest(of:)).first { $0 != healthy })
    let lines = [
        try ObservationLine(subjectID: healthy, field: "era.fused", value: "1991-1995", by: seatedBy, at: 1_762_000_000, confidence: 0.6,
                            evidence: ["validEraWindows": 1, "windows": [[0.0, 60.0]]], job: "TEST", unit: 0),
        // The shape EraRecordMapper.giveUpLine writes (Core pins its exact text).
        try ObservationLine(subjectID: other, field: EraRecordMapper.noneField, value: EraRecordMapper.noneValue, by: seatedBy,
                            at: 1_762_000_000, confidence: 0,
                            evidence: ["reason": "gave up after 3 tries: 2 of 2 frames would not decode (ffmpeg: moov atom not found)",
                                       "tries": 3, "gaveUp": true], job: "TEST", unit: 1),
    ]
    try ObservationJournal(directory: scene.folder.appendingPathComponent("background/journal", isDirectory: true)).append(lines)
    try scene.writeLatch()
    scene.model.records = scene.model.loadCatalogAtLaunch()
    _ = try #require(await scene.model.journalApplier.launchPass?.value)
    let healthyRecord = try scene.record(.healthy)
    let otherRecord = try #require(scene.model.records.first { CatalogCommit.digest(of: $0) == other })
    return (scene, healthyRecord, otherRecord)
}

@MainActor
private func closeScene(_ model: VideoScanModel) async {
    model.journalApplier.detach()
    model.machineEras.detach()
    if let c = model.catalogCutover.committer { await c.repository.close() }
}

@Suite("Content Analysis ▸ Results — the store", .serialized)
@MainActor
struct AnalysisResultsStoreTests {

    @Test("TRUTH: the production store reads this session's catalog and attempts file, read-only, and a click reveals the record")
    func theProductionStoreShowsWhatTheCatalogHolds() async throws {
        let (scene, healthy, other) = try await resultsScene("results_truth")
        defer { scene.cleanup() }
        let model = scene.model
        // One try in progress on a third digest, in the scene's own state folder.
        let root = scene.folder.appendingPathComponent("background", isDirectory: true)
        let tries = try EraAttemptStore(stateRoot: root)
        try tries.record(digest: String(repeating: "c", count: 64), signer: seatedBy, reason: "the model never answered", at: 1)
        let attemptsBytes = try Data(contentsOf: EraAttemptStore.url(stateRoot: root))
        let repository = try #require(model.catalogCutover.committer?.repository)
        let rowsBefore = try await repository.read { try $0.provenanceAssertionCount() }
        let generationBefore = await repository.generation

        let store = AnalysisResultsStore.production(model: model)
        await store.load()
        #expect(store.failure == nil)
        let a = try #require(store.analyzer)
        #expect(a.signer == seatedBy && a.isSeated)
        #expect(a.eraFound == 1 && a.gaveUp == 1 && a.eraNone == 0 && a.triesInProgress == 1)
        #expect(store.outcome == .eraFound)
        let found = try #require(store.files?.rows.first)
        #expect(found.filename == healthy.filename && found.value == "early 1990s (1991–1995)")
        #expect(found.recordID == healthy.id)

        await store.select(outcome: .gaveUp)
        let gave = try #require(store.files?.rows.first)
        #expect(gave.recordID == other.id)
        #expect(gave.reason == "gave up after 3 tries: 2 of 2 frames would not decode (ffmpeg: moov atom not found)")

        await store.select(outcome: .inProgress)
        #expect(store.files?.rows.map(\.value) == ["tried 1 of 3 times"])
        #expect(store.files?.rows.first?.reason == "the model never answered")

        // A click goes to the existing door (showInCatalog(recordID:), pinned by the
        // sensor below); not invoked here — it writes the host's real `selectedTab`
        // default and raises windows. Its guard accepts the rows of catalog files,
        // and the in-progress digest that is not in the catalog has no record to reveal.
        #expect(model.canNavigateToRecord(id: try #require(found.recordID)))
        #expect(model.canNavigateToRecord(id: try #require(gave.recordID)))
        #expect(store.files?.rows.first?.recordID == nil)
        #expect(!store.reveal(try #require(store.files?.rows.first)))
        #expect(store.revealProblem?.contains("is not in this session's catalog") == true)

        // Read-only: nothing written anywhere.
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == rowsBefore)
        #expect(await repository.generation == generationBefore)
        #expect(try Data(contentsOf: EraAttemptStore.url(stateRoot: root)) == attemptsBytes)
        await closeScene(model)
    }

    @Test("LOGIC: a failed read is said in place of the numbers, and logged once")
    func aFailedReadSaysSo() async {
        var lines: [String] = []
        let store = AnalysisResultsStore(loadReport: { throw Refusal("catalog.sqlite is not open in this session") },
                                         loadFiles: { _, _ in throw Refusal("unreachable") },
                                         reveal: { _ in true }, note: { lines.append($0) })
        await store.load()
        #expect(store.report == nil && store.files == nil)
        #expect(store.failure == "catalog.sqlite is not open in this session")
        #expect(lines.count == 1 && lines[0].contains("could not be read"))
    }

    @Test("LOGIC: the seated analyzer comes first; switching analyzer reloads its list; a row not in the catalog says why")
    func selectionAndReveal() async {
        let older = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r2"
        let report = AnalysisResultsReport(analyzers: [
            .init(signer: seatedBy, modelShortName: "8B", isSeated: true, analyzed: 1, eraFound: 1, eraNone: 0, gaveUp: 0,
                  triesInProgress: 0, stillToDo: 0, agreement: .init(total: 0, agree: 0), rate: .init(lastHour: 0, last24Hours: 0)),
            .init(signer: older, modelShortName: "8B", isSeated: false, analyzed: 2, eraFound: 0, eraNone: 2, gaveUp: 0,
                  triesInProgress: nil, stillToDo: nil, agreement: .init(total: 0, agree: 0), rate: .init(lastHour: 0, last24Hours: 0)),
        ], builtAt: 1)
        let row = AnalysisResultsReport.FileRow(digest: "d", recordID: UUID(), filename: "Gone.mov", path: "/V/Gone.mov", removed: true,
                                                value: "no usable era", reason: "r")
        let store = AnalysisResultsStore(
            loadReport: { report },
            loadFiles: { signer, outcome in .init(signer: signer, outcome: outcome, rows: signer == older ? [row] : [], truncated: false) },
            reveal: { _ in false })
        await store.load()
        #expect(store.analyzer?.signer == seatedBy && store.files?.rows.isEmpty == true)
        await store.select(signer: older)
        #expect(store.files?.signer == older && store.files?.rows == [row])
        #expect(!store.reveal(row))
        #expect(store.revealProblem == "Gone.mov is not in this session's catalog (every copy was removed from the catalog) — nothing to show")
    }

    @Test("LOGIC: a list request that lands after a newer one is dropped")
    func aStaleListIsDropped() async throws {
        let report = AnalysisResultsReport(analyzers: [
            .init(signer: seatedBy, modelShortName: "8B", isSeated: true, analyzed: 0, eraFound: 0, eraNone: 0, gaveUp: 0,
                  triesInProgress: 0, stillToDo: 0, agreement: .init(total: 0, agree: 0), rate: .init(lastHour: 0, last24Hours: 0)),
        ], builtAt: 1)
        let store = AnalysisResultsStore(
            loadReport: { report },
            loadFiles: { signer, outcome in
                if outcome == .eraNone { try await Task.sleep(for: .milliseconds(300)) }       // the slow, older request
                return .init(signer: signer, outcome: outcome, rows: [], truncated: false)
            },
            reveal: { _ in true })
        await store.load()
        let slow = Task { await store.select(outcome: .eraNone) }
        try await Task.sleep(for: .milliseconds(50))
        await store.select(outcome: .gaveUp)
        await slow.value
        #expect(store.outcome == .gaveUp)
        #expect(store.files?.outcome == .gaveUp, "the older eraNone list landed later and was dropped")
        #expect(!store.filesLoading)
    }
}

@Suite("Content Analysis ▸ Results — source sensors")
struct AnalysisResultsSheetSensorTests {

    private func code(_ file: String) throws -> String {
        try SourceTree.appSource(named: file).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records", "for rec in records",
                                "records.reduce", "records.first", "records.count", "records.contains"]

    @Test func theSheetAndTheStoreDoNoRecordsWork() throws {
        for file in ["AnalysisResultsSheet.swift", "AnalysisResultsStore.swift"] {
            let src = try code(file)
            for walk in recordsWalks { #expect(!src.contains(walk), "\(file) walks records: `\(walk)`") }
        }
        // The sheet reads the store only — never the model.
        #expect(!(try code("AnalysisResultsSheet.swift")).contains("model."))
    }

    @Test func theStoreHoldsNoSQLAndNeverWrites() throws {
        let src = try code("AnalysisResultsStore.swift")
        for forbidden in ["SELECT ", "INSERT", "UPDATE ", "DELETE", "writeBlocking", ".write(as", "EraAttemptStore(", "record(digest", "clear(digest"] {
            #expect(!src.contains(forbidden), "AnalysisResultsStore must stay read-only: `\(forbidden)`")
        }
        #expect(src.contains("repository.read {"), "reads through the session's repository reader")
        #expect(src.contains("AnalysisResultsReport.readAttempts"), "the try counts through the read-only snapshot")
        #expect(src.contains("Task.detached"), "loads off the main actor")
    }

    @Test func noModelExtensionAndRevealIsTheExistingDoor() throws {
        for file in ["AnalysisResultsSheet.swift", "AnalysisResultsStore.swift"] {
            #expect(!(try code(file)).contains("extension VideoScanModel"), "rule 12: \(file)")
        }
        let store = try code("AnalysisResultsStore.swift")
        #expect(store.contains("model.showInCatalog(recordID: id)") && store.contains("canNavigateToRecord(id: id)"))
        #expect(!store.contains("pendingCatalogSelection ="), "one reveal engine (rule 4): no hand-rolled navigation")
    }

    @Test func thePanelOpensTheSheet() throws {
        let panel = try code("AnalyzePanelView.swift")
        #expect(panel.contains("Button(\"Results…\")"))
        #expect(panel.contains("AnalysisResultsSheet(store: AnalysisResultsStore.production(model: model))"))
    }
}
