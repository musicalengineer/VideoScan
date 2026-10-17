// ImportToSQLiteTests.swift
// Import to SQLite as an MFO job (Rick 2026-10-17, catalog_sqlite_migration
// §10c "app wiring") — the five dimensions plus TRUTH:
//   LOGIC     — every pre-flight refusal, pure, with its words; the dry-run
//               marker's gate (passed at N enables commit at N only); the
//               rows subtitle.
//   ISOLATION — every job test runs on a sandboxed catalog folder holding
//               the Core's poisoned fixture (never the shared store); a save
//               attempted mid-run is REFUSED with words and the catalog file
//               is unchanged by hash (poisoned state: the one writer rule).
//   SENSOR    — START and OUTCOME through the one sink for every ending
//               (passed, imported, refused, stopped); the kind is in the
//               registry; the job's sources hold and release the store's
//               writes and never save the catalog themselves.
//   TRUTH     — a dry run writes NOTHING beside the catalog (no
//               catalog.sqlite, the catalog's hash unchanged) and the real
//               import's line equals the dry run's.
// SCALE: the importer's own 100k test (CatalogImporterScaleTests) covers the
// work; nothing here iterates records. MEDIA MATRIX: N/A — no media is opened.
//
// Suites (filter by SUITE): ImportToSQLitePreflightTests ·
// ImportDryRunMarkerTests · ImportToSQLiteJobTests · ImportToSQLiteSensorTests

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Logic: the pre-flight

@Suite("Import to SQLite — pre-flight refusals")
struct ImportToSQLitePreflightTests {

    private func clear(mode: CatalogImporter.Mode = .dryRun) -> ImportToSQLitePreflight {
        ImportToSQLitePreflight(mode: mode, hasUnsavedChanges: false, runningJobs: [], catalogGeneration: 41,
                                report: .generation(41), audit: .rows(true), targetExists: false)
    }

    @Test func allClearHasNoRefusal() {
        #expect(clear().refusals.isEmpty)
    }

    @Test func unsavedChangesRefuse() {
        var p = clear(); p.hasUnsavedChanges = true
        #expect(p.refusals.map(\.kind) == [.unsavedChanges])
        #expect(p.refusals.first?.words == "the catalog has unsaved changes — wait a few seconds for the save, then try again")
    }

    @Test func anotherJobRunningRefusesAndNamesIt() {
        var p = clear(); p.runningJobs = ["Verify catalog"]
        #expect(p.refusals.map(\.kind) == [.anotherJobRunning])
        #expect(p.refusals.first?.words.hasPrefix("Verify catalog is running — one job at a time while the catalog is read") == true)
    }

    @Test func aReportOlderThanTheCatalogRefusesWithBothGenerations() {
        var p = clear(); p.report = .generation(40)
        #expect(p.refusals.map(\.kind) == [.reportStale])
        #expect(p.refusals.first?.words == "the Verify Catalog report describes generation 40; the catalog is at generation 41 — run Audit Catalog, then Verify Catalog, then try again")
    }

    @Test func aReportWithoutAGenerationIsStale() {
        var p = clear(); p.report = .generation(nil)
        #expect(p.refusals.first?.words.contains("describes an unknown generation") == true)
    }

    @Test func aMissingOrUnreadableReportRefuses() {
        var missing = clear(); missing.report = .missing
        #expect(missing.refusals.map(\.kind) == [.reportMissing])
        var unreadable = clear(); unreadable.report = .unreadable("damaged")
        #expect(unreadable.refusals.first?.words == "the Verify Catalog report can't be read (damaged) — run Audit Catalog, then Verify Catalog, then try again")
    }

    @Test func anAuditWithoutPerRowResultsRefuses() {
        var p = clear(); p.audit = .rows(false)
        #expect(p.refusals.map(\.kind) == [.auditNoRowResults])
        #expect(p.refusals.first?.words == "the last Audit Catalog carries no per-row results (a run from before this build) — run Audit Catalog, then Verify Catalog, then try again")
    }

    @Test func aMissingAuditRefuses() {
        var p = clear(); p.audit = .missing
        #expect(p.refusals.map(\.kind) == [.auditMissing])
    }

    @Test func anExistingTargetRefusesInCommitModeOnly() {
        var commit = clear(mode: .commit); commit.targetExists = true
        #expect(commit.refusals.map(\.kind) == [.targetExists])
        #expect(commit.refusals.first?.words == "catalog.sqlite already exists beside the catalog — move it aside first; nothing was written")
        var dry = clear(mode: .dryRun); dry.targetExists = true
        #expect(dry.refusals.isEmpty)
    }

    @Test func everyRefusalIsListedInFixOrder() {
        var p = clear(mode: .commit)
        p.hasUnsavedChanges = true; p.runningJobs = ["Audit catalog"]; p.report = .generation(3); p.audit = .rows(false); p.targetExists = true
        #expect(p.refusals.map(\.kind) == [.unsavedChanges, .anotherJobRunning, .reportStale, .auditNoRowResults, .targetExists])
    }

    @Test func theRowsLineBecomesTheSubtitle() {
        #expect(ImportToSQLiteJob.rowsSubtitle("rows 13793: main 13581 · quarantine 212 (auditChanged 3, noWholeFileDigest 209)")
                == "rows 13793 · main 13581 · quarantine 212")
    }
}

// MARK: - Logic: the marker's gate

@Suite("Import to SQLite — the dry-run marker")
@MainActor
struct ImportDryRunMarkerTests {

    @Test func aDryRunPassedAtNEnablesCommitAtNOnly() {
        let passed = ImportDryRunRecord(passedAt: Date(), catalogGeneration: 41, reconciliationLine: "rows before 17")
        #expect(ImportDryRunMarker.enablesCommit(passed, catalogGeneration: 41))
        #expect(!ImportDryRunMarker.enablesCommit(passed, catalogGeneration: 42))
        #expect(!ImportDryRunMarker.enablesCommit(passed, catalogGeneration: 40))
        #expect(!ImportDryRunMarker.enablesCommit(nil, catalogGeneration: 41))
    }

    @Test func theMarkerRoundTripsBesideTheCatalogAndNowhereElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-dryrun-marker-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json").path
        let marker = ImportDryRunMarker()
        #expect(marker.attach(catalogFile: catalog) == nil)
        let record = ImportDryRunRecord(passedAt: Date(timeIntervalSince1970: 1_760_700_000), catalogGeneration: 7, reconciliationLine: "rows before 3")
        marker.notePassed(record)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ImportDryRunMarker.fileName).path))
        let again = ImportDryRunMarker()
        #expect(again.attach(catalogFile: catalog) == record)
    }

    @Test("the marker never touches UserDefaults (source sensor)")
    func theMarkerNeverTouchesUserDefaults() throws {
        let source = try ImportToSQLiteSensorTests.code("MediaOps/ImportDryRunMarker.swift")   // comments stripped: the header names UserDefaults on purpose
        #expect(!source.contains("UserDefaults"))
        #expect(source.components(separatedBy: "AtomicFilePublish.write(").count == 2, "one writer, the marker file")
    }

    @Test func aDamagedMarkerReadsAsNone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-dryrun-damaged-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(ImportDryRunMarker.fileName))
        #expect(ImportDryRunMarker().attach(catalogFile: dir.appendingPathComponent("catalog.json").path) == nil)
    }
}

// MARK: - The job (sandboxed catalog folder, the poisoned fixture, a real store)

@MainActor
struct ImportScene {
    let sandbox: ShowAgainSandbox
    let fixture = PoisonedCatalogFixture()

    var catalogURL: URL { URL(fileURLWithPath: sandbox.model.catalogStore.fileLocation) }
    var folder: URL { catalogURL.deletingLastPathComponent() }
    var databaseURL: URL { folder.appendingPathComponent(CatalogImporter.Inputs.databaseFileName) }

    static func make(_ label: String) throws -> ImportScene {
        let sb = try ShowAgainSandbox.make("import_\(label)")
        let scene = ImportScene(sandbox: sb)
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        for (name, data) in scene.fixture.files {
            try data.write(to: scene.folder.appendingPathComponent(name), options: .atomic)
        }
        return scene
    }

    func cleanup() { sandbox.cleanup() }

    func overwrite(_ name: String, _ data: Data) throws {
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    func catalogHash() throws -> String {
        SHA256.hash(data: try Data(contentsOf: catalogURL)).map { String(format: "%02x", $0) }.joined()
    }

    func job(_ mode: CatalogImporter.Mode, runningJobs: [String] = []) -> ImportToSQLiteJob {
        ImportToSQLiteJob(model: sandbox.model, mode: mode, runningJobs: runningJobs, gateEnvironment: { CatalogImporter.Environment() })
    }

    func run(_ mode: CatalogImporter.Mode, runningJobs: [String] = [],
             configure: (ImportToSQLiteJob) -> Void = { _ in }) async -> ImportToSQLiteJob {
        let job = job(mode, runningJobs: runningJobs)
        configure(job)
        job.start()
        await job.task?.value
        return job
    }

    func log() -> String { sandbox.catalogLogText() }
}

@Suite("Import to SQLite — the job", .serialized)
@MainActor
struct ImportToSQLiteJobTests {

    @Test("TRUTH: a dry run passes on the fixture, the row's summary IS the reconciliation line prefixed DRY RUN, the marker names the file's generation, nothing is written beside the catalog, START / OUTCOME go through the sink, the hold is released")
    func aDryRunPassesAndWritesNothing() async throws {
        let scene = try ImportScene.make("dry"); defer { scene.cleanup() }
        let before = try scene.catalogHash()
        let job = await scene.run(.dryRun)
        guard case .finished(let summary) = job.state else { Issue.record("expected finished, got \(job.state)"); return }
        #expect(summary.hasPrefix(ImportToSQLiteJob.dryRunPrefix + "rows before 17 · main 5 (live 4, tombstoned 1) · quarantine 12"), Comment(rawValue: summary))
        #expect(job.reconciliation?.rowsQuarantine == 12)
        #expect(job.quarantineSample.count == 12)
        #expect(job.phase == .done)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(try scene.catalogHash() == before)
        let marker = scene.sandbox.model.importDryRunMarker.lastPassed
        #expect(marker?.catalogGeneration == PoisonedCatalogFixture.generation)
        #expect(marker?.reconciliationLine == job.reconciliation?.line)
        #expect(FileManager.default.fileExists(atPath: scene.folder.appendingPathComponent(ImportDryRunMarker.fileName).path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        let log = scene.log()
        #expect(log.contains("Import to SQLite: START — DRY RUN"), Comment(rawValue: log))
        #expect(log.contains("Import to SQLite: importer: START import (dry run)"))
        #expect(log.contains("Import to SQLite: OUTCOME dry run passed — nothing written — rows before 17"))
    }

    @Test("a real import commits catalog.sqlite beside the catalog with the SAME line the dry run printed; the quarantine words are read back")
    func aRealImportCommitsTheSameLine() async throws {
        let scene = try ImportScene.make("commit"); defer { scene.cleanup() }
        let dry = await scene.run(.dryRun)
        let real = await scene.run(.commit)
        guard case .finished(let summary) = real.state else { Issue.record("expected finished, got \(real.state)"); return }
        #expect(summary == dry.reconciliation?.line)
        #expect(real.databaseURL == scene.databaseURL)
        #expect(FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(real.quarantineSample.map(\.ordinal) == dry.quarantineSample.map(\.ordinal))
        #expect(scene.log().contains("Import to SQLite: OUTCOME imported — rows before 17"))
    }

    @Test("pre-flight: unsaved catalog changes refuse before any work, with the words in the row")
    func unsavedChangesRefuseTheJob() async throws {
        let scene = try ImportScene.make("unsaved"); defer { scene.cleanup() }
        scene.sandbox.model.saveCatalogDebounced()
        #expect(scene.sandbox.model.catalogStore.hasUnsavedChanges)
        let job = await scene.run(.dryRun)
        #expect(job.wasRefused)
        #expect(job.refusals == ["the catalog has unsaved changes — wait a few seconds for the save, then try again"])
        #expect(scene.log().contains("Import to SQLite: OUTCOME refused — the catalog has unsaved changes"))
        #expect(!scene.log().contains("importer: START"), "the importer never ran")
    }

    @Test("pre-flight: another MFO job running refuses and names it")
    func anotherJobRefuses() async throws {
        let scene = try ImportScene.make("busy"); defer { scene.cleanup() }
        let job = await scene.run(.commit, runningJobs: ["Verify catalog"])
        #expect(job.wasRefused)
        #expect(job.refusals.first?.hasPrefix("Verify catalog is running") == true)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
    }

    @Test("pre-flight: a Verify Catalog report older than the catalog's generation refuses with both generations")
    func staleReportRefuses() async throws {
        let scene = try ImportScene.make("stale"); defer { scene.cleanup() }
        var report = try IntegrityReportJSON.decode(scene.fixture.integrityData)
        report.snapshotGeneration = PoisonedCatalogFixture.generation - 1
        try scene.overwrite(PoisonedCatalogFixture.integrityFileName, try CatalogJSONValue.makeEncoder().encode(report))
        let job = await scene.run(.dryRun)
        #expect(job.wasRefused)
        #expect(job.refusals == ["the Verify Catalog report describes generation 40; the catalog is at generation 41 — run Audit Catalog, then Verify Catalog, then try again"])
    }

    @Test("pre-flight: an audit marker without per-row results refuses — run Audit Catalog, then Verify Catalog, then try again")
    func auditWithoutRowsRefuses() async throws {
        let scene = try ImportScene.make("norows"); defer { scene.cleanup() }
        var marker = try AuditMarkerJSON.decode(scene.fixture.auditData)
        marker.rows = nil
        try scene.overwrite(PoisonedCatalogFixture.auditFileName, try CatalogJSONValue.makeEncoder().encode(marker))
        let job = await scene.run(.dryRun)
        #expect(job.wasRefused)
        #expect(job.refusals == ["the last Audit Catalog carries no per-row results (a run from before this build) — run Audit Catalog, then Verify Catalog, then try again"])
    }

    @Test("pre-flight: catalog.sqlite already beside the catalog refuses a real import and leaves it alone; a dry run does not care")
    func existingTargetRefuses() async throws {
        let scene = try ImportScene.make("target"); defer { scene.cleanup() }
        try Data("not a database".utf8).write(to: scene.databaseURL)
        let commit = await scene.run(.commit)
        #expect(commit.wasRefused)
        #expect(commit.refusals == ["catalog.sqlite already exists beside the catalog — move it aside first; nothing was written"])
        #expect(try Data(contentsOf: scene.databaseURL) == Data("not a database".utf8))
        let dry = await scene.run(.dryRun)
        #expect(dry.state == .finished(summary: dry.subtitle))
    }

    @Test("ISOLATION (poisoned state): a save attempted while the import runs is refused with words, the catalog file is unchanged by hash, and the held save is caught up when the job lets go")
    func aSaveDuringTheRunIsRefused() async throws {
        let scene = try ImportScene.make("hold"); defer { scene.cleanup() }
        let before = try scene.catalogHash()
        let model = scene.sandbox.model
        model.records.append(VideoRecord())                          // the model's rows are NOT the fixture's: a save would clobber it
        var saveResult: Bool?
        var holdSeen: String?
        let job = await scene.run(.dryRun) { job in
            job.onImporterLineForTesting = { line in
                guard line.hasPrefix("rows "), saveResult == nil else { return }
                holdSeen = model.catalogStore.writeHold
                saveResult = model.saveCatalogNow()
            }
        }
        #expect(job.state == .finished(summary: job.subtitle), Comment(rawValue: job.subtitle))
        #expect(saveResult == false)
        #expect(holdSeen == ImportToSQLiteJob.holdReason)
        #expect(model.catalogStore.lastWriteError == .heldByJob(ImportToSQLiteJob.holdReason))
        #expect(try scene.catalogHash() == before)
        #expect(model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("1 catalog save(s) were held while the catalog was being read — saving now"))
    }

    @Test("the store's hold: every write door refuses with .heldByJob and its words, nothing lands; releasing returns the count; the next save lands")
    func theStoreHoldRefusesEveryDoor() async throws {
        let sb = try ShowAgainSandbox.make("import_doors"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        let file = store.fileLocation
        store.holdWrites(reason: "a test job")
        #expect(store.saveNow(records: []) == false)
        #expect(await store.saveAcknowledged(records: []) == false)
        #expect(store.lastWriteError == .heldByJob("a test job"))
        #expect(store.lastWriteError?.userFacingDescription == "Catalog saving is paused while a test job. The change is kept in memory and saved when the job finishes.")
        #expect(!FileManager.default.fileExists(atPath: file), "nothing landed while held")
        #expect(store.writeHold == "a test job")
        #expect(store.releaseWriteHold() == 2)
        #expect(store.writeHold == nil)
        #expect(store.saveNow(records: []) == true)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test("Stop before the gate: the row ends Stopped, the target is absent, OUTCOME says stopped")
    func stopBeforeTheGate() async throws {
        let scene = try ImportScene.make("stop0"); defer { scene.cleanup() }
        let job = scene.job(.commit)
        job.start()
        job.cancel()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.log().contains("Import to SQLite: OUTCOME stopped"), Comment(rawValue: scene.log()))
    }

    @Test("Stop during the transaction: the importer rolls back at its next step — Stopped, never Done; the target is absent")
    func stopDuringTheRun() async throws {
        let scene = try ImportScene.make("stop1"); defer { scene.cleanup() }
        let job = await scene.run(.commit) { job in
            job.onImporterLineForTesting = { [weak job] line in
                if line.hasPrefix("START import") { job?.cancel() }
            }
        }
        #expect(job.state == .cancelled, Comment(rawValue: job.subtitle))
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.log().contains("importer: OUTCOME stopped · nothing written"))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
    }
}

// MARK: - Sensors

@Suite("Import to SQLite — sensors")
struct ImportToSQLiteSensorTests {

    static func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("MOPS-16: the job holds the store's writes before the importer runs and releases them after; it never saves the catalog itself; the only sink is importToSQLiteNote")
    func theJobHoldsAndReleasesTheOneWriter() throws {
        let job = try Self.code("MediaOps/ImportToSQLiteJob.swift")
        #expect(job.components(separatedBy: "catalogStore.holdWrites(").count == 2)
        #expect(job.components(separatedBy: "catalogStore.releaseWriteHold()").count == 2)
        let hold = try #require(job.range(of: "catalogStore.holdWrites("))
        let importer = try #require(job.range(of: "await runImporter("))
        let release = try #require(job.range(of: "catalogStore.releaseWriteHold()"))
        #expect(hold.lowerBound < importer.lowerBound && importer.lowerBound < release.lowerBound)
        #expect(!job.contains("saveCatalogNow(") && !job.contains("saveCatalogAcknowledged("))
        #expect(job.components(separatedBy: "func importToSQLiteNote(").count == 2)
        #expect(job.contains("log(\"Import to SQLite: \" + line)") && job.contains("appLog.write(\"[import-sqlite] \" + line)"))
        for call in ["removeItem(", "trashItem(", "moveItem(", "Process(", "ProcessRunner", "AVAsset"] {
            #expect(!job.contains(call), "the job contains \(call)")
        }
    }

    @Test("the store's precondition checks the hold before the lock; the menu passes the marker and the store's generation; the kind is registered")
    func shapeOfTheWiring() throws {
        let store = try Self.code("Catalog/CatalogStore.swift")
        let hold = try #require(store.range(of: "if let hold = writeHold {"))
        let lock = try #require(store.range(of: "switch lock.acquire() {"))
        #expect(hold.lowerBound < lock.lowerBound)
        let app = try SourceTree.appSource(named: "VideoScanApp.swift")
        #expect(app.contains("ImportToSQLiteMenuItems(model: catalogModel, center: fileOpsCenter, marker: catalogModel.importDryRunMarker"))
        #expect(app.contains("catalogModel?.attachImportDryRunMarker()"))
        let marker = try Self.code("MediaOps/ImportDryRunMarker.swift")
        #expect(marker.contains("importDryRunMarker.attach(catalogFile: catalogStore.fileLocation)"))
        #expect(MediaFileOperationKind.all.contains(.importToSQLite))
        #expect(MediaFileOperationKind.importToSQLite.hasDetailView)
        let content = try SourceTree.appSource(named: "ContentView.swift")
        #expect(content.contains(".sheet(item: $model.importToSQLiteConfirm)"))
    }
}
