// CatalogCutoverB22Tests.swift
// Cutover B2.2 — the SQLite commit path made SYNCHRONOUS on the main actor
// (docs/reviews/codex/codex-review-cutover-b2-1-closing-pass-2026-10-17.md,
// "Codex answer"). Codex's five open reproductions, written red first
// against efab05ed8+:
//   (a) two copies of one content edited differently before one commit:
//       the app ends showing what the store holds (propagation follows the
//       LAST committed value — CatalogCommitBaseline.swift:244);
//   (b) a new row's first insert, then Trash → Undo: both revisions land
//       (CatalogCommitBaseline.swift:73);
//   (c) a failed pending UPDATE leaves the row NOT durable — the old payload
//       never certifies the newer edit (CatalogCommitBaseline.swift:174/:108);
//   (d) note A → B → Trash → A → Undo: the store ends at A
//       (CatalogCommitter.swift:366 + CatalogCommitBody.swift:142);
//   (e) a held row momentarily absent at one commit keeps its payload
//       (GRDBCatalogRepository+LivePending.swift:58).
// (a) as codex wrote it ("edit B DURING the commit") and (b) as codex wrote
// it ("Trash → Undo DURING the first insert's flight") were red through the
// removed seams `afterSnapshotForTesting` / `beforeAbsorbForTesting`. Since
// B2.2 a commit is one synchronous main-actor turn, so "during" cannot be
// written: CatalogCommitterSyncSensorTests pins that, and the cases here keep
// what the person sees.
// Dimensions: LOGIC (a–e; a batch of marker changes is one commit; two
// absences purge; a synchronous save purges at once); ISOLATION (c injects a
// store refusal through a sandbox trigger, never a real file); SCALE in Core
// (CatalogCommitScaleTests.syncCommit*: 1 row < 150 ms, 1,000 rows < 1.5 s at
// 14k rows); SENSOR CatalogCommitterSyncSensorTests (no Task / semaphore /
// actor hop between snapshot and baseline adoption); MEDIA N/A — no media is
// opened. Every case runs in a sandbox folder (CutoverScene), never
// Application Support.
//
// Suites (filter by SUITE): CatalogCommitSyncTests · CatalogCommitterSyncSensorTests

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// A new record WITH a whole-file hash (a fresh content): its first
    /// commit inserts a `files` row.
    func freshStored(of shape: PoisonedCatalogFixture.Shape, path: String, digestFill: Character) throws -> VideoRecord {
        let fresh = try freshCopy(of: shape, path: path)
        fresh.contentFixity = ContentFixity(digest: String(repeating: digestFill, count: 64), byteCount: fresh.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 9, size: fresh.sizeBytes, mtimeNs: 3,
                                                                     ctimeNs: 4, volumeUUID: nil))
        return fresh
    }

    /// The tombstone revisions of any row, read through the seam.
    func tombstoneRevisions(id: UUID) async throws -> [Int] {
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: databaseURL)
        do {
            let revisions = try await repository.read { try $0.tombstoneRevisions(fileID: id.uuidString) }
            await repository.close()
            return revisions
        } catch {
            await repository.close()
            throw error
        }
    }

    /// How many `pending_rows` payloads the sandbox database holds for `id`
    /// (tombstoned or not), through a second, read-only connection.
    func pendingPayloadCount(_ id: UUID) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CutoverFailure(words: "sqlite3_open_v2 failed on the sandbox database")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM pending_rows WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "sqlite3_prepare_v2 failed")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CutoverFailure(words: "sqlite3_step returned no row") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Run one SQL statement on the sandbox database through a second
    /// connection (a test-only fault: a trigger that refuses an UPDATE).
    func execSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CutoverFailure(words: "sqlite3_open_v2 failed on the sandbox database")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let words = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            throw CutoverFailure(words: "sqlite3_exec: \(words)")
        }
    }
}

@Suite("Catalog commit B2.2 — synchronous on the main actor: codex's five reproductions", .serialized)
@MainActor
struct CatalogCommitSyncTests {

    // B2.3 (regression F2, Manager's rule 2026-10-18): two copies edited
    // DIFFERENTLY in one commit are a conflict — nothing dropped. Was: "each
    // copy shows what the store holds" (the records-order winner).
    @Test("(a) B2.3: two copies edited differently before one commit: each keeps its own; the store holds a conflict (empty)")
    func copiesEditedDifferentlyAreAConflict() async throws {
        let scene = try CutoverScene.make("b22_copies"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.userNotes = "one"
        b.userNotes = "two"
        #expect(scene.model.saveCatalogNow())
        #expect(a.userNotes == "one")
        #expect(b.userNotes == "two")
        #expect(try await scene.reloaded(.curatedConflictA).userNotes.isEmpty)
        #expect(try await scene.reloaded(.curatedConflictB).userNotes.isEmpty)
        #expect(try scene.committer().changedRecordCount() == 0)
    }

    @Test("(b) a new row's first insert, then Trash → Undo before the next save: both revisions land")
    func trashUndoAfterFirstInsert() async throws {
        let scene = try CutoverScene.make("b22_first_insert"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let fresh = try scene.freshStored(of: .healthy, path: "/Volumes/Fixture/New/inserted.mov", digestFill: "e")
        scene.model.records.append(fresh)
        #expect(await scene.model.saveCatalogAcknowledged())
        let before = RemovalMirrors.of(fresh)
        VideoScanModel.stampRemoval(fresh, .removedFromCatalog(at: Date(), reason: .userRemoved))
        VideoScanModel.revertRemoval(fresh, wrote: fresh.removal, previous: nil, revision: fresh.removalRevision,
                                     mirrorsBefore: before, mirrorsAfter: RemovalMirrors.of(fresh))
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.tombstoneRevisions(id: fresh.id) == [1, 2])
    }

    @Test("(b) a batch: every live row trashed in one turn is ONE commit; Undo of all in the next turn is one more")
    func batchIsOneCommit() async throws {
        let scene = try CutoverScene.make("b22_batch"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow())
        let live = scene.model.records.filter { $0.removal == nil }
        let mirrors = live.map(RemovalMirrors.of)
        let before = committer.commitCount
        for record in live { VideoScanModel.stampRemoval(record, .removedFromCatalog(at: Date(), reason: .userRemoved)) }
        try await scene.settle()
        #expect(committer.commitCount == before + 1)
        for (record, was) in zip(live, mirrors) {
            VideoScanModel.revertRemoval(record, wrote: record.removal, previous: nil, revision: record.removalRevision,
                                         mirrorsBefore: was, mirrorsAfter: RemovalMirrors.of(record))
        }
        try await scene.settle()
        #expect(committer.commitCount == before + 2)
        #expect(committer.changedRecordCount() == 0)
        #expect(try await scene.tombstoneRevisions(.healthy) == [1, 2])
    }

    @Test("(c) codex: a failed pending UPDATE is not certified by the older held payload")
    func failedPendingUpdateNotDurable() async throws {
        let scene = try CutoverScene.make("b22_held_fp"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/held.mov")
        scene.model.records.append(fresh)
        #expect(scene.model.saveCatalogNow(), "a held row is durable")
        try scene.execSQL("CREATE TRIGGER b22_refuse_pending_update BEFORE UPDATE ON pending_rows "
                          + "BEGIN SELECT RAISE(ABORT, 'b22 test: pending update refused'); END")
        fresh.userNotes = "typed after it was held"
        #expect(scene.model.saveCatalogNow() == false, "the update was refused")
        #expect(scene.model.saveCatalogNow() == false, "the old payload does not hold the new notes")
        try scene.execSQL("DROP TRIGGER b22_refuse_pending_update")
        fresh.userNotes = "typed again once the store took updates"
        #expect(scene.model.saveCatalogNow())
        try await scene.relaunch()
        let back = try #require(scene.model.records.first { $0.id == fresh.id })
        #expect(back.userNotes == "typed again once the store took updates")
    }

    @Test("(d) codex: note A → B → Trash → A → Undo: catalog.sqlite ends at A")
    func curatedReversionAcrossMarkers() async throws {
        let scene = try CutoverScene.make("b22_reversion"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.userNotes = "A"
        #expect(scene.model.saveCatalogNow())
        healthy.userNotes = "B"
        let before = RemovalMirrors.of(healthy)
        VideoScanModel.stampRemoval(healthy, .removedFromCatalog(at: Date(), reason: .userRemoved))
        healthy.userNotes = "A"
        VideoScanModel.revertRemoval(healthy, wrote: healthy.removal, previous: nil, revision: healthy.removalRevision,
                                     mirrorsBefore: before, mirrorsAfter: RemovalMirrors.of(healthy))
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.healthy).userNotes == "A")
        #expect(try await scene.tombstoneRevisions(.healthy) == [1, 2])
    }

    @Test("(e) codex: a held row absent at ONE background commit keeps its payload")
    func momentaryAbsenceKeepsPayload() async throws {
        let scene = try CutoverScene.make("b22_absent_once"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/rescanned.mov")
        scene.model.records.append(fresh)
        #expect(scene.model.saveCatalogNow(), "a held row is durable")
        scene.model.records.removeAll { $0.id == fresh.id }
        committer.scheduleCommit(after: .zero)
        try await scene.settle()
        scene.model.records.append(fresh)
        // A crash here: no further save.
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.contains { $0.id == fresh.id })
    }

    // B2.3 (codex B2.2 finding (e)): absence never purges. The two B2.2
    // cases that pinned "absent twice → purged" and "a synchronous save
    // purges what is absent" now pin the opposite: KEPT, and a door's
    // explicit purge is what removes a held row (its payload still kept).

    @Test("(e) B2.3: a held row absent at two background commits and a quit is KEPT — absence is not a purge")
    func absentTwiceKept() async throws {
        let scene = try CutoverScene.make("b22_absent_twice"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/removed.mov")
        scene.model.records.append(fresh)
        #expect(scene.model.saveCatalogNow(), "a held row is durable")
        scene.model.records.removeAll { $0.id == fresh.id }
        committer.scheduleCommit(after: .zero)
        try await scene.settle()
        committer.scheduleCommit(after: .zero)
        try await scene.settle()
        #expect(scene.model.saveCatalogNow())
        #expect(committer.heldIDs.contains(fresh.id))
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.contains { $0.id == fresh.id })
        #expect(scene.sandbox.catalogLogText().contains("left memory without a purge — kept in the catalog"))
    }

    @Test("(e) B2.3: a door's explicit purge of a held row removes it at once — the payload still kept")
    func explicitPurgeOfHeldRow() async throws {
        let scene = try CutoverScene.make("b22_absent_quit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/gone.mov")
        scene.model.records.append(fresh)
        #expect(scene.model.saveCatalogNow())
        scene.model.records.removeAll { $0.id == fresh.id }
        scene.model.purgeCatalogRows(ids: [fresh.id], reason: "test door")
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.contains { $0.id == fresh.id } == false)
        #expect(try scene.pendingPayloadCount(fresh.id) == 1, "the payload is kept")
    }
}

// MARK: - SENSOR: one synchronous turn

@Suite("Catalog committer sync sensor — no Task, semaphore or main-actor hop between snapshot and baseline adoption", .serialized)
@MainActor
struct CatalogCommitterSyncSensorTests {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VideoScan")

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The committer's commit section: from its MARK to the words.
    private static func commitSection() throws -> String {
        let text = try source("Catalog/CatalogCommitter.swift")
        let start = try #require(text.range(of: "// MARK: - One commit"))
        let end = try #require(text.range(of: "// MARK: - Words"))
        return String(text[start.lowerBound..<end.lowerBound])
    }

    @Test("the commit section has no await, async, Task, Dispatch, semaphore or launch-wait")
    func commitSectionIsSynchronous() throws {
        let section = try Self.commitSection()
        for word in ["await", "async", "Task", "Dispatch", "Semaphore", "LaunchWait", "detached"] {
            #expect(section.contains(word) == false, Comment(rawValue: "CatalogCommitter's commit section contains \(word)"))
        }
    }

    @Test("the committer has no flight: no detached task, no semaphore, no launch-wait, no test seams")
    func noFlightMachinery() throws {
        let text = try Self.source("Catalog/CatalogCommitter.swift")
        for word in ["Task.detached", "DispatchSemaphore", "CatalogLaunchWait", "Flight", "afterSnapshotForTesting",
                     "beforeAbsorbForTesting", "CatalogCommit.run("] {
            #expect(text.contains(word) == false, Comment(rawValue: "CatalogCommitter.swift contains \(word)"))
        }
        #expect(text.contains("CatalogCommit.runBlocking("))
    }

    @Test("the baseline is plain bookkeeping: no await, Task or marker journal")
    func baselineIsSynchronous() throws {
        let text = try Self.source("Catalog/CatalogCommitBaseline.swift")
        for word in ["await", "Task", "takeJournal", "restoreJournal", "noteMarker"] {
            #expect(text.contains(word) == false, Comment(rawValue: "CatalogCommitBaseline.swift contains \(word)"))
        }
    }

    @Test("only the committer runs the blocking commit")
    func onlyTheCommitterBlocks() throws {
        let files = FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "CatalogCommitter.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("runBlocking(") || text.contains("writeBlocking(") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: ", ")))
    }

    @Test("quit is one call: the commit has run and its truth is known when commitNow returns")
    func quitIsOneCall() async throws {
        let scene = try CutoverScene.make("b22_sensor_quit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let before = committer.commitCount
        try scene.record(.healthy).starRating = 2
        #expect(committer.commitNow())
        #expect(committer.commitCount == before + 1)
        #expect(committer.isBusy == false)
        #expect(committer.changedRecordCount() == 0)
    }
}
