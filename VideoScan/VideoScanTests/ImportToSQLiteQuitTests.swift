// ImportToSQLiteQuitTests.swift
// Codex 2026-10-17 round 2 on the import quit path
// (docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md):
//   P1 — force-release is not a COMMIT fence: a COMMIT stalled past the
//        quit's bound completes AFTER the hold was released and the JSON
//        saved. Pinned end to end with a stall injected inside the store's
//        write (after the importer's last Stop poll, before COMMIT): the
//        late COMMIT lands in the importer's STAGING folder, catalog.sqlite
//        never appears, and the next import moves the staging aside and
//        imports clean.
//   P1 — failed persistence still permits termination: a save refused at
//        quit leaves a recovery copy WITH the edit; when that fails too the
//        terminate reply is .terminateCancel unless the person chooses to
//        lose N change(s); the next launch says a copy is there (never
//        merged); willTerminate's save is checked and logged.
//   P2 — holdWrites can wait forever: bounded; past the bound the hold is
//        given back, the job refuses before phase 1 with words, and the
//        quit SKIPS its synchronous save behind a stalled writer (detected
//        by `waitForWriterToDrain` timing out) in favour of the recovery copy.
// Dimensions: LOGIC (each outcome named, with words), ISOLATION (poisoned
// state: a stalled writer, a refused write, a read-only folder), SENSOR
// (the delegate honours the reply; willTerminate cancels, releases, checks).
// SCALE: N/A here — the copy is the store's own payload (one DTO map, the
// same cost as a save, measured by the store's scale suites). MEDIA MATRIX:
// N/A (no media opened).
// Suites (filter by SUITE): ImportToSQLiteQuitPathTests · ImportToSQLiteQuitSensorTests

import AppKit
import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

/// A stall inside the store's write, after the importer's last Stop poll
/// and before COMMIT. Bounded so a failing test cannot wedge the runner.
final class CommitStall: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = false
    private let gate = DispatchSemaphore(value: 0)
    var entered: Bool { lock.withLock { inside } }

    func stallHere() {
        lock.withLock { inside = true }
        _ = gate.wait(timeout: .now() + 30)
    }

    func release() { gate.signal() }
}

@Suite("Import to SQLite — the quit path, codex round 2", .serialized)
@MainActor
struct ImportToSQLiteQuitPathTests {

    private static let corrupt: @Sendable (URL) -> Void = { url in
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("tamper".utf8))
        try? handle.close()
    }

    private func notesOnDisk(_ scene: ImportScene) -> [String] {
        CatalogStore(directory: scene.folder).load().map(\.userNotes)
    }

    private func entries(_ scene: ImportScene, prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scene.folder.path)) ?? []).filter { $0.hasPrefix(prefix) }
    }

    /// A stalled save (the volume hangs for `seconds`), admitted now.
    private func stallASave(_ scene: ImportScene, seconds: TimeInterval) {
        let store = scene.sandbox.model.catalogStore
        store.testWriteDelay = seconds
        store.saveAsync(records: scene.sandbox.model.records)
    }

    /// Let a stalled save finish before the sandbox goes away.
    private func waitOutTheStall(_ scene: ImportScene) async throws {
        let store = scene.sandbox.model.catalogStore
        for _ in 0..<1_000 where store.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(10)) }
        store.testWriteDelay = 0
    }

    // MARK: - P1: the late COMMIT

    @Test("P1: COMMIT stalls past the quit's bound — hold released by force, the held edit saved; the COMMIT then completes into STAGING: catalog.sqlite does not exist; the next import moves the staging aside and imports clean")
    func aLateCommitNeverReachesCatalogSQLite() async throws {
        let scene = try ImportScene.make("latecommit"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        let stall = CommitStall()
        let job = scene.job(.commit)
        job.makeRepositoryForTesting = {
            let repository = GRDBCatalogRepository(host: "quit-test", durability: .volatileForTests)
            await repository.injectCrashBeforeCommit { stall.stallHere() }
            return repository
        }
        job.start()
        for _ in 0..<3_000 where !stall.entered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(stall.entered, "the importer reached its COMMIT")
        model.records.first?.userNotes = "edited while COMMIT stalled"
        model.saveCatalogDebounced()
        let outcome = await ImportToSQLiteQuit.settleAndSave(job: job, model: model, deadline: 0.5, writerDeadline: 5)
        #expect(outcome == .saved)
        #expect(notesOnDisk(scene).contains("edited while COMMIT stalled"))
        #expect(model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Stop holds the publish gate, so catalog.sqlite cannot appear"), Comment(rawValue: scene.log()))
        stall.release()
        await job.task?.value
        #expect(job.state == .cancelled, Comment(rawValue: job.subtitle))
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(entries(scene, prefix: "catalog.sqlite.importing-").count == 1)
        let next = await scene.run(.commit)
        #expect(next.state == .finished(summary: next.subtitle), Comment(rawValue: next.subtitle))
        #expect(FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(entries(scene, prefix: "catalog.sqlite.import-aside-").count == 1)
    }

    // MARK: - P1: failed persistence

    @Test("P1: a save refused at quit (the write does not verify) leaves a recovery copy beside catalog.json WITH the edit; START/OUTCOME logged; the quit may proceed")
    func aRefusedSaveAtQuitLeavesARecoveryCopy() async throws {
        let scene = try ImportScene.make("quitcopy"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "the edit the quit must not lose"
        model.catalogStore.testAfterWriteBeforeVerify = Self.corrupt
        let outcome = await ImportToSQLiteQuit.settleAndSave(job: nil, model: model, deadline: 0, writerDeadline: 5)
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(url.lastPathComponent.hasPrefix(CatalogQuitRecovery.filePrefix))
        #expect(url.deletingLastPathComponent().path == scene.folder.path)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("the edit the quit must not lose"))
        #expect(CatalogSnapshot.headerProbe(at: url) != nil)
        #expect(scene.log().contains("Catalog quit: START recovery copy"))
        #expect(scene.log().contains("Catalog quit: OUTCOME recovery copy written"))
        let reply = ImportToSQLiteQuit.terminateReply(for: outcome, model: model) { _, _ in
            Issue.record("a recovery copy must not ask")
            return false
        }
        #expect(reply == .terminateNow)
    }

    @Test("P1: the save AND the recovery copy fail (read-only folder) — the reply is .terminateCancel by default; only 'Quit and lose N' quits; nothing is written")
    func bothFailingKeepsTheAppOpen() async throws {
        let scene = try ImportScene.make("quitboth")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scene.folder.path)
            scene.cleanup()
        }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "nowhere to go"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scene.folder.path)
        let outcome = await ImportToSQLiteQuit.settleAndSave(job: nil, model: model, deadline: 0, writerDeadline: 5)
        guard case .unsaved(let words, let changes) = outcome else { Issue.record("expected unsaved, got \(outcome)"); return }
        #expect(words.contains("the recovery copy also failed"))
        #expect(changes == 1)
        var asked: Int?
        let kept = ImportToSQLiteQuit.terminateReply(for: outcome, model: model) { _, n in
            asked = n
            return false
        }
        #expect(kept == .terminateCancel)
        #expect(asked == 1)
        #expect(ImportToSQLiteQuit.terminateReply(for: outcome, model: model) { _, _ in true } == .terminateNow)
        #expect(scene.log().contains("Catalog quit: quit CANCELLED — VideoScan stays open with 1 unsaved change(s)"))
        #expect(scene.log().contains("Catalog quit: OUTCOME recovery copy FAILED"))
        #expect(entries(scene, prefix: CatalogQuitRecovery.filePrefix).isEmpty)
    }

    @Test("P1: willTerminate's save is CHECKED — a refused save becomes a recovery copy and the branch is logged")
    func theTerminalSaveIsChecked() async throws {
        let scene = try ImportScene.make("terminal"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        model.records.first?.userNotes = "saved at exit"
        model.catalogStore.testAfterWriteBeforeVerify = Self.corrupt
        let outcome = CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5)
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("saved at exit"))
        #expect(scene.log().contains("Catalog quit: app exit — the catalog could not be saved"))
        model.catalogStore.testAfterWriteBeforeVerify = nil
        #expect(CatalogQuitRecovery.saveAtTermination(model: model, writerDeadline: 5) == .saved)
    }

    @Test("P1: the next launch says a recovery copy is beside the catalog — console + catalog.log — and merges nothing")
    func theNextLaunchSaysACopyIsThere() async throws {
        let scene = try ImportScene.make("launch"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        #expect(CatalogQuitRecovery.launchNotice(catalogURL: scene.catalogURL) == nil)
        try Data("{}".utf8).write(to: scene.folder.appendingPathComponent("catalog.recovery-20261017-230000.json"))
        let before = model.records.map(\.userNotes)
        model.announceCatalogRecoveryCopies()
        #expect(scene.log().contains("Catalog quit: 1 catalog recovery copy from a quit that could not save is beside the catalog: catalog.recovery-20261017-230000.json. Nothing was merged."),
                Comment(rawValue: scene.log()))
        #expect(model.records.map(\.userNotes) == before)
    }

    // MARK: - P2: a stalled writer

    @Test("P2: holdWrites is BOUNDED — an admitted save that does not drain gives the hold back within the bound (.writerStalled), it does not wait for the save")
    func theHoldGivesUpOnAStalledSave() async throws {
        let scene = try ImportScene.make("stallhold"); defer { scene.cleanup() }
        let store = scene.sandbox.model.catalogStore
        stallASave(scene, seconds: 2)
        let started = Date()
        let result = await store.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner(), within: 0.3)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(result == .writerStalled(heldSaves: 0))
        #expect(store.writeHold == nil)
        try await waitOutTheStall(scene)
    }

    @Test("P2: the job facing a stalled save refuses before phase 1 with words; no audit ran; the hold is released")
    func theJobRefusesOnAStalledWriter() async throws {
        let scene = try ImportScene.make("stalljob"); defer { scene.cleanup() }
        let job = await scene.run(.dryRun) { job in
            job.holdDrainDeadline = 0.3
            job.onBeforeHoldForTesting = { stallASave(scene, seconds: 2) }
        }
        #expect(job.wasRefused)
        #expect(job.refusals == ["a catalog save did not finish within 0.3 s — try again"])
        #expect(job.auditJob == nil)
        #expect(scene.sandbox.model.catalogStore.writeHold == nil)
        #expect(scene.log().contains("Import to SQLite: OUTCOME refused — a catalog save did not finish within 0.3 s — try again"))
        try await waitOutTheStall(scene)
    }

    @Test("P2: a quit behind a stalled writer SKIPS the synchronous save (it would block the main thread) and writes the recovery copy, within the bound")
    func aQuitBehindAStalledWriterWritesTheCopy() async throws {
        let scene = try ImportScene.make("stallquit"); defer { scene.cleanup() }
        let model = scene.sandbox.model
        stallASave(scene, seconds: 3)
        model.records.first?.userNotes = "edited behind a stalled save"
        let started = Date()
        let outcome = await ImportToSQLiteQuit.settleAndSave(job: nil, model: model, deadline: 0, writerDeadline: 0.3)
        #expect(Date().timeIntervalSince(started) < 2)
        guard case .recoveryCopy(let url) = outcome else { Issue.record("expected a recovery copy, got \(outcome)"); return }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("edited behind a stalled save"))
        #expect(scene.log().contains("the synchronous save is SKIPPED so the quit cannot hang behind it"))
        try await waitOutTheStall(scene)
    }
}

@Suite("Import to SQLite — quit path sensors, codex round 2")
struct ImportToSQLiteQuitSensorTests {

    @Test("the delegate replies with the settle's answer on both terminateLater paths; willTerminate stops the import, releases, then makes a CHECKED save; launch announces recovery copies")
    func theDelegateHonoursTheSaveOutcome() throws {
        let app = try ImportToSQLiteSensorTests.code("App/VideoScanApp.swift")
        #expect(app.components(separatedBy: "NSApp.reply(toApplicationShouldTerminate: reply == .terminateNow)").count == 3)
        #expect(app.contains("guard reply == .terminateNow else { return reply }"))
        let cancel = try #require(app.range(of: "importJob?.cancel()"))
        let release = try #require(app.range(of: "ImportToSQLiteQuit.releaseHoldIfStillHeld(model: model, deadline: 0, job: importJob)"))
        let save = try #require(app.range(of: "CatalogQuitRecovery.saveAtTermination(model: model)"))
        #expect(cancel.lowerBound < release.lowerBound)
        #expect(release.lowerBound < save.lowerBound)
        #expect(!app.contains("catalogModel?.saveCatalogNow()"))
        #expect(app.contains("catalogModel?.announceCatalogRecoveryCopies()"))
    }

    @Test("the quit asks the writer to drain (bounded) before its synchronous save; the job passes the atomic publish gate to the importer")
    func theQuitDetectsAStalledWriterFirst() throws {
        let quit = try ImportToSQLiteSensorTests.code("MediaOps/ImportToSQLiteQuit.swift")
        let drain = try #require(quit.range(of: "await store.waitForWriterToDrain(within: writerDeadline)"))
        let save = try #require(quit.range(of: "model.saveCatalogNow()"))
        #expect(drain.lowerBound < save.lowerBound)
        let job = try ImportToSQLiteSensorTests.code("MediaOps/ImportToSQLiteJob.swift")
        #expect(job.contains("publishPermit: { flag.claimPublish() }"))
    }
}
