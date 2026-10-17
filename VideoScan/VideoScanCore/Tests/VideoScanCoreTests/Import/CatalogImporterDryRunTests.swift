// CatalogImporterDryRunTests.swift
// The dry run (app wiring, 2026-10-17): the IDENTICAL flow — gate, one
// transaction, rows, sidecars, comparator — and then ALWAYS a roll back.
// Its database lives in a scratch folder the importer owns and removes;
// the inputs' own target is never touched. A miss reads the same as in a
// real run; a Stop between phases rolls back with its own outcome. And the
// "" → NULL pin: Rick's catalog has 763 rows whose `contentHash` is the
// empty string; the DDL's GLOB refuses "" in `files.sampled_hash`, so the
// DTO must map it to nil and the row must land in `files`.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporter — dry run")
struct CatalogImporterDryRunTests {

    // MARK: - Logic

    @Test func aDryRunPassesWithTheSameLineARealRunWouldPrint() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        let report = try #require(dry.outcome.dryRunReport, Comment(rawValue: "\(dry.outcome)"))
        let real = await scene.run()
        let reconciliation = try #require(real.outcome.reconciliation)
        #expect(report.reconciliation.line == reconciliation.line)
        #expect(report.reconciliation.rowsQuarantine == 12)
    }

    @Test func aDryRunCarriesTheQuarantineWordsCappedAtTheSample() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        let report = try #require(dry.outcome.dryRunReport)
        #expect(report.quarantineSample.count == 12)
        #expect(report.quarantineSample.map(\.ordinal) == report.quarantineSample.map(\.ordinal).sorted())
        let deadLink = try #require(scene.fixture.ordinals(of: .deadLink).first)
        let sample = try #require(report.quarantineSample.first { $0.ordinal == deadLink })
        #expect(sample.reasonCode == CatalogDDL.ReasonCode.auditCouldNotCheck.rawValue)
        #expect(sample.words == ImportGate.Words.auditCouldNotCheck)
        #expect(CatalogImporter.quarantineSampleCap == 200)
    }

    @Test func aDryRunWritesNothingToTheInputsTargetAndRemovesItsScratch() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let importer = scene.makeImporter()
        let outcome = await importer.run(scene.inputs, mode: .dryRun)
        #expect(outcome.dryRunReport != nil)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        let scratch = try #require(await importer.lastDryRunScratch)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
        #expect(scratch.path != scene.databaseFolder.path)
        // The target is still empty: a real run into it is not refused.
        let real = await scene.run()
        #expect(real.outcome.reconciliation != nil)
    }

    @Test func aDryRunLogsStartAndADryRunOutcomeThroughTheSink() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let dry = await scene.run(mode: .dryRun)
        let report = try #require(dry.outcome.dryRunReport)
        let lines = scene.sink.lines
        #expect(lines.first?.hasPrefix("START import (dry run) ") == true)
        #expect(lines.last == "OUTCOME dry run passed — nothing written · " + report.reconciliation.line)
    }

    @Test func aMissInADryRunRollsBackAndNamesItAndTheScratchIsGone() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let ordinal = try #require(scene.fixture.ordinals(of: .curatedConflictA).first)
        let importer = scene.makeImporter()
        await importer.injectComparatorSeam({ side in
            side.knowledgeSources.removeAll { $0.ordinal == ordinal && $0.field == .starRating }
        })
        let outcome = await importer.run(scene.inputs, mode: .dryRun)
        #expect(outcome.misses == [.curatedValueMissing(ordinal: ordinal, field: .starRating)])
        let scratch = try #require(await importer.lastDryRunScratch)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func aGateRefusalInADryRunIsTheSameRefusal() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        try scene.overwrite(PoisonedCatalogFixture.catalogFileName, with: scene.fixture.catalogData + Data(" ".utf8))
        let dry = await scene.run(mode: .dryRun)
        #expect(dry.outcome.refusalKinds == [.reportHashMismatch])
    }

    // MARK: - Stop

    @Test func aStopRequestedBeforeTheTargetOpensEndsStoppedWithNothingWritten() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run(stopRequested: { true })
        #expect(run.outcome == .stopped)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sink.lines.last == "OUTCOME stopped · nothing written")
    }

    @Test func aStopRequestedDuringTheRowsRollsTheTransactionBack() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let flag = StopFlag()
        let importer = scene.makeImporter()
        // The decode seam runs at the start of the row pass: raise the flag
        // there, so the first stop check (after the rows) sees it.
        await importer.injectDecodeSeam({ flag.raise() })
        let outcome = await importer.run(scene.inputs, stopRequested: { flag.isRaised })
        #expect(outcome == .stopped)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.isEmpty)
        let generation = try await scene.read { $0.generation }
        #expect(generation == 0)
    }

    // MARK: - "" → NULL (Rick's 763 rows)

    @Test func anEmptyContentHashMapsToANilSampledHash() throws {
        let data = try JSONSerialization.data(withJSONObject: ["id": "A", "sizeBytes": 10, "contentHash": ""])
        let record = try JSONDecoder().decode(VideoRecordJSON.self, from: data)
        #expect(record.contentHash?.isEmpty == true)
        let dto = CatalogRecordDTO(record: record, migrationLoadedAt: 0)
        #expect(dto.file.sampledHash == nil)
        #expect(dto.file.sampledHashAt == nil)
    }

    @Test func aRowWithAnEmptyContentHashLandsInFiles() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let healthy = try #require(scene.fixture.ordinals(of: .healthy).first)
        try scene.poisonCatalog { records in records[healthy]["contentHash"] = .string("") }
        let run = await scene.run()
        let reconciliation = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        #expect(reconciliation.rowsMain == 5)
        let landing = try await scene.read { reader -> CatalogRow.RowLanding? in
            var found: CatalogRow.RowLanding?
            try reader.rowLandings(run: run.runID) { if $0.ordinal == healthy { found = $0 } }
            return found
        }
        #expect(landing?.landedTable == .files)
    }
}

/// A flag a seam raises and a stop check reads. (For Rick: an atomic bool.)
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}
