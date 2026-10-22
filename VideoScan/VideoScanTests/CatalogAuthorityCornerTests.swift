// CatalogAuthorityCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the LAUNCH and AUTHORITY half: how
// our launch rule (`CatalogAuthority.decide`), the model's launch seam and the
// committer react when the files that make catalog.sqlite the authority are
// missing, vanish mid-session, are damaged, or come from a newer build.
//
//   Case 5   no catalog.cutover beside a real catalog.sqlite — on a master and
//            on a viewer. Since slice 2 (GH #354, 2026-10-21): `.noLatch`;
//            the master refuses loudly, read-only, with words, and opens no
//            catalog.json; a viewer with no latch of its own nor in
//            viewer-catalog/ says nothing is synced yet. Since slice 2b
//            (2026-10-21): a viewer's synced folder with the snapshot but no
//            latch shows "nothing synced from the master yet" — a catalog.json
//            beside it is never read (CatalogViewerSnapshot.source).
//   Fail-fast  the latch vanishes mid-session (#359) — the store refuses the
//            next commit before writing; the committer blocks with words
//            naming catalog.cutover and does not retry.
//   Case 10  (app) a damaged catalog.sqlite behind the latch — the launch is
//            refused with words, no catalog opens (catalog.json is never the
//            fallback, QA r1 F1, 2026-10-21), and neither
//            catalog.sqlite nor its witnesses change by one byte.
//   Case 11  (app) a newer schema behind the latch — the same: refused with
//            the store's "newer than this build" words, read-only, untouched.
//
// Five dimensions: LOGIC (above) · SCALE N/A (each case is one launch) ·
// MEDIA N/A · ISOLATION (CutoverScene sandboxes only; a damaged file is our
// own synthetic fixture) · SENSOR (SHA-256 before == after on every refusal).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog authority corners — missing or vanished latch, damaged or newer catalog.sqlite", .serialized)
@MainActor
struct CatalogAuthorityCornerTests {

    // MARK: - Case 5

    @Test("case 5 (master): catalog.sqlite with no catalog.cutover — refused loudly, read-only, catalog.json not opened (GH #354)")
    func masterWithoutLatch() async throws {
        let scene = try CutoverScene.make("corner_nolatch_master"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        let jsonBefore = try CornerFiles.sha256(scene.catalogURL)
        let authority = await CatalogAuthority.decide(folder: scene.folder)
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(authority == .noLatch)
        #expect(scene.model.catalogCutover.committer == nil)
        #expect(scene.model.records.isEmpty, "no catalog was opened")
        #expect(scene.model.isReadOnly, "catalog.json must not open writable")
        #expect(scene.model.catalogStore.isReadOnly)
        #expect(scene.model.catalogStore.lastLoadOutcome == .missing, "catalog.json was never loaded")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("OUTCOME No catalog — \(CatalogAuthority.latchFileName) is not beside the catalog"), Comment(rawValue: log))
        #expect(try CornerFiles.sha256(scene.catalogURL) == jsonBefore)
    }

    @Test("case 5 (viewer): own catalog.sqlite with no latch → .noLatch (GH #354); a synced snapshot with no latch is not shown and the catalog.json beside it is never read — 'nothing synced from the master yet' (slice 2b)")
    func viewerWithoutLatch() async throws {
        let scene = try CutoverScene.make("corner_nolatch_viewer"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        let own = await CatalogAuthority.decide(folder: scene.folder, readOnly: true)
        #expect(own == .noLatch, "a viewer without the latch never takes catalog.json as its catalog")

        // The synced folder: the master's sealed snapshot arrived, its latch did not.
        let live = scene.sandbox.root.appendingPathComponent("viewer-live", isDirectory: true)
        let repository = GRDBCatalogRepository(host: "corner-test")
        _ = await repository.open(at: scene.databaseURL)
        try FileManager.default.createDirectory(at: CatalogViewerSnapshot.directory(in: live), withIntermediateDirectories: true)
        let sealed = repository.sealedCopyBlocking(to: CatalogViewerSnapshot.databaseURL(in: live))
        await repository.close()
        #expect(sealed == nil)
        let json = live.appendingPathComponent("catalog.json")
        try Data("{\"version\":4,\"records\":[]}".utf8).write(to: json)
        let jsonBefore = try CornerFiles.sha256(json)

        let source = CatalogViewerSnapshot.source(in: live)
        #expect(source == .none, "a snapshot without its latch is not shown, and catalog.json is never the fallback")
        var adopted = 0
        let status = await CatalogViewerSnapshot.show(source, note: { _ in }, adopt: { _ in adopted += 1 })
        #expect(status == .none)
        #expect(status.words == "nothing synced from the master yet")
        #expect(adopted == 0, "nothing was swapped in")
        #expect(try CornerFiles.sha256(json) == jsonBefore, "the frozen catalog.json is left exactly as it was")
    }

    // MARK: - Fail fast: the latch vanishes mid-session

    @Test("fail-fast (#359, #354 mid-session note): catalog.cutover removed mid-session — the next commit is refused before writing, the committer is blocked with words naming the latch, and nothing lands; a later save does not retry")
    func latchVanishesMidSession() async throws {
        let scene = try CutoverScene.make("corner_latch_gone"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let wal = URL(fileURLWithPath: scene.databaseURL.path + "-wal")
        let before = CornerFiles.catalogFingerprint(scene.databaseURL) + [CornerFiles.sha256OrAbsent(wal)]
        try FileManager.default.removeItem(at: scene.latchURL)
        try scene.record(.healthy).userNotes = "after the latch went"
        let saved = scene.model.saveCatalogNow()
        let blocked = scene.model.catalogCutover.blockedReason
        let attempts = scene.model.catalogCutover.committer?.commitCount
        let again = scene.model.saveCatalogNow()                       // no silent retry
        let after = CornerFiles.catalogFingerprint(scene.databaseURL) + [CornerFiles.sha256OrAbsent(wal)]
        let landed = try await scene.reloaded(.healthy).userNotes == "after the latch went"
        print("[corner-authority] latch gone: saveCatalogNow → \(saved), blocked → \(blocked ?? "nil"), landed → \(landed)")
        #expect(!saved, "a commit ran after catalog.cutover vanished")
        #expect(!again)
        #expect(scene.model.catalogCutover.committer?.commitCount == attempts, "a blocked committer tried again")
        #expect(blocked == "\(CatalogAuthority.latchFileName) was replaced or removed while VideoScan was open; nothing more will be saved — quit and reopen",
                Comment(rawValue: blocked ?? "nil"))
        #expect(!landed, "the edit landed in catalog.sqlite after the latch vanished")
        #expect(after == before, "catalog.sqlite or a witness changed after the latch vanished")
    }

    @Test("fail-fast (#359): catalog.sqlite replaced mid-session — the committer's words say quit and reopen (never Catalog ▸ Reopen), and Reopen refuses with the same words, so memory is never committed into the replacement")
    func replacedCatalogRefusesReopen() async throws {
        let scene = try CutoverScene.make("corner_replaced_reopen"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let committer = try #require(scene.model.catalogCutover.committer)
        // A restore put in its place while the app runs: a sealed copy.
        let copy = scene.folder.appendingPathComponent("restored.sqlite")
        #expect(committer.repository.sealedCopyBlocking(to: copy) == nil)
        try FileManager.default.moveItem(at: scene.databaseURL, to: scene.folder.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: copy, to: scene.databaseURL)
        let replacementBefore = try CornerFiles.sha256(scene.databaseURL)

        try scene.record(.healthy).userNotes = "typed after the restore"
        #expect(!scene.model.saveCatalogNow(), "a commit ran after catalog.sqlite was replaced")
        let stop = "catalog.sqlite was replaced or moved while VideoScan was open; nothing more will be saved — quit and reopen"
        #expect(scene.model.catalogCutover.blockedReason == stop)
        let refusal = committer.saveRefusal() ?? "nil"
        #expect(refusal.contains("quit and reopen"), Comment(rawValue: refusal))
        #expect(!refusal.contains("Reopen SQLite Catalog"), Comment(rawValue: refusal))
        #expect(!scene.model.catalogCutover.canReopen, "the Reopen item is offered after a file-stop")

        await scene.model.catalogCutover.reopen()                   // the menu item, if reached anyway
        let afterReopen = scene.model.saveCatalogNow()
        let log = scene.sandbox.catalogLogText()
        #expect(!afterReopen, "a commit ran after Reopen on a replaced catalog.sqlite")
        #expect(scene.model.catalogCutover.blockedReason == stop)
        #expect(log.contains("REFUSED Catalog ▸ Reopen SQLite Catalog — \(stop)"), Comment(rawValue: log))
        #expect(!log.contains("(Catalog ▸ Reopen SQLite Catalog)"), "the NOT SAVED line still points at Reopen")
        #expect(try CornerFiles.sha256(scene.databaseURL) == replacementBefore, "the replacement catalog.sqlite was written")
        // No reload of the replacement here: the session still holds the old
        // catalog's -wal at the path, and opening beside it is the separate
        // read-after-swap issue (Manager, 10/21), not this one.
    }

    @Test("fail-fast (#359, QA r2-2): quit after catalog.sqlite was replaced — the store is closed, the session's -wal is quarantined, and the START / OUTCOME lines reach the catalog log; without a stop the quit close is a no-op")
    func quitAfterReplaceQuarantinesAndSaysSo() async throws {
        let scene = try CutoverScene.make("corner_quit_quarantine"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(!CatalogQuitRecovery.closeAfterFileStop(model: scene.model), "no stop: the quit close must not run")
        try scene.record(.healthy).userNotes = "committed before the restore"
        #expect(scene.model.saveCatalogNow())
        let committer = try #require(scene.model.catalogCutover.committer)
        let copy = scene.folder.appendingPathComponent("restored.sqlite")
        #expect(committer.repository.sealedCopyBlocking(to: copy) == nil)
        try FileManager.default.moveItem(at: scene.databaseURL, to: scene.folder.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: copy, to: scene.databaseURL)
        #expect(!scene.model.saveCatalogNow() || committer.repository.fileStopWords != nil)
        #expect(committer.repository.fileStopWords != nil, "the swap was not noticed")

        #expect(CatalogQuitRecovery.closeAfterFileStop(model: scene.model))
        let log = scene.sandbox.catalogLogText()
        let folders = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.hasPrefix("catalog-wal-quarantine-") }
        #expect(folders.count == 1, "\(folders)")
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path + "-wal"), "the session's -wal is still beside the replacement")
        #expect(log.contains("START closing catalog.sqlite at quit"), Comment(rawValue: log))
        #expect(log.contains("START quarantine of this session's catalog.sqlite-wal"), Comment(rawValue: log))
        #expect(log.contains("OUTCOME quarantine — "), Comment(rawValue: log))
        #expect(log.contains("OUTCOME closed catalog.sqlite at quit"), Comment(rawValue: log))
    }

    /// A close that never returns in time (the hung-writer stand-in).
    nonisolated static let hangingClose: @Sendable (any CatalogRepository) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(20))
    }

    @Test("fail-fast (#359, QA r3 + codex #117 F3): latch-only stop, the quit close times out — nothing is moved, and the words say the catalog's own -wal holds committed changes for the next open (never 'move it away')",
          .timeLimit(.minutes(1)))
    func quitCloseIsBoundedAndKeepsTheLiveWAL() async throws {
        let scene = try CutoverScene.make("corner_quit_bounded"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try FileManager.default.removeItem(at: scene.latchURL)
        try scene.record(.healthy).userNotes = "after the latch went"
        #expect(!scene.model.saveCatalogNow())
        let wal = URL(fileURLWithPath: scene.databaseURL.path + "-wal")
        let walBefore = CornerFiles.sha256OrAbsent(wal)
        let clock = ContinuousClock()
        let start = clock.now
        let attempted = CatalogQuitRecovery.closeAfterFileStop(model: scene.model, within: 0.3, close: Self.hangingClose)
        let waited = clock.now - start
        let log = scene.sandbox.catalogLogText()
        #expect(attempted)
        #expect(waited < .seconds(5), "the quit waited \(waited) for a hung close")
        #expect(log.contains("OUTCOME catalog.sqlite could not be closed within"), Comment(rawValue: log))
        #expect(log.contains("will be applied at the next open"), Comment(rawValue: log))
        #expect(!log.contains("away before reopening"), "a latch-only stop must never advise moving the live -wal")
        #expect(CornerFiles.sha256OrAbsent(wal) == walBefore, "the live -wal was touched")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.hasPrefix("catalog-wal-quarantine-") }.isEmpty)
    }

    @Test("fail-fast (#359, codex #117 F3): catalog.sqlite REPLACED, the quit close times out — the quit itself quarantines this session's -wal/-shm by inode, so the replacement cannot take them",
          .timeLimit(.minutes(1)))
    func quitTimeoutAfterReplaceStillQuarantines() async throws {
        let scene = try CutoverScene.make("corner_quit_timeout_replace"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.healthy).userNotes = "committed before the restore"
        #expect(scene.model.saveCatalogNow())
        let committer = try #require(scene.model.catalogCutover.committer)
        let copy = scene.folder.appendingPathComponent("restored.sqlite")
        #expect(committer.repository.sealedCopyBlocking(to: copy) == nil)
        try FileManager.default.moveItem(at: scene.databaseURL, to: scene.folder.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: copy, to: scene.databaseURL)
        let replacementBefore = try CornerFiles.sha256(scene.databaseURL)
        _ = scene.model.saveCatalogNow()                                    // the stop
        #expect(CatalogQuitRecovery.closeAfterFileStop(model: scene.model, within: 0.3, close: Self.hangingClose))
        let log = scene.sandbox.catalogLogText()
        let folders = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.hasPrefix("catalog-wal-quarantine-") }
        #expect(folders.count == 1, "\(folders)")
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path + "-wal"), "the session's -wal is still beside the replacement")
        #expect(try CornerFiles.sha256(scene.databaseURL) == replacementBefore)
        #expect(log.contains("START quarantine"), Comment(rawValue: log))
        #expect(log.contains("OUTCOME catalog.sqlite could not be closed within"), Comment(rawValue: log))
    }

    @Test("fail-fast (#359, codex #117 F4): catalog.sqlite replaced WHILE Reopen closes the store — Reopen re-checks after the close and refuses with the same words; nothing is opened and the replacement is untouched")
    func reopenRechecksAfterClose() async throws {
        let scene = try CutoverScene.make("corner_reopen_swap_in_close"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        let inner = GRDBCatalogRepository(host: "corner-test")
        try #require(await inner.open(at: scene.databaseURL, requiringLatch: true) == .readWrite)
        let replacement = scene.folder.appendingPathComponent("restored.sqlite")
        #expect(inner.sealedCopyBlocking(to: replacement) == nil)
        let swapping = SwapOnCloseRepository(inner: inner, database: scene.databaseURL, replacement: replacement)
        var lines: [String] = []
        let committer = CatalogCommitter(repository: swapping, storedDesignationJSON: nil,
                                         input: { CatalogCommitter.Input(records: [], designation: nil, clearAuthorized: false,
                                                                          holdReason: nil, holdOwner: nil) },
                                         sink: { lines.append($0) })
        committer.block("a refusal that offers Reopen")
        await committer.reopen(at: scene.databaseURL)
        let stop = "catalog.sqlite was replaced or moved while VideoScan was open; nothing more will be saved — quit and reopen"
        #expect(swapping.openCalls == 0, "Reopen opened the replacement")
        #expect(committer.blockedReason == stop, "\(committer.blockedReason ?? "nil")")
        #expect(lines.contains { $0.contains("REFUSED Catalog ▸ Reopen SQLite Catalog — \(stop)") }, "\(lines)")
        #expect(swapping.replacementSHA == (try CornerFiles.sha256(scene.databaseURL)), "the replacement was written")
    }

    @Test("fail-fast (#359, QA r3 nit): quit after a latch-only stop — catalog.sqlite is still the session's file, closed normally; the words do not talk about a -wal left behind")
    func quitAfterLatchOnlyStopSaysClosedNormally() async throws {
        let scene = try CutoverScene.make("corner_quit_latch_only"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try FileManager.default.removeItem(at: scene.latchURL)
        try scene.record(.healthy).userNotes = "after the latch went"
        #expect(!scene.model.saveCatalogNow())
        #expect(CatalogQuitRecovery.closeAfterFileStop(model: scene.model))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("OUTCOME closed catalog.sqlite at quit — it is still this session's own file and was closed normally"),
                Comment(rawValue: log))
        #expect(!log.contains("-wal stays with it"))
        let folders = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path).filter { $0.hasPrefix("catalog-wal-quarantine-") }
        #expect(folders.isEmpty, "a latch-only stop quarantined the live catalog's -wal: \(folders)")
    }

    // MARK: - Cases 10 and 11 at the launch

    enum Damage: String, CaseIterable, Sendable, CustomStringConvertible {
        case corruptPages
        case newerSchema
        var description: String { rawValue }
    }

    @Test("cases 10/11 (app): a damaged or newer catalog.sqlite behind the latch — refused with words, no catalog opened (catalog.json never the fallback), catalog.sqlite and its witnesses byte-identical",
          arguments: Damage.allCases)
    func damagedOrNewerCatalogIsRefusedAndUntouched(_ damage: Damage) async throws {
        let scene = try CutoverScene.make("corner_\(damage)"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        try CornerFiles.checkpointAndDropSidecars(scene.databaseURL)
        switch damage {
        case .corruptPages:
            try CornerFiles.corruptPageHeaders(scene.databaseURL)
        case .newerSchema:
            try CornerFiles.exec(scene.databaseURL, "UPDATE catalog_state SET schema_version = schema_version + 1 WHERE singleton = 1")
            try CornerFiles.checkpointAndDropSidecars(scene.databaseURL)
        }
        try scene.writeLatch()
        let before = CornerFiles.catalogFingerprint(scene.databaseURL)
        let jsonBefore = try CornerFiles.sha256(scene.catalogURL)

        scene.model.records = scene.model.loadCatalogAtLaunch()
        scene.model.applyReadOnlyMode(false)                    // the master's onAppear
        let log = scene.sandbox.catalogLogText()
        #expect(scene.model.catalogCutover.committer == nil, "\(damage): a committer was installed on a refused store")
        #expect(scene.model.isReadOnly, "\(damage)")
        #expect(scene.model.catalogStore.isReadOnly, "\(damage)")
        #expect(log.contains("SQLite catalog refused — catalog.sqlite would not open"), "\(damage): \(log)")
        if damage == .newerSchema {
            #expect(log.contains("newer than this build"), Comment(rawValue: log))
        }
        // Fail-fast: nothing may be written over it, by any door.
        #expect(scene.model.records.isEmpty, "\(damage): a refused launch opens no catalog (QA r1 F1)")
        #expect(scene.model.saveCatalogNow() == false, "\(damage)")
        #expect(CornerFiles.catalogFingerprint(scene.databaseURL) == before, "\(damage): catalog.sqlite or a witness changed")
        #expect(try CornerFiles.sha256(scene.catalogURL) == jsonBefore, "\(damage): catalog.json was written")
    }
}
