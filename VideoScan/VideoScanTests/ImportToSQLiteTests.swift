// ImportToSQLiteTests.swift
// Import to SQLite as ONE MFO job in three phases inside one write hold
// (Rick 2026-10-17, catalog_sqlite_migration §10c "app wiring"; "one action
// verb" the same evening) — the five dimensions plus TRUTH:
//   LOGIC     — every pre-flight refusal, pure, with its words; a phase
//               job's terminal state → the import's verdict; the wait before
//               Verify (the gate's time-order rule); the dry-run marker's
//               gate (this build enables commit at ANY generation, another
//               build or no build disables it); the rows subtitle.
//   ISOLATION — every job test runs on a sandboxed catalog folder with real
//               small files (never the shared store, nothing under
//               ~/Library: the audit's lane is the sandbox, Verify gets no
//               shared events); a background save attempted in EACH phase is
//               REFUSED, the generation does not move and catalog.json's
//               hash changes only by the audit's own save (poisoned state:
//               the one writer rule with an owner token).
//   SENSOR    — START, the phase lines and OUTCOME through the one sink;
//               the job's sources hold and release the store's writes around
//               the three phases and never save the catalog themselves; the
//               audit saves with the owner token; the store checks the hold
//               (owner token) before the lock.
//   TRUTH     — the three phases run in order and describe ONE generation:
//               the audit's save → Verify's snapshot → the importer's file;
//               a dry run writes no catalog.sqlite; Stop in any phase imports
//               nothing and releases the hold.
// SCALE: the importer's own 100k test (CatalogImporterScaleTests) and the
// audit's (CatalogAuditJobTests) cover the work; nothing here iterates
// records beyond the sandbox's few. MEDIA MATRIX: N/A — no media is opened
// (the audit stats; the importer reads JSON).
//
// Suites (filter by SUITE): ImportToSQLitePreflightTests ·
// ImportDryRunMarkerTests · ImportToSQLiteHoldTests · ImportToSQLiteJobTests ·
// ImportToSQLiteSensorTests

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Logic: the pre-flight, the verdicts, the wait

@Suite("Import to SQLite — pre-flight refusals and phase logic")
struct ImportToSQLitePreflightTests {

    private func clear(mode: CatalogImporter.Mode = .dryRun) -> ImportToSQLitePreflight {
        ImportToSQLitePreflight(mode: mode, hasUnsavedChanges: false, runningJobs: [], catalogGeneration: 41, targetExists: false)
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

    @Test func anExistingTargetRefusesInCommitModeOnly() {
        var commit = clear(mode: .commit); commit.targetExists = true
        #expect(commit.refusals.map(\.kind) == [.targetExists])
        #expect(commit.refusals.first?.words == "catalog.sqlite already exists beside the catalog — move it aside first; nothing was written")
        var dry = clear(mode: .dryRun); dry.targetExists = true
        #expect(dry.refusals.isEmpty)
    }

    @Test func everyRefusalIsListedInFixOrder() {
        var p = clear(mode: .commit)
        p.hasUnsavedChanges = true; p.runningJobs = ["Audit catalog"]; p.targetExists = true
        #expect(p.refusals.map(\.kind) == [.unsavedChanges, .anotherJobRunning, .targetExists])
    }

    @Test func theRowsLineBecomesTheSubtitle() {
        #expect(ImportToSQLiteJob.rowsSubtitle("rows 13793: main 13581 · quarantine 212 (auditChanged 3, noWholeFileDigest 209)")
                == "rows 13793 · main 13581 · quarantine 212")
    }

    @Test("a phase job's terminal state: finished goes on, Stop stops, a failure stops the import with the phase's own words")
    func phaseVerdicts() {
        #expect(ImportPhaseVerdict.of(.finished(summary: "ok"), step: "the audit") == .proceed)
        #expect(ImportPhaseVerdict.of(.cancelled, step: "the audit") == .stopped)
        #expect(ImportPhaseVerdict.of(.cancelling, step: "the audit") == .stopped)
        #expect(ImportPhaseVerdict.of(.failed(message: "Refused — read-only"), step: "the audit")
                == .couldNotComplete("the audit could not complete: Refused — read-only"))
        #expect(ImportPhaseVerdict.of(.running, step: "Verify Catalog") == .couldNotComplete("Verify Catalog did not finish"))
    }

    @Test("Verify starts no earlier than the audit's finishing second + 1.5 s (the gate refuses finishedAt >= report start, whole seconds)")
    func theWaitBeforeVerify() {
        let finished = Date(timeIntervalSince1970: 1_000.2)
        #expect(abs(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_000.3)) - 1.2) < 1e-6)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_001.5)) == 0)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: finished, now: Date(timeIntervalSince1970: 1_005)) == 0)
        let lateInSecond = Date(timeIntervalSince1970: 1_000.99)
        #expect(ImportToSQLiteTiming.verifyStartDelay(auditFinishedAt: lateInSecond, now: lateInSecond) < 0.52)
    }
}

// MARK: - Logic: the marker's gate (this build)

@Suite("Import to SQLite — the dry-run marker")
@MainActor
struct ImportDryRunMarkerTests {

    private func record(generation: Int, build: String?) -> ImportDryRunRecord {
        ImportDryRunRecord(passedAt: Date(timeIntervalSince1970: 1_760_700_000), catalogGeneration: generation,
                           reconciliationLine: "rows before 17", build: build)
    }

    @Test("a dry run that passed on THIS build enables the real import at any catalog generation (the real run re-proves everything)")
    func thisBuildEnablesCommitAtAnyGeneration() {
        let older = record(generation: 4_881, build: ImportBuildIdentity.current)
        #expect(ImportDryRunMarker.enablesCommit(older, build: ImportBuildIdentity.current))
    }

    @Test func anotherBuildDisablesCommit() {
        let other = record(generation: 4_881, build: "999 · 00000000-0000-0000-0000-000000000000")
        #expect(!ImportDryRunMarker.enablesCommit(other, build: ImportBuildIdentity.current))
    }

    @Test func noMarkerOrNoBuildDisablesCommit() {
        #expect(!ImportDryRunMarker.enablesCommit(nil, build: ImportBuildIdentity.current))
        #expect(!ImportDryRunMarker.enablesCommit(record(generation: 1, build: nil), build: ImportBuildIdentity.current))
        #expect(!ImportDryRunMarker.enablesCommit(record(generation: 1, build: ""), build: ""))
    }

    @Test("this build's identity: CFBundleVersion and the image's Mach-O UUID")
    func theBuildIdentityNamesTheImage() {
        let parts = ImportBuildIdentity.current.components(separatedBy: " · ")
        #expect(parts.count == 2)
        #expect(UUID(uuidString: parts.last ?? "") != nil, Comment(rawValue: ImportBuildIdentity.current))
    }

    @Test("a marker written before the build was recorded decodes, with no build")
    func anOlderMarkerDecodesWithoutABuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-dryrun-old-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = #"{"catalogGeneration":4881,"passedAt":"2026-10-17T22:59:58Z","reconciliationLine":"rows before 13793"}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent(ImportDryRunMarker.fileName))
        let read = ImportDryRunMarker().attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        #expect(read?.catalogGeneration == 4_881)
        #expect(read?.build == nil)
    }

    @Test func theMarkerRoundTripsBesideTheCatalogAndNowhereElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-dryrun-marker-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json").path
        let marker = ImportDryRunMarker()
        #expect(marker.attach(catalogFile: catalog) == nil)
        let written = record(generation: 7, build: ImportBuildIdentity.current)
        marker.notePassed(written)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ImportDryRunMarker.fileName).path))
        #expect(ImportDryRunMarker().attach(catalogFile: catalog) == written)
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

// MARK: - The store's hold with an owner token

@Suite("Import to SQLite — the store's hold (owner token)", .serialized)
@MainActor
struct ImportToSQLiteHoldTests {

    @Test("every write door refuses with .heldByJob and its words, nothing lands; releasing returns the count; the next save lands")
    func theStoreHoldRefusesEveryDoor() async throws {
        let sb = try ShowAgainSandbox.make("import_doors"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        let file = store.fileLocation
        store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner())
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

    @Test("the owner's acknowledged save passes the hold and moves the generation by one; the hold stays; it is not counted as held")
    func theOwnersSavePasses() async throws {
        let sb = try ShowAgainSandbox.make("import_owner"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        #expect(store.saveNow(records: []))
        let before = store.currentGeneration
        let owner = CatalogWriteHoldOwner()
        store.holdWrites(reason: "a test job", owner: owner)
        #expect(await store.saveAcknowledged(records: [], as: owner))
        #expect(store.currentGeneration == before + 1)
        #expect(CatalogSnapshot.headerProbe(at: URL(fileURLWithPath: store.fileLocation))?.generation == before + 1)
        #expect(store.writeHold == "a test job")
        #expect(store.releaseWriteHold() == 0)
    }

    @Test("a save presenting ANOTHER token, or none, is held while the owner's passes")
    func anotherTokenIsHeld() async throws {
        let sb = try ShowAgainSandbox.make("import_token"); defer { sb.cleanup() }
        let store = sb.model.catalogStore
        #expect(store.saveNow(records: []))
        let before = store.currentGeneration
        store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner())
        #expect(await store.saveAcknowledged(records: [], as: CatalogWriteHoldOwner()) == false)
        #expect(await store.saveAcknowledged(records: [], as: nil) == false)
        #expect(store.currentGeneration == before)
        #expect(store.releaseWriteHold() == 2)
    }
}

// MARK: - The job (sandboxed catalog folder, real small files, a real store)

@MainActor
struct ImportScene {
    let sandbox: ShowAgainSandbox

    var catalogURL: URL { URL(fileURLWithPath: sandbox.model.catalogStore.fileLocation) }
    var folder: URL { catalogURL.deletingLastPathComponent() }
    var databaseURL: URL { folder.appendingPathComponent(CatalogImporter.Inputs.databaseFileName) }

    /// A sandbox catalog whose rows point at real files in the sandbox and
    /// whose catalog.json is SAVED (the store's generation = the file's), as
    /// in a live app.
    static func make(_ label: String, rows: Int = 3) throws -> ImportScene {
        let sb = try ShowAgainSandbox.make("import_\(label)")
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        for i in 0..<rows { try sb.live("clip\(i).mov", bytes: 2_000 + i) }
        guard sb.model.saveCatalogNow() else { throw CocoaError(.fileWriteUnknown) }
        return ImportScene(sandbox: sb)
    }

    func cleanup() { sandbox.cleanup() }

    func catalogHash() throws -> String {
        SHA256.hash(data: try Data(contentsOf: catalogURL)).map { String(format: "%02x", $0) }.joined()
    }

    func fileGeneration() -> Int? { CatalogSnapshot.headerProbe(at: catalogURL)?.generation }

    /// The job, with its phase jobs pointed at the sandbox: the audit's lane
    /// is the sandbox folder (mounted), Verify reads no shared events store.
    func job(_ mode: CatalogImporter.Mode, runningJobs: [String] = []) -> ImportToSQLiteJob {
        let job = ImportToSQLiteJob(model: sandbox.model, mode: mode, runningJobs: runningJobs,
                                    gateEnvironment: { CatalogImporter.Environment() })
        let laneRoot = sandbox.laneRoot
        job.configureAuditForTesting = { audit in
            audit.volumeOnline = { _ in true }
            audit.laneRoot = laneRoot
            audit.tickMilliseconds = 20
        }
        job.configureVerifyForTesting = { $0.eventsForTesting = [] }
        return job
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

    @Test("TRUTH: audit, then Verify, then the import, in order, all at ONE generation — the audit's save; the dry run passes, writes no catalog.sqlite, stamps the marker with this build; START / phase lines / OUTCOME go through the sink; the hold is released")
    func threePhasesInOrderAtOneGeneration() async throws {
        let scene = try ImportScene.make("dry"); defer { scene.cleanup() }
        let startGeneration = try #require(scene.fileGeneration())
        var phases: [ImportToSQLiteJob.Phase] = []
        let job = await scene.run(.dryRun) { $0.onPhaseForTesting = { phases.append($0) } }
        guard case .finished(let summary) = job.state else { Issue.record("expected finished, got \(job.state)"); return }
        #expect(phases == [.audit, .verify, .gate])
        #expect(summary.hasPrefix(ImportToSQLiteJob.dryRunPrefix + "rows before 3"), Comment(rawValue: summary))
        let audit = try #require(job.auditJob)
        let generation = try #require(job.auditedGeneration)
        #expect(audit.saveCount >= 1, "the audit saved its stamps")
        #expect(generation == startGeneration + audit.saveCount)
        #expect(job.verifyJob?.report?.snapshotGeneration == generation)
        #expect(job.verifyJob?.report?.catalogHashCertified == true)
        #expect(scene.fileGeneration() == generation)
        #expect(scene.sandbox.model.catalogAuditRunMarker.lastRun?.catalogGeneration == generation)
        let marker = scene.sandbox.model.importDryRunMarker.lastPassed
        #expect(marker?.catalogGeneration == generation)
        #expect(marker?.build == ImportBuildIdentity.current)
        #expect(marker?.reconciliationLine == job.reconciliation?.line)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(job.phase == .done)
        let log = scene.log()
        let order = ["Import to SQLite: START — DRY RUN", "Import to SQLite: phase 1 of 3 — Audit catalog", "Audit catalog: START",
                     "Audit catalog: OUTCOME", "Import to SQLite: phase 2 of 3 — Verify catalog", "Verify catalog: START",
                     "Verify catalog: OUTCOME", "Import to SQLite: phase 3 of 3 — the import, at generation \(generation)",
                     "Import to SQLite: importer: START import (dry run)", "Import to SQLite: OUTCOME dry run passed — nothing written"]
        let positions = order.map { log.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil), Comment(rawValue: log))
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), Comment(rawValue: log))
    }

    @Test("the audit's own stamp save passes the hold: every row on disk carries its where-seen stamp at the audit's generation")
    func theAuditsOwnSavePassesTheHold() async throws {
        let scene = try ImportScene.make("stamps"); defer { scene.cleanup() }
        let job = await scene.run(.dryRun)
        #expect(job.state == .finished(summary: job.subtitle), Comment(rawValue: job.subtitle))
        #expect(job.auditJob?.stampedCount == 3)
        let reread = CatalogStore(directory: scene.folder)
        let rows = reread.load()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.auditSeenOn != nil })
        #expect(reread.currentGeneration == job.auditedGeneration)
    }

    @Test("ISOLATION (poisoned state): a background save in EACH phase is held — the generation stays the audit's, catalog.json's hash changes only by the audit's own save — and the held saves are caught up when the job lets go")
    func aBackgroundSaveInEachPhaseIsHeld() async throws {
        let scene = try ImportScene.make("hold"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        let startGeneration = try #require(scene.fileGeneration())
        var results: [ImportToSQLiteJob.Phase: Bool] = [:]
        var generations: [ImportToSQLiteJob.Phase: Int] = [:]
        var hashes: [ImportToSQLiteJob.Phase: String] = [:]
        var midImport: Bool?
        let job = await scene.run(.dryRun) { job in
            job.onPhaseForTesting = { phase in
                model.records.first?.userNotes = "edited during \(phase)"     // a background writer's change
                results[phase] = model.saveCatalogNow()
                generations[phase] = scene.fileGeneration()
                hashes[phase] = try? scene.catalogHash()
            }
            job.onImporterLineForTesting = { line in
                guard line.hasPrefix("rows "), midImport == nil else { return }
                midImport = model.saveCatalogNow()
            }
        }
        #expect(job.state == .finished(summary: job.subtitle), Comment(rawValue: job.subtitle))
        let generation = try #require(job.auditedGeneration)
        #expect(results[.audit] == false)
        #expect(results[.verify] == false)
        #expect(results[.gate] == false)
        #expect(midImport == false)
        #expect(generations[.audit] == startGeneration, "phase 1 starts before the audit's save")
        #expect(generations[.verify] == generation)
        #expect(generations[.gate] == generation)
        #expect(scene.fileGeneration() == generation)
        #expect(hashes[.verify] == hashes[.gate])
        #expect(try scene.catalogHash() == hashes[.verify])
        #expect(model.catalogStore.lastWriteError == .heldByJob(ImportToSQLiteJob.holdReason))
        #expect(model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("4 catalog save(s) were held while the catalog was audited, verified and read — saving now"))
    }

    @Test("a real import, enabled by a dry run from this build at an OLDER generation, re-audits, re-verifies and commits at its own audit's generation")
    func aRealImportAfterTheCatalogMovedOn() async throws {
        let scene = try ImportScene.make("commit"); defer { scene.cleanup() }
        let dry = await scene.run(.dryRun)
        let dryGeneration = try #require(dry.auditedGeneration)
        #expect(scene.sandbox.model.saveCatalogNow(), "a background save after the dry run (the 4881 → 4882 race)")
        let marker = scene.sandbox.model.importDryRunMarker.lastPassed
        #expect(marker?.catalogGeneration == dryGeneration)
        #expect(try #require(scene.fileGeneration()) > dryGeneration)
        #expect(ImportDryRunMarker.enablesCommit(marker, build: ImportBuildIdentity.current))
        let real = await scene.run(.commit)
        guard case .finished(let summary) = real.state else { Issue.record("expected finished, got \(real.state)"); return }
        #expect(summary == real.reconciliation?.line)
        #expect(real.reconciliation?.rowsBefore == dry.reconciliation?.rowsBefore)
        #expect(real.reconciliation?.rowsQuarantine == dry.reconciliation?.rowsQuarantine)
        #expect(try #require(real.auditedGeneration) > dryGeneration)
        #expect(real.databaseURL == scene.databaseURL)
        #expect(FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.log().contains("Import to SQLite: OUTCOME imported — generation \(real.auditedGeneration ?? -1)"))
    }

    @Test("pre-flight: unsaved catalog changes refuse before any work — no audit ran, nothing written")
    func unsavedChangesRefuseTheJob() async throws {
        let scene = try ImportScene.make("unsaved"); defer { scene.cleanup() }
        scene.sandbox.model.saveCatalogDebounced()
        #expect(scene.sandbox.model.catalogStore.hasUnsavedChanges)
        let job = await scene.run(.dryRun)
        #expect(job.wasRefused)
        #expect(job.refusals == ["the catalog has unsaved changes — wait a few seconds for the save, then try again"])
        #expect(job.auditJob == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME refused — the catalog has unsaved changes"))
        #expect(!scene.log().contains("Audit catalog: START"), "the audit never ran")
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
    }

    @Test("pre-flight: another MFO job running refuses and names it")
    func anotherJobRefuses() async throws {
        let scene = try ImportScene.make("busy"); defer { scene.cleanup() }
        let job = await scene.run(.commit, runningJobs: ["Verify catalog"])
        #expect(job.wasRefused)
        #expect(job.refusals.first?.hasPrefix("Verify catalog is running") == true)
        #expect(job.auditJob == nil)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
    }

    @Test("pre-flight: catalog.sqlite already beside the catalog refuses a real import before the audit and leaves it alone; a dry run does not care")
    func existingTargetRefuses() async throws {
        let scene = try ImportScene.make("target"); defer { scene.cleanup() }
        try Data("not a database".utf8).write(to: scene.databaseURL)
        let commit = await scene.run(.commit)
        #expect(commit.wasRefused)
        #expect(commit.refusals == ["catalog.sqlite already exists beside the catalog — move it aside first; nothing was written"])
        #expect(commit.auditJob == nil)
        #expect(try Data(contentsOf: scene.databaseURL) == Data("not a database".utf8))
        let dry = await scene.run(.dryRun)
        #expect(dry.state == .finished(summary: dry.subtitle), Comment(rawValue: dry.subtitle))
    }

    @Test("phase 1 cannot complete (its save is not acknowledged): the job stops with the audit's own words; Verify never runs; nothing imported; the hold is released")
    func anAuditThatCannotCompleteStopsTheJob() async throws {
        let scene = try ImportScene.make("auditfail"); defer { scene.cleanup() }
        let job = await scene.run(.commit) { job in
            let configure = job.configureAuditForTesting
            job.configureAuditForTesting = { audit in
                configure?(audit)
                audit.saveCatalogForTesting = { false }
            }
        }
        #expect(job.wasRefused)
        #expect(job.refusals.first?.hasPrefix("the audit could not complete: Failed — marks undone") == true, Comment(rawValue: job.refusals.first ?? ""))
        #expect(job.verifyJob == nil)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME refused — the audit could not complete"))
        #expect(scene.log().contains("Nothing was imported."))
    }

    @Test("phase 2 cannot complete (its report cannot be written): the job stops with Verify's own words; the importer never runs")
    func aVerifyThatCannotCompleteStopsTheJob() async throws {
        let scene = try ImportScene.make("verifyfail"); defer { scene.cleanup() }
        // A FOLDER where the report must land: the publish cannot replace it.
        let blocker = scene.folder.appendingPathComponent(IntegrityReportStore.latestFileName)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        let job = await scene.run(.dryRun)
        #expect(job.wasRefused)
        #expect(job.refusals.first?.hasPrefix("Verify Catalog could not complete:") == true, Comment(rawValue: job.refusals.first ?? ""))
        #expect(!scene.log().contains("importer: START"), "the importer never ran")
        #expect(scene.sandbox.model.importDryRunMarker.lastPassed == nil)
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
    }

    @Test("Stop before any work: Stopped, no audit, the target absent")
    func stopBeforeAnyWork() async throws {
        let scene = try ImportScene.make("stop0"); defer { scene.cleanup() }
        let job = scene.job(.commit)
        job.start()
        job.cancel()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(job.auditJob == nil)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.log().contains("Import to SQLite: OUTCOME stopped"), Comment(rawValue: scene.log()))
    }

    /// Stop pressed at the start of `phase` (inside the hold).
    private func stop(in phase: ImportToSQLiteJob.Phase, _ label: String) async throws -> (ImportScene, ImportToSQLiteJob) {
        let scene = try ImportScene.make(label)
        let job = await scene.run(.commit) { job in
            job.onPhaseForTesting = { [weak job] p in if p == phase { job?.cancel() } }
        }
        return (scene, job)
    }

    @Test("Stop in phase 1 (the audit): Stopped; Verify never runs; nothing imported; the hold released")
    func stopDuringTheAudit() async throws {
        let (scene, job) = try await stop(in: .audit, "stopA"); defer { scene.cleanup() }
        #expect(job.state == .cancelled, Comment(rawValue: job.subtitle))
        #expect(job.auditJob?.state == .cancelled)
        #expect(job.verifyJob == nil)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME stopped — during the audit"))
    }

    @Test("Stop in phase 2 (Verify): Stopped; the importer never runs; nothing imported; the hold released")
    func stopDuringVerify() async throws {
        let (scene, job) = try await stop(in: .verify, "stopB"); defer { scene.cleanup() }
        #expect(job.state == .cancelled, Comment(rawValue: job.subtitle))
        #expect(job.verifyJob?.state == .cancelled)
        #expect(!scene.log().contains("importer: START"))
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME stopped — during Verify Catalog"))
    }

    @Test("Stop in phase 3 before the target opens: the importer stops — Stopped, never Done; the target absent; the hold released")
    func stopAtTheImport() async throws {
        let (scene, job) = try await stop(in: .gate, "stopC"); defer { scene.cleanup() }
        #expect(job.state == .cancelled, Comment(rawValue: job.subtitle))
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME stopped — rolled back"))
    }

    @Test("Stop during the transaction: the importer rolls back at its next step — Stopped, never Done; the target is absent")
    func stopDuringTheTransaction() async throws {
        let scene = try ImportScene.make("stopT"); defer { scene.cleanup() }
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

    @Test("while an import is active the standalone Audit Catalog and Verify Catalog refuse (it runs its own); with none active they start as before")
    func standaloneAuditAndVerifyWaitForTheImport() async throws {
        let sb = try ShowAgainSandbox.make("import_center"); defer { sb.cleanup() }
        let center = MediaFileOperationsCenter()
        let importing = ImportToSQLiteJob(model: sb.model, mode: .dryRun, runningJobs: [],
                                          gateEnvironment: { CatalogImporter.Environment() })
        #expect(center.add(importing))                                   // active, never started: no work, no reads
        let audit = center.startCatalogAudit(model: sb.model, marker: nil)
        let verify = center.startVerifyCatalog(model: sb.model)
        #expect(audit.wasRefused)
        #expect(verify.wasRefused)
        #expect(audit.subtitle.hasPrefix("Import to SQLite is running and runs its own Audit Catalog"), Comment(rawValue: audit.subtitle))
        #expect(verify.subtitle.hasPrefix("Import to SQLite is running and runs its own Verify Catalog"), Comment(rawValue: verify.subtitle))
        importing.refuseToStart(reason: "test over")
        #expect(center.importRunsItsOwn("Audit Catalog") == nil)
    }
}

// MARK: - Sensors

@Suite("Import to SQLite — sensors")
struct ImportToSQLiteSensorTests {

    static func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("MOPS-16: the job holds the store's writes (with its owner token) before the three phases and releases them after; it never saves the catalog itself; the only sink is importToSQLiteNote")
    func theJobHoldsAndReleasesTheOneWriter() throws {
        let job = try Self.code("MediaOps/ImportToSQLiteJob.swift")
        #expect(job.components(separatedBy: "catalogStore.holdWrites(reason: Self.holdReason, owner: holdOwner)").count == 2)
        #expect(job.components(separatedBy: "catalogStore.releaseWriteHold()").count == 2)
        let hold = try #require(job.range(of: "catalogStore.holdWrites("))
        let phases = try #require(job.range(of: "await runPhases("))
        let release = try #require(job.range(of: "catalogStore.releaseWriteHold()"))
        #expect(hold.lowerBound < phases.lowerBound)
        #expect(phases.lowerBound < release.lowerBound)
        #expect(!job.contains("saveCatalogNow("))
        #expect(!job.contains("saveCatalogAcknowledged("))
        #expect(job.contains("audit.writeHoldOwner = holdOwner"))
        #expect(job.components(separatedBy: "func importToSQLiteNote(").count == 2)
        #expect(job.contains("log(\"Import to SQLite: \" + line)"))
        #expect(job.contains("appLog.write(\"[import-sqlite] \" + line)"))
        for call in ["removeItem(", "trashItem(", "moveItem(", "Process(", "ProcessRunner", "AVAsset"] {
            #expect(!job.contains(call), "the job contains \(call)")
        }
    }

    @Test("the audit's acknowledged save presents its owner token; the store lets ONLY that token past the hold, before the lock; saveNow and saveAsync present none")
    func theOwnerTokenPath() throws {
        let audit = try Self.code("MediaOps/CatalogAuditJob.swift")
        #expect(audit.contains("model.saveCatalogAcknowledged(asHoldOwner: writeHoldOwner)"))
        let store = try Self.code("Catalog/CatalogStore.swift")
        let hold = try #require(store.range(of: "if let hold = writeHold, owner != writeHoldOwner {"))
        let lock = try #require(store.range(of: "switch lock.acquire() {"))
        #expect(hold.lowerBound < lock.lowerBound)
        #expect(store.components(separatedBy: "writePrecondition(as: owner)").count == 2, "only saveAcknowledged presents a token")
        #expect(store.components(separatedBy: "if writePrecondition() != nil").count == 3, "saveNow and saveAsync present none")
    }

    @Test("the menu passes the marker (no generation); the kind is registered; the sheet is wired")
    func shapeOfTheWiring() throws {
        let app = try SourceTree.appSource(named: "VideoScanApp.swift")
        #expect(app.contains("ImportToSQLiteMenuItems(model: catalogModel, center: fileOpsCenter, marker: catalogModel.importDryRunMarker,"))
        #expect(app.contains("catalogModel?.attachImportDryRunMarker()"))
        let menu = try Self.code("Catalog/ImportToSQLiteMenuItems.swift")
        #expect(menu.contains("ImportDryRunMarker.enablesCommit(marker.lastPassed, build: ImportBuildIdentity.current)"))
        let marker = try Self.code("MediaOps/ImportDryRunMarker.swift")
        #expect(marker.contains("importDryRunMarker.attach(catalogFile: catalogStore.fileLocation)"))
        #expect(MediaFileOperationKind.all.contains(.importToSQLite))
        #expect(MediaFileOperationKind.importToSQLite.hasDetailView)
        let content = try SourceTree.appSource(named: "ContentView.swift")
        #expect(content.contains(".sheet(item: $model.importToSQLiteConfirm)"))
    }
}
