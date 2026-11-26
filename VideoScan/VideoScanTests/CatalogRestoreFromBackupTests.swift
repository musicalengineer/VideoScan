// CatalogRestoreFromBackupTests.swift
// File ▸ Restore from Backup… (GH #343, CatalogBackupRestore.swift) in the
// app, end to end on a sandbox catalog.sqlite (CutoverScene — never
// Application Support; the Trash is MediaTrash's per-process test trash).
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      back up → edit and save past it → restore: the outcome names
//              the backup's generation and rows; the session stops (every
//              save refused with "quit", Reopen and Adopt refused, the model
//              read-only, the quit writes no recovery copy); the catalog as
//              it was is in the Trash with the edit typed after the backup.
//   RELAUNCH   a NEW model on the same folder opens the restored catalog
//              read-only "restored below high-water" with the backup's values;
//              Adopt is offered, adopting makes it writable, an edit saves.
//   ISOLATION  each refusal leaves catalog.sqlite (+ -wal) byte-identical,
//              the session writable and no work folder behind: a bundle whose
//              catalog.sqlite does not match its manifest's SHA-256; a
//              manifest whose generation is not the file's; a backup AT the
//              high-water; a bundle with no latch; a catalog held by a job;
//              Cancel at the confirmation.
//   STEPS      a failure at each later step gives the hold back and leaves the
//              live catalog intact and openable: the safety copy cannot reach
//              the Trash; the store refuses the restore after the hold (the
//              staged copy damaged under it).
//   TRUTH      the confirmation's numbers are read from the verified copy, and
//              equal the manifest's only because the door checked they do.
//   SENSOR     source: the door never moves, replaces or publishes over
//              catalog.sqlite; the restore goes through the store's backup-API
//              door, the safety copy through THE one Trash call.
//   SCALE      in Core (CatalogDatabaseRestoreScale: a 100k-row restore).
//   MEDIA      N/A — no media is opened.
//
// Suites (filter by SUITE): CatalogRestoreFromBackupTests · CatalogRestoreFromBackupSensorTests

import Foundation
import SQLite3
import Testing
@testable import VideoScan
@testable import VideoScanCore

// MARK: - Helpers

@MainActor
extension CutoverScene {

    /// Production's context with the confirmation answered by the test.
    func restoreContext(confirm: Bool = true, seen: RestoreSeen? = nil,
                        trash: (@Sendable (URL) throws -> URL)? = nil) throws -> CatalogBackupRestore.Context {
        var context = try #require(CatalogBackupRestore.Context.live(model: model))
        context.confirm = { plan, live in
            seen?.plan = plan
            seen?.live = live
            return confirm
        }
        if let trash { context.trash = trash }
        return context
    }

    /// No `.restore-*` work folder is left beside catalog.sqlite.
    func workFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(CatalogBackupRestore.workFolderPrefix) }
    }

    /// An edit + a synchronous save lands: the session is writable.
    func expectWritable(_ note: String, _ comment: String) throws {
        try record(.healthy).userNotes = note
        #expect(model.saveCatalogNow(), Comment(rawValue: "the session must still save: \(comment)"))
    }

    /// Back up through the real door; returns the bundle's manifest.
    func backUp() async throws -> BundleManifest {
        switch await model.backUpCatalog(to: backupURL, sideFiles: sandboxSideFiles) {
        case .backedUp(let summary): return summary.manifest
        case .refused(let words): throw CutoverFailure(words: "backup refused: \(words)")
        }
    }

    /// The same folder launched by a NEW model (nothing in memory survives).
    func relaunched() async throws -> VideoScanModel {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    func rewriteManifest(_ edit: (inout BundleManifest) -> Void) throws {
        let url = backupURL.appendingPathComponent("manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(BundleManifest.self, from: Data(contentsOf: url))
        edit(&manifest)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url)
    }
}

/// What the confirmation was shown (the closure runs on the main actor).
@MainActor
final class RestoreSeen {
    var plan: CatalogBackupRestore.Plan?
    var live: CatalogBackupRestore.Live?
}

/// The notes of every record in a sealed copy (opened sealed, read-only).
private func notes(inSealed url: URL) async throws -> Set<String> {
    let reader = GRDBCatalogRepository(host: "restore-test-reader")
    guard case .readOnly = await reader.openSealedSnapshot(at: url) else { throw CutoverFailure(words: "sealed open of \(url.path)") }
    do {
        let snapshot = try await CatalogLoad.read(reader)
        await reader.close()
        return Set(try snapshot.rows.map { try VideoRecord(loaded: $0).userNotes })
    } catch {
        await reader.close()
        throw error
    }
}

// MARK: - The door

@Suite("Restore from Backup — the door, the stop, the relaunch and every refusal", .serialized)
@MainActor
struct CatalogRestoreFromBackupTests {

    @Test("restore: the session stops, the old catalog is in the Trash; the relaunch is read-only below high-water with the backup's values, and Adopt makes it writable")
    func restoreStopRelaunchAdopt() async throws {
        let scene = try CutoverScene.make("restore_e2e"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.healthy).userNotes = "as backed up"
        let manifest = try await scene.backUp()
        let sealed = try #require(manifest.catalogDatabase)
        try scene.expectWritable("typed after the backup", "an edit after the backup")
        let committer = try #require(scene.model.catalogCutover.committer)
        let liveGeneration = await committer.generationNow()
        #expect(liveGeneration > sealed.generation)

        let seen = RestoreSeen()
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: try scene.restoreContext(seen: seen))
        guard case .restored(let restored) = outcome else { Issue.record("expected restored, got \(outcome)"); return }
        #expect(restored.generation == sealed.generation && restored.replaced == liveGeneration)
        #expect(restored.files == sealed.files)

        // TRUTH: what the confirmation showed came from the verified copy.
        let plan = try #require(seen.plan)
        #expect(plan.backup.generation == sealed.generation && plan.backup.counts.files == sealed.files)
        #expect(plan.highWater == liveGeneration)
        #expect(seen.live?.generation == liveGeneration)
        let words = CatalogBackupRestore.confirmationText(plan, try #require(seen.live))
        #expect(words.contains("\(sealed.files.formatted()) file rows (generation \(sealed.generation))"), Comment(rawValue: words))
        #expect(words.contains("(generation \(liveGeneration))"))

        // The session stopped for good.
        #expect(committer.restoreStop != nil)
        #expect(scene.model.isReadOnly && scene.model.readOnlyFacts.restoredFromBackup)
        #expect(committer.saveRefusal()?.contains("quit VideoScan and open it again") == true)
        #expect(scene.model.catalogCutover.canReopen == false && scene.model.catalogCutover.canAdopt == false)
        #expect(await committer.adopt(toHighWater: liveGeneration + 1) == .refused(reason: try #require(committer.restoreStop)))
        try scene.record(.healthy).userNotes = "typed after the restore"
        #expect(scene.model.saveCatalogNow() == false, "nothing may be committed into the restored file by this session")
        #expect(CatalogQuitRecovery.saveAtTermination(model: scene.model) == .readOnlySession(words: CatalogReadOnlyFacts.restoredWords))
        #expect(try scene.workFolders().isEmpty)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("START Restore from Backup"))
        #expect(log.contains("OUTCOME restored catalog.sqlite from test.videoscanbundle: generation \(liveGeneration) → \(sealed.generation)"))

        // The catalog as it was: in the (test) Trash, sealed, with the later edit.
        #expect(restored.safetyCopy.path.hasPrefix(MediaTrash.testHostTrash.path), "the safety copy went through MediaTrash.move")
        #expect(try await notes(inSealed: restored.safetyCopy).contains("typed after the backup"))

        // Relaunch: the reload is the launch.
        let fresh = try await scene.relaunched()
        #expect(fresh.isReadOnly)
        #expect(fresh.catalogCutover.canAdopt)
        let healthy = try #require(fresh.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) })
        #expect(healthy.userNotes == "as backed up")
        let request = try #require(await fresh.catalogCutover.adoptRequestIfAdoptable())
        #expect(request.databaseGeneration == sealed.generation && request.highWater == liveGeneration)
        #expect(await fresh.catalogCutover.adopt(request) == .adopted(from: sealed.generation, to: liveGeneration))
        #expect(fresh.isReadOnly == false)
        healthy.userNotes = "after adopt"
        #expect(fresh.saveCatalogNow())
        if let committer = fresh.catalogCutover.committer { await committer.repository.close() }
    }

    // MARK: Refusals — nothing changed

    private func expectRefusedUnchanged(_ scene: CutoverScene, saying words: String,
                                        context: CatalogBackupRestore.Context? = nil) async throws {
        let fingerprint = try scene.databaseFingerprint()
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: try context ?? scene.restoreContext())
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains(words), Comment(rawValue: reason))
        #expect(try scene.databaseFingerprint() == fingerprint, "a refusal changed catalog.sqlite (+ -wal)")
        #expect(try scene.workFolders().isEmpty, "a work folder was left beside catalog.sqlite")
        #expect(scene.model.catalogCutover.committer?.restoreStop == nil)
        #expect(scene.model.isReadOnly == false)
        #expect(scene.sandbox.catalogLogText().contains("REFUSED Restore from Backup"))
    }

    @Test("ISOLATION: a bundle whose catalog.sqlite does not match its manifest's SHA-256 is refused — nothing changed, still writable")
    func shaMismatchRefused() async throws {
        let scene = try CutoverScene.make("restore_sha"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("later", "after the backup")
        let bundled = scene.backupURL.appendingPathComponent("catalog.sqlite")
        var bytes = try Data(contentsOf: bundled)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: bundled)
        try await expectRefusedUnchanged(scene, saying: "does not match the SHA-256")
        try scene.expectWritable("after the refusal", "a refused restore gives nothing back to hold")
    }

    @Test("ISOLATION: a manifest whose generation is not the file's is refused — the numbers shown are the file's own")
    func manifestMismatchRefused() async throws {
        let scene = try CutoverScene.make("restore_manifest"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("later", "after the backup")
        try scene.rewriteManifest {
            $0.catalogDatabase?.generation += 1
            $0.catalogDatabase?.highWater = nil
        }
        try await expectRefusedUnchanged(scene, saying: "is not what its manifest recorded")
    }

    @Test("ISOLATION: a backup AT this Mac's high-water (it would open writable, unasked) is refused")
    func atHighWaterRefused() async throws {
        let scene = try CutoverScene.make("restore_highwater"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try await expectRefusedUnchanged(scene, saying: "not below this Mac's high-water")
    }

    @Test("ISOLATION: a bundle with no catalog.cutover beside its catalog.sqlite is refused")
    func missingLatchRefused() async throws {
        let scene = try CutoverScene.make("restore_latch"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("later", "after the backup")
        try FileManager.default.removeItem(at: scene.backupURL.appendingPathComponent("catalog.cutover"))
        try await expectRefusedUnchanged(scene, saying: "has no catalog.cutover")
    }

    @Test("ISOLATION: a catalog held by a job (MOPS-16) refuses the restore before it reads the bundle")
    func heldCatalogRefused() async throws {
        let scene = try CutoverScene.make("restore_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("later", "after the backup")
        let owner = CatalogWriteHoldOwner()
        _ = await scene.model.catalogStore.holdWrites(reason: "a test job is reading the catalog", owner: owner)
        try await expectRefusedUnchanged(scene, saying: "a test job is reading the catalog")
        _ = scene.model.catalogStore.releaseWriteHold()
    }

    @Test("Cancel at the confirmation: nothing changed, no work folder, the session writable")
    func cancelledChangesNothing() async throws {
        let scene = try CutoverScene.make("restore_cancel"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("later", "after the backup")
        let fingerprint = try scene.databaseFingerprint()
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: try scene.restoreContext(confirm: false))
        #expect(outcome == .cancelled)
        #expect(try scene.databaseFingerprint() == fingerprint)
        #expect(try scene.workFolders().isEmpty)
        try scene.expectWritable("after cancel", "cancel")
    }

    // MARK: A failure at each later step — the hold given back, the live catalog intact

    @Test("STEP: the safety copy cannot reach the Trash → refused, the hold given back, the live catalog intact and openable")
    func trashFailureGivesHoldBack() async throws {
        let scene = try CutoverScene.make("restore_trash"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        struct NoTrash: Error, LocalizedError { var errorDescription: String? { "this volume has no Trash" } }
        let context = try scene.restoreContext(trash: { _ in throw NoTrash() })
        try await expectRefusedUnchanged(scene, saying: "could not be moved to the Trash", context: context)
        try scene.expectWritable("after the refusal", "the hold was given back")
        let fresh = try await scene.relaunched()
        #expect(fresh.isReadOnly == false, "the live catalog opens writable")
        #expect(fresh.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) }?.userNotes == "after the refusal")
        if let committer = fresh.catalogCutover.committer { await committer.repository.close() }
    }

    @Test("STEP: the store refuses the restore after the hold (its staged copy damaged under it) → the hold given back, the live catalog intact")
    func storeRefusalGivesHoldBack() async throws {
        let scene = try CutoverScene.make("restore_store"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let folder = scene.folder
        // The Trash step runs after verify and before the store's restore:
        // it trashes for real, then damages the verified staged copy.
        let context = try scene.restoreContext(trash: { url in
            let landed = try MediaTrash.move(url)
            let staged = try stagedCopies(in: folder)
            #expect(staged.count == 1)
            for url in staged {
                try unlock(url)
                try Data(repeating: 0, count: 100).write(to: url)
            }
            return landed
        })
        let fingerprint = try scene.databaseFingerprint()
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: context)
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains("changed after it was checked"), Comment(rawValue: reason))
        #expect(scene.model.isReadOnly == false, "editing given back")
        #expect(try scene.databaseFingerprint() == fingerprint)
        #expect(try scene.workFolders().isEmpty)
        try scene.expectWritable("after the refusal", "the hold was given back")
        let fresh = try await scene.relaunched()
        #expect(fresh.isReadOnly == false)
        if let committer = fresh.catalogCutover.committer { await committer.repository.close() }
    }
}

// MARK: - Codex #384 round 1 (P1/P2): bound to the verified bytes; editing paused; committed means stopped

/// The staged (verified) copies under every `.restore-*` work folder in `folder`.
private func stagedCopies(in folder: URL) throws -> [URL] {
    let fm = FileManager.default
    var found: [URL] = []
    for name in try fm.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(CatalogBackupRestore.workFolderPrefix) {
        guard let walk = fm.enumerator(at: folder.appendingPathComponent(name), includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walk where url.lastPathComponent == "backup-catalog.sqlite" { found.append(url) }
    }
    return found
}

/// A determined change: give the owner write permission back on the file
/// and its folder (the door takes it away), the way a person could.
private func unlock(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
}

/// Run `sql` on the plain SQLite file at `url` (rollback journal: nothing left beside it).
private func execute(_ sql: String, on url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        sqlite3_close(db); throw CutoverFailure(words: "open \(url.path)")
    }
    defer { sqlite3_close(db) }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
        let words = error.map { String(cString: $0) } ?? "?"
        sqlite3_free(error)
        throw CutoverFailure(words: "\(sql): \(words)")
    }
}

/// The trash seam parks here until the test lets it go (it runs off the main actor).
final class RestorePark: @unchecked Sendable {
    let arrived = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    /// Wait for the seam without blocking the main actor.
    func waitArrived() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.arrived.wait(); done.resume() }
        }
    }
}

@Suite("Restore from Backup — codex #384: verified bytes, editing paused, committed means stopped", .serialized)
@MainActor
struct CatalogRestoreCodex384Tests {

    /// Restore with a trash seam that trashes for real and then runs `after`
    /// on the staged copy (off the main actor, after verify, before the store's restore).
    private func runWithStagedChange(_ scene: CutoverScene,
                                     _ change: @escaping @Sendable (URL) throws -> Void) async throws -> CatalogBackupRestore.Outcome {
        let folder = scene.folder
        let context = try scene.restoreContext(trash: { url in
            let landed = try MediaTrash.move(url)
            for staged in try stagedCopies(in: folder) { try change(staged) }
            return landed
        })
        return await CatalogBackupRestore.run(bundle: scene.backupURL, context: context)
    }

    private func expectRefusedLiveUntouched(_ scene: CutoverScene, _ fingerprint: String, _ outcome: CatalogBackupRestore.Outcome,
                                            saying words: String) throws {
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains(words), Comment(rawValue: reason))
        #expect(try scene.databaseFingerprint() == fingerprint, "the live catalog changed")
        #expect(try scene.workFolders().isEmpty)
        #expect(scene.model.catalogCutover.committer?.restoreStop == nil)
        #expect(scene.model.isReadOnly == false, "editing is given back on a refusal")
        try scene.expectWritable("after the refusal", "the hold and editing were given back")
    }

    @Test("P1: a valid same-generation change to the verified copy after verification (UPDATE notes) is refused — the live catalog untouched")
    func modifiedAfterVerificationRefused() async throws {
        let scene = try CutoverScene.make("restore_tamper"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.healthy).userNotes = "as backed up"
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let fingerprint = try scene.databaseFingerprint()
        let outcome = try await runWithStagedChange(scene) { staged in
            try unlock(staged)
            try execute("UPDATE user_notes SET text = 'tampered'; UPDATE generations SET saved_from_host = 'tampered' WHERE id = 1",
                        on: staged)
        }
        try expectRefusedLiveUntouched(scene, fingerprint, outcome, saying: "changed after it was checked")
    }

    @Test("P1: the verified copy replaced by another valid catalog at the same generation is refused — the live catalog untouched")
    func replacedAfterVerificationRefused() async throws {
        let scene = try CutoverScene.make("restore_replace"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.healthy).userNotes = "as backed up"
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let fingerprint = try scene.databaseFingerprint()
        let outcome = try await runWithStagedChange(scene) { staged in
            try unlock(staged)
            let other = staged.deletingLastPathComponent().appendingPathComponent("other.sqlite")
            try FileManager.default.copyItem(at: staged, to: other)
            try execute("UPDATE generations SET saved_from_host = 'another catalog' WHERE id = 1", on: other)
            _ = try FileManager.default.replaceItemAt(staged, withItemAt: other)
        }
        try expectRefusedLiveUntouched(scene, fingerprint, outcome, saying: "changed after it was checked")
    }

    @Test("P2: a safety copy damaged in the Trash (same length) is refused before the first write — proven by identity and full SHA-256")
    func safetyCopyDamagedInTrashRefused() async throws {
        let scene = try CutoverScene.make("restore_safety_sha"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let fingerprint = try scene.databaseFingerprint()
        let context = try scene.restoreContext(trash: { url in
            let landed = try MediaTrash.move(url)
            var bytes = try Data(contentsOf: landed)
            bytes[bytes.count / 2] ^= 0xFF
            let handle = try FileHandle(forWritingTo: landed)
            try handle.write(contentsOf: bytes)
            try handle.close()
            return landed
        })
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: context)
        try expectRefusedLiveUntouched(scene, fingerprint, outcome, saying: "does not match the copy that was checked")
    }

    @Test("P1: editing is paused from the confirmation to the end — mid-restore the session is read-only in words, a save is refused, the quit says why; the restore then completes")
    func editingPausedMidRestore() async throws {
        let scene = try CutoverScene.make("restore_paused"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let park = RestorePark()
        let context = try scene.restoreContext(trash: { url in
            let landed = try MediaTrash.move(url)
            park.arrived.signal()
            park.proceed.wait()
            return landed
        })
        let bundle = scene.backupURL
        let running = Task { await CatalogBackupRestore.run(bundle: bundle, context: context) }
        await park.waitArrived()
        // Mid-restore: the safety copy exists, the store has not been written.
        #expect(scene.model.isReadOnly, "the model must not accept edits while the restore runs")
        let words = scene.model.readOnlyFacts.readOnlyWords ?? ""
        #expect(words.contains("restoring the catalog — editing is paused"), Comment(rawValue: words))
        try scene.record(.healthy).userNotes = "typed mid-restore"
        #expect(scene.model.saveCatalogNow() == false, "a mid-restore save is refused, not taken")
        #expect(CatalogQuitRecovery.saveAtTermination(model: scene.model) == .readOnlySession(words: CatalogReadOnlyFacts.restoringWords))
        park.proceed.signal()
        let outcome = await running.value
        guard case .restored = outcome else { Issue.record("expected restored, got \(outcome)"); return }
        #expect(scene.model.isReadOnly && scene.model.readOnlyFacts.restoredFromBackup)
    }

    @Test("P1: a failure AFTER the copy committed is restoredUnverified — the store closed, the committer stopped, the session read-only")
    func failureAfterCommitStopsTheSession() async throws {
        let scene = try CutoverScene.make("restore_after_commit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try await scene.backUp()
        try scene.expectWritable("typed after the backup", "after the backup")
        let committer = try #require(scene.model.catalogCutover.committer)
        let store = try #require(committer.repository as? GRDBCatalogRepository)
        struct ReadBackFailed: Error {}
        await store.injectRestoreAfterCommitHook { throw ReadBackFailed() }
        let outcome = await CatalogBackupRestore.run(bundle: scene.backupURL, context: try scene.restoreContext())
        guard case .restoredUnverified(let why, _) = outcome else { Issue.record("expected restoredUnverified, got \(outcome)"); return }
        #expect(why.contains("ReadBackFailed"), Comment(rawValue: why))
        #expect(committer.restoreStop != nil, "the committer stopped for good")
        #expect(scene.model.isReadOnly && scene.model.readOnlyFacts.restoredFromBackup)
        await #expect(throws: CatalogRepositoryError.self) { _ = try await committer.repository.read { $0.generation } }
        try scene.record(.healthy).userNotes = "typed after"
        #expect(scene.model.saveCatalogNow() == false)
    }
}

// MARK: - Sensor

@Suite("Restore from Backup — source sensors")
struct CatalogRestoreFromBackupSensorTests {

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Code lines only (a `//` line is a comment).
    private static func code(_ text: String) -> String {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("the door never moves, replaces or publishes over catalog.sqlite; it restores through the store's backup-API door and trashes through MediaTrash")
    func doorNeverReplacesTheFile() throws {
        let door = Self.code(try Self.source("VideoScan/Catalog/CatalogBackupRestore.swift"))
        let core = Self.code(try Self.source("VideoScanCore/Sources/VideoScanCore/Store/CatalogDatabaseRestore.swift"))
        #expect(door.count > 1_000 && core.count > 1_000, "the scan read both files")
        // ".moveItem(" with its dot: "removeItem(" (the work folder's one
        // removal, classified in OneEngineSensorTests) contains "moveItem(".
        for forbidden in [".moveItem(", "replaceItem", "AtomicFilePublish", "rename(", "renamex_np(", "unlink(", "trashItem("] {
            #expect(!door.contains(forbidden), Comment(rawValue: "CatalogBackupRestore.swift uses \(forbidden)"))
            #expect(!core.contains(forbidden), Comment(rawValue: "CatalogDatabaseRestore.swift uses \(forbidden)"))
        }
        #expect(door.contains("committer.repository.restore(fromSealedCopy:"))
        #expect(door.contains("try MediaTrash.move($0)"))
        #expect(core.contains("src.backup(to: db, pagesPerStep: pagesPerStep)"))
        #expect(!core.contains("CatalogHighWater.write") && !core.contains("CatalogHighWaterLedger.append"),
                "a restore never writes this Mac's high-water witnesses")
    }
}
