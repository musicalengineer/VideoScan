// CatalogCutoverB23Tests.swift
// Cutover B2.3 — the last two codex findings on the SQLite write side
// (docs/reviews/codex/codex-review-cutover-b2-2-synchronous-commit-2026-10-17.md,
// "Codex answer"), written RED FIRST against f3900b36f:
//
//   P1  a failed marker pre-commit must VETO the marker change. Codex: stored
//       revision 0 → hold → Trash (1) → Undo (2) → release: revision 1 was
//       never stored, the store refuses 2 and every later whole-row save
//       (stars, notes) with it.
//   (e) rescan purge by inferred absence → EXPLICIT purge only. A record that
//       leaves memory without a door saying "purge it" stays in catalog.sqlite
//       (and is logged once); a door that removes a record purges its id in
//       the same turn.
//
// Dimensions: LOGIC (both reproductions, the doors); ISOLATION (a sandbox
// catalog folder, the MOPS-16 hold taken through the real CatalogStore API);
// SENSOR CatalogPurgeDoorSensorTests (every row-removal door calls the purge);
// SCALE in Core (CatalogCommitScaleTests, unchanged pipeline); MEDIA N/A — no
// media is opened.
//
// Suites (filter by SUITE): CatalogMarkerVetoTests · CatalogExplicitPurgeTests ·
// CatalogPurgeDoorSensorTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Take the MOPS-16 write hold as an import job would.
    func hold() async {
        _ = await model.catalogStore.holdWrites(reason: "a test import is reading the catalog", owner: CatalogWriteHoldOwner())
    }

    func release() {
        model.catalogStore.releaseWriteHold()
    }

    /// Mark `record` In the Trash through the one marker writer.
    func trash(_ record: VideoRecord) {
        VideoScanModel.stampRemoval(record, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
    }

    /// What a rescan's probe makes of the file `source` describes: the same
    /// fields under a NEW id, no whole-file hash, no curated values.
    func probe(of source: VideoRecord) throws -> VideoRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(VideoRecordDTO(source))) as? [String: Any])
        object["id"] = UUID().uuidString
        object["contentFixity"] = nil
        object["archiveFixity"] = nil
        object["pairedWithID"] = nil
        object["starRating"] = 0
        object["userNotes"] = ""
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Undo the marker write `record` carries now (the audit's undo shape).
    @discardableResult
    func undo(_ record: VideoRecord, mirrorsBefore: RemovalMirrors) -> Bool {
        VideoScanModel.revertRemoval(record, wrote: record.removal, previous: nil, revision: record.removalRevision,
                                     mirrorsBefore: mirrorsBefore, mirrorsAfter: RemovalMirrors.of(record))
    }
}

// MARK: - P1: a failed marker pre-commit vetoes the change

@Suite("Catalog marker veto — a marker change the catalog cannot save is refused, never applied", .serialized)
@MainActor
struct CatalogMarkerVetoTests {

    @Test("codex P1 (Manager's pin): rev 0 stored → hold → Trash refused → release → Trash → Undo → both stored; stars save")
    func heldTrashIsRefused() async throws {
        let scene = try CutoverScene.make("b23_veto_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.saveCatalogNow(), "revision 0 is stored")
        await scene.hold()
        scene.trash(healthy)
        #expect(healthy.removalRevision == 0, "a held catalog refuses the marker change")
        #expect(healthy.removal == nil, "the row stays live")
        scene.release()
        let before = RemovalMirrors.of(healthy)
        scene.trash(healthy)
        #expect(healthy.removalRevision == 1)
        #expect(scene.undo(healthy, mirrorsBefore: before))
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.tombstoneRevisions(.healthy) == [1, 2])
        healthy.starRating = 2
        #expect(scene.model.saveCatalogNow(), "a later star edit saves")
        #expect(try await scene.reloaded(.healthy).starRating == 2)
    }

    @Test("codex P1 (exact): Trash's commit not yet run → hold → Undo is VETOED → release: rev 1 stored, later edits save")
    func undoWhileHeldIsVetoed() async throws {
        let scene = try CutoverScene.make("b23_veto_undo"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.saveCatalogNow(), "revision 0 is stored")
        let before = RemovalMirrors.of(healthy)
        scene.trash(healthy)                       // revision 1, its commit asked for at once…
        await scene.hold()                         // …but the hold lands first
        #expect(try scene.committer().changedRecordCount() == 1, "revision 1 is not in the store yet")
        scene.undo(healthy, mirrorsBefore: before)
        #expect(healthy.removalRevision == 1, "Undo is vetoed: revision 1 cannot be stored first")
        #expect(healthy.removal != nil, "the row stays In the Trash")
        scene.release()
        #expect(scene.model.saveCatalogNow(), "revision 1 lands once the hold is let go")
        #expect(try await scene.tombstoneRevisions(.healthy) == [1])
        healthy.starRating = 3
        #expect(scene.model.saveCatalogNow(), "a later star edit saves")
        #expect(try await scene.reloaded(.healthy).starRating == 3)
    }
}

// MARK: - (e): explicit purge only

@Suite("Catalog explicit purge — only a door that removes a record purges its row; absence alone never does", .serialized)
@MainActor
struct CatalogExplicitPurgeTests {

    @Test("codex (e): a record absent from memory across 3 commits and a quit, with no door's purge, stays in catalog.sqlite")
    func absenceNeverPurges() async throws {
        let scene = try CutoverScene.make("b23_absent"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 3
        #expect(scene.model.saveCatalogNow())
        scene.model.records.removeAll { $0.id == healthy.id }     // an unlisted path — a bug, not a door
        for _ in 0..<3 {
            committer.scheduleCommit(after: .zero)
            try await scene.settle()
        }
        #expect(scene.model.saveCatalogNow())
        let reloaded = try await scene.sqliteLoad()
        let kept = try #require(reloaded.records.first { $0.id == healthy.id }, "the row was purged by inference")
        #expect(kept.starRating == 3)
        #expect(reloaded.purgedCount == 0)
    }

    @Test("a long rescan swapping ids across 3 commits: the file's row lives under the newest id with its values; old ids purged")
    func rescanSwapsKeepValues() async throws {
        let scene = try CutoverScene.make("b23_rescan"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let original = try scene.record(.healthy)
        original.starRating = 3
        original.userNotes = "the lake house"
        #expect(scene.model.saveCatalogNow())
        let path = original.fullPath
        let root = (path as NSString).deletingLastPathComponent
        let target = CatalogScanTarget(searchPath: root)
        var retired: [UUID] = []
        for _ in 0..<3 {
            let current = try #require(scene.model.records.first { $0.fullPath == path })
            scene.model.snapshotPreservedFieldsForRescan(of: target)
            let probed = try scene.probe(of: current)                         // a new id, no curated values
            scene.model.applyPreservedFieldsAfterRescan(of: target, onto: [probed])
            await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [probed], scanWasComplete: false)
            retired.append(current.id)
            scene.model.saveCatalogDebounced()                                  // the scan's own save: a background commit
            try await scene.settle()
        }
        #expect(scene.model.saveCatalogNow())
        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.count == 1, "one row for the file — nothing hidden, nothing doubled")
        #expect(atPath.first?.starRating == 3)
        #expect(atPath.first?.userNotes == "the lake house")
        #expect(retired.allSatisfy { id in !reloaded.records.contains { $0.id == id } }, "the replaced ids were purged")
    }

    @Test("Delete All: every row purged — the relaunch holds no record")
    func deleteAllPurges() async throws {
        let scene = try CutoverScene.make("b23_delete_all"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let count = scene.model.records.count
        scene.model.deleteAllCatalog()
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.isEmpty)
        #expect(reloaded.purgedCount == count)
    }

    @Test("Remove from Catalog keeps the row (GH #143): stored with its marker, never purged")
    func removeFromCatalogKeepsTheRow() async throws {
        let scene = try CutoverScene.make("b23_remove"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.purgeRecords(ids: [healthy.id]) == 1)
        #expect(scene.model.saveCatalogNow())
        let back = try await scene.reloaded(.healthy)
        #expect(back.removal?.state == .removedFromCatalog)
        #expect(try await scene.sqliteLoad().purgedCount == 0)
    }
}

// MARK: - P1: the words, and the doors that show them

@Suite("Catalog marker veto — the words and the doors", .serialized)
@MainActor
struct CatalogMarkerVetoDoorTests {

    @Test("the refusal says what, why and when: can't move <name> to the Trash right now — the catalog can't save (…); try again when …")
    func refusalWords() async throws {
        let scene = try CutoverScene.make("b23_words"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        await scene.hold()
        defer { scene.release() }
        let words = VideoScanModel.stampRemoval(healthy, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))
        #expect(words == "can't move \(healthy.filename) to the Trash right now — the catalog can't save "
                + "(held — a test import is reading the catalog); try again when that job finishes")
        #expect(scene.sandbox.catalogLogText().contains("REFUSED a removal-marker change"))
    }

    @Test("an identical re-stamp is not a change: never refused, even while held")
    func identicalRestampNeverRefused() async throws {
        let scene = try CutoverScene.make("b23_same"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let marker = RemovalMarker.removedFromCatalog(at: Date(timeIntervalSince1970: 1_790_000_000), reason: .userRemoved)
        VideoScanModel.stampRemoval(healthy, marker)
        #expect(scene.model.saveCatalogNow())
        await scene.hold()
        defer { scene.release() }
        #expect(VideoScanModel.stampRemoval(healthy, marker) == nil)
        #expect(healthy.removalRevision == 1)
    }

    @Test("Remove from Catalog while held: nothing removed, the row live, no Undo banner")
    func removeWhileHeld() async throws {
        let scene = try CutoverScene.make("b23_remove_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        await scene.hold()
        defer { scene.release() }
        #expect(scene.model.purgeRecords(ids: [healthy.id]) == 0)
        #expect(healthy.removal == nil)
        #expect(scene.model.lastPurgedBatch == nil)
    }

    @Test("Restore while held: refused with the words; the marker untouched")
    func restoreWhileHeld() async throws {
        let scene = try CutoverScene.make("b23_restore_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        VideoScanModel.stampRemoval(healthy, .removedFromCatalog(at: Date(), reason: .userRemoved))
        #expect(scene.model.saveCatalogNow())
        await scene.hold()
        defer { scene.release() }
        let words = scene.model.clearRemoval(healthy)
        #expect(words?.hasPrefix("can't restore \(healthy.filename) right now — the catalog can't save") == true)
        #expect(healthy.removalRevision == 1)
    }

    @Test("a detached snapshot (not this session's live record) is never vetoed")
    func detachedSnapshotNotVetoed() async throws {
        let scene = try CutoverScene.make("b23_detached"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let snapshot = try scene.record(.healthy).snapshotClone()
        await scene.hold()
        defer { scene.release() }
        #expect(VideoScanModel.stampRemoval(snapshot, .missing(noticedAt: Date(), lastSeen: nil, reason: .duplicate),
                                            kind: .diskFact) == nil)
    }

    @Test("JSON authority: no committer for the model — the writer never refuses")
    func jsonAuthorityUnchanged() async throws {
        let scene = try CutoverScene.make("b23_json"); defer { scene.cleanup() }
        scene.model.records = scene.model.catalogStore.load()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.catalogCutover.isSQLiteAuthority == false)
        #expect(VideoScanModel.stampRemoval(healthy, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash)) == nil)
        #expect(healthy.removalRevision == 1)
    }
}

// MARK: - Regression F2: two copies edited differently in one commit

@Suite("Catalog copy conflict — two copies edited differently in one commit keep both values", .serialized)
@MainActor
struct CatalogCopyConflictTests {

    @Test("both values are in row_knowledge, each with its row id; the display row is conflict = 1")
    func bothValuesKept() async throws {
        let scene = try CutoverScene.make("b23_conflict"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.curatedConflictA)
        let b = try scene.record(.curatedConflictB)
        a.starRating = 1
        b.starRating = 3
        #expect(scene.model.saveCatalogNow())
        #expect(try scene.sqliteRows("SELECT file_id || '=' || value_json FROM row_knowledge WHERE field = 'starRating' "
                                     + "ORDER BY rowid DESC LIMIT 2").sorted()
                == ["\(a.id.uuidString)=1", "\(b.id.uuidString)=3"].sorted())
        let rows = try scene.sqliteRows("SELECT conflict || '|' || ifnull(rating, '-') FROM stars "
                                        + "WHERE digest = (SELECT content_digest FROM files WHERE id = '\(a.id.uuidString)')")
        #expect(rows == ["1|-"], "the display row is a conflict with no value")
    }
}

@MainActor
extension CutoverScene {
    /// One text column of every row `sql` returns, through a read-only connection.
    func sqliteRows(_ sql: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }
}

// MARK: - Regression F3: the snapshot-gated doors under catalog.sqlite

@Suite("Catalog safety copy — under catalog.sqlite the pre-change snapshot is a sealed copy of catalog.sqlite", .serialized)
@MainActor
struct CatalogSQLiteSnapshotTests {

    @Test("snapshotCatalog writes catalog.<prefix>.<stamp>.sqlite that opens and holds the records; catalog.json untouched")
    func sealedCopy() async throws {
        let scene = try CutoverScene.make("b23_snapshot"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let json = try scene.sha256(scene.catalogURL)
        let path = try #require(scene.model.snapshotCatalog(prefix: "pre-test"))
        #expect(path.hasSuffix(".sqlite"))
        #expect(path.contains("catalog.pre-test."))
        let copy = try await CutoverScene.load(URL(fileURLWithPath: path))
        #expect(copy.records.count == scene.model.records.count)
        #expect(try scene.sha256(scene.catalogURL) == json)
        #expect(scene.sandbox.catalogLogText().contains("OUTCOME safety copy pre-test of catalog.sqlite"))
    }
}

// MARK: - SENSOR: every door that takes records out of the catalog purges them

@Suite("Catalog purge door sensor — every row-removal door names the ids it removed", .serialized)
@MainActor
struct CatalogPurgeDoorSensorTests {

    /// Files that drop records from the model's array but need no purge call
    /// of their own, each with why.
    static let exempt: [String: String] = [
        "Catalog/VideoScanModel+RecordIdentityRepair.swift": "drops twin INSTANCES of one id at launch — every id stays",
    ]

    /// Every place a record can leave `records`: the one-engine sensor's
    /// row-removal patterns, a whole-array assignment, and a replace-at-index.
    static let patterns = [#"\brecords\.remove\("#, #"\brecords\.removeAll\b"#, #"\brecords\.removeFirst\b"#,
                           #"\brecords\.removeLast\b"#, #"\brecords\s*=\s*records\.filter\b"#,
                           #"^(self\.)?records\s*=\s*(keep|restored|\[\])"#, #"\brecords\[[^\]]+\]\s*=[^=]"#]

    @Test("each row-removal door calls purgeCatalogRows(ids: — or is exempt with a reason")
    func everyDoorPurges() throws {
        let doors = Set(OneEngineSensorTests.hits(Self.patterns).keys)
            .union(OneEngineSensorTests.rowRemovalAllowlist.keys)
            .subtracting(["ArchiveAngel/Recommend/ArchiveAngelSweep.swift"])   // a local dictionary named `records`
        #expect(doors.count >= 9, "the scan found the doors")
        var silent: [String] = []
        for door in doors.sorted() where Self.exempt[door] == nil {
            let url = try #require(SourceTree.appSources.first { $0.relative == door }?.url, Comment(rawValue: door))
            let text = try String(contentsOf: url, encoding: .utf8)
            if !text.contains("purgeCatalogRows(ids:") { silent.append(door) }
        }
        #expect(silent.isEmpty, Comment(rawValue: "doors that remove records without purging them: \(silent)"))
    }

    @Test("the committer purges only what a door asked for — no absence inference left")
    func noInference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let baseline = try String(contentsOf: root.appendingPathComponent("VideoScan/Catalog/CatalogCommitBaseline.swift"), encoding: .utf8)
        #expect(baseline.contains("absentLastTime") == false)
        #expect(baseline.contains("final ? absent") == false)
        #expect(baseline.contains("func purges(requested: Set<UUID>, present: Set<UUID>)"))
    }
}
