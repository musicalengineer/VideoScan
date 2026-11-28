import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #478 (DECISIONS 2026-11-27 (1)): a different file at a known path
// takes Rick's values WITH A NOTE, the earlier record stays as history, and the
// carry is one undoable action
//
// RescanPreservedFields is keyed by PATH, so before this change a rescan that
// found a DIFFERENT file at a path (a re-encode, a re-export under the same
// name, another tape captured to the same filename) silently gave it the old
// file's date, place, tags, notes, people and stars, and purged the old row:
// nothing said the values had moved onto other bytes, and nothing could take
// them back off.
//
// The ruling: the values are CARRIED onto the new file's record, the new record
// gets a visible provenance note ("Copied from the earlier file <name> (SHA-256
// <prefix>) at this path on <date>; review if this is not the same footage"),
// the old row stays in the catalog as `replacedAtPath` history, and "Undo
// carry" on the new record puts back its own prior (blank) values. Never onto
// an archived content's date (GH #528): a new file that is a copy of archived
// content keeps the date it was filed under.
//
// "A different file": the rescan's evidence says so — both whole-file digests
// known and different, or a size change, or two partialMD5s that disagree. No
// evidence either way is the same file (carried as before, no note).
//
// Dimensions:
//   logic      different size / different fingerprint / different digest →
//              carried + note + history row; same bytes, no evidence, nothing
//              curated → as before; the partial merge as well; the second
//              rescan of the same file keeps the note and the history row
//   truth      the archived twin keeps its filed date; the note says which SHA
//              (or that none was computed); the summary line is plain words
//   isolation  a date typed on the OLD record while the scan ran is the one
//              carried, and the history row has it too
//   scale      100k re-seen paths, every other one a different file — inside
//              the Debug budget, ONE summary line
//   writer     catalog.sqlite: the merge inside an edit's debounce window and
//              during a write hold, then relaunch — the carried values, the
//              note and the history row are all stored
//              (undo across a role flip: RescanCarryUndoTests)
//   media      not applicable — no file is decoded; the decision reads the
//              probe's size, partialMD5 and whole-file digest only
//   production shape: ProductionShapeRescanCarryTests

@MainActor
@Suite("GH #478 — a different file at a known path takes Rick's values with a note; the old row stays as history", .serialized)
struct RescanCarryWithNoteTests {

    static let note = "review if this is not the same footage"

    static func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_rescan_carry_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func record(path: String, size: Int64, md5: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    static func fixity(_ digest: String, _ size: Int64) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 0), computedAt: Date())
    }

    /// Rick's curated values — every group the carry and its undo cover.
    @discardableResult
    static func curated(_ r: VideoRecord) -> VideoRecord {
        r.userDate = "1984-07"
        r.userDateConfidence = UserDateConfidence.known.rawValue
        r.userPlace = "Cape Cod"
        r.userPlaceConfidence = "estimated"
        r.mediaDisposition = .important
        r.tags = ["Reunion"]
        r.userNotes = "Grandpa at the lake"
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        r.starRating = 3
        return r
    }

    static func expectCurated(_ r: VideoRecord, _ comment: Comment) {
        #expect(r.userDate == "1984-07" && r.userDateConfidence == UserDateConfidence.known.rawValue, comment)
        #expect(r.userPlace == "Cape Cod", comment)
        #expect(r.mediaDisposition == .important, comment)
        #expect(r.tags == ["Reunion"], comment)
        #expect(r.userNotes == "Grandpa at the lake", comment)
        #expect(r.confirmedByUserPeople.map(\.name) == ["Donna"], comment)
        #expect(r.starRating == 3, comment)
    }

    static func model(root: URL, records: [VideoRecord]) -> VideoScanModel {
        let model = VideoScanModel()
        model.scanTargets = [CatalogScanTarget(searchPath: root.path)]
        model.records = records
        model.snapshotPreservedFieldsForRescan(of: model.scanTargets[0])
        return model
    }

    /// Fresh probe → apply → merge, as ScanExecution runs it.
    @discardableResult
    static func rescan(_ model: VideoScanModel, root: URL, fresh: [VideoRecord],
                       complete: Bool = true) async -> ScanMergeOutcome {
        model.applyPreservedFieldsAfterRescan(of: model.scanTargets[0], onto: fresh)
        return await model.commitScanResults(root: root.path, volName: "Test", targetRecords: fresh,
                                             scanWasComplete: complete)
    }

    static func console(_ model: VideoScanModel) async -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)   // the console flush debounce
        return model.dashboard.consoleLines.joined(separator: "\n")
    }

    static var today: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: Logic

    @Test("RED before #478 ruling: a re-encoded file at the same path (different size) takes the values WITH the provenance note; the old row stays as replacedAtPath history")
    func reEncodedFileCarriesWithNote() async throws {
        let root = try Self.makeRoot("size"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape01.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000, md5: "aaaa"))
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 2_000, md5: "bbbb")
        let outcome = await Self.rescan(model, root: root, fresh: [fresh])

        Self.expectCurated(fresh, "the new file's record carries Rick's values")
        #expect(fresh.notes.contains("Copied from the earlier file test_tape01.mov (SHA-256 not computed) at this path on \(Self.today); \(Self.note)"),
                "the visible provenance note: \(fresh.notes)")
        let kept = try #require(model.records.first { $0.id == old.id }, "the old row was purged")
        #expect(kept.removal?.reason == .replacedAtPath, "kept as history, not live")
        Self.expectCurated(kept, "the history row keeps the values it had")
        #expect(model.records.filter { $0.fullPath == path && $0.removal == nil }.map(\.id) == [fresh.id],
                "one live row at the path: the new file's")
        #expect(outcome.carriedWithNote == 1)
        let said = await Self.console(model)
        #expect(said.contains("1 file at a known path had changed; your dates and notes were copied onto it with a note — review it"),
                "console: \(said)")
        #expect(said.contains("test_tape01.mov"))
    }

    @Test("RED before #478 ruling: same size but a different partialMD5 is a different file; a whole-file digest names its SHA-256 prefix in the note")
    func differentFingerprintNamesTheDigest() async throws {
        let root = try Self.makeRoot("md5"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape02.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000, md5: "aaaa"))
        old.contentFixity = Self.fixity(String(repeating: "ab", count: 32), 1_000)
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 1_000, md5: "cccc")
        await Self.rescan(model, root: root, fresh: [fresh])
        Self.expectCurated(fresh, "carried")
        #expect(fresh.notes.contains("Copied from the earlier file test_tape02.mov (SHA-256 abababababab…) at this path"),
                "\(fresh.notes)")
        #expect(model.records.first { $0.id == old.id }?.removal?.reason == .replacedAtPath)
    }

    @Test("RED before #478 ruling: two whole-file digests that differ are a different file even at the same size and fingerprint")
    func differentDigestIsADifferentFile() async throws {
        let root = try Self.makeRoot("digest"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape03.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000, md5: "aaaa"))
        old.contentFixity = Self.fixity(String(repeating: "ab", count: 32), 1_000)
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 1_000, md5: "aaaa")
        fresh.contentFixity = Self.fixity(String(repeating: "cd", count: 32), 1_000)
        await Self.rescan(model, root: root, fresh: [fresh])
        #expect(fresh.notes.contains("Copied from the earlier file test_tape03.mov"), "\(fresh.notes)")
        #expect(model.records.first { $0.id == old.id }?.removal?.reason == .replacedAtPath)
    }

    @Test("control: the same bytes, or no evidence either way, carry as before — no note, no history row",
          arguments: [("aaaa", "aaaa"), ("", "aaaa"), ("aaaa", ""), ("", "")])
    func sameOrUnknownCarriesQuietly(_ md5s: (String, String)) async throws {
        let root = try Self.makeRoot("same"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape04.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000, md5: md5s.0))
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 1_000, md5: md5s.1)
        let outcome = await Self.rescan(model, root: root, fresh: [fresh])
        Self.expectCurated(fresh, "the same file carries")
        #expect(!fresh.notes.contains("Copied from the earlier file"))
        #expect(!model.records.contains { $0.id == old.id }, "the same file: the old id is replaced, as before")
        #expect(outcome.carriedWithNote == 0)
        #expect(!(await Self.console(model)).contains("had changed; your dates and notes"))
    }

    @Test("control: a different file over a record with nothing curated is replaced as before — no note, no history")
    func nothingCuratedNothingKept() async throws {
        let root = try Self.makeRoot("plain"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape05.mov").path
        let old = Self.record(path: path, size: 1_000)
        old.sceneCaptions = [SceneCaption(timestamp: 1, text: "a lake")]   // a machine product, not Rick's
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 2_000)
        await Self.rescan(model, root: root, fresh: [fresh])
        #expect(!fresh.notes.contains("Copied from the earlier file"))
        #expect(!model.records.contains { $0.id == old.id })
    }

    @Test("RED before #478 ruling: the partial (aborted) merge carries with the note and keeps the history row too")
    func partialMerge() async throws {
        let root = try Self.makeRoot("partial"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape06.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000))
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 3_000)
        let outcome = await Self.rescan(model, root: root, fresh: [fresh], complete: false)
        Self.expectCurated(fresh, "carried on the partial merge")
        #expect(fresh.notes.contains("Copied from the earlier file test_tape06.mov"))
        #expect(model.records.first { $0.id == old.id }?.removal?.reason == .replacedAtPath)
        #expect(outcome.carriedWithNote == 1)
    }

    @Test("RED before #478 ruling: the next rescan of the SAME new file keeps its note and the history row beside it, and writes no second note")
    func secondRescanKeepsTheNoteAndTheHistory() async throws {
        let root = try Self.makeRoot("twice"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape07.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000))
        let model = Self.model(root: root, records: [old])
        let fresh = Self.record(path: path, size: 2_000)
        await Self.rescan(model, root: root, fresh: [fresh])
        model.snapshotPreservedFieldsForRescan(of: model.scanTargets[0])
        let again = Self.record(path: path, size: 2_000)
        await Self.rescan(model, root: root, fresh: [again])
        Self.expectCurated(again, "the same file again")
        #expect(again.notes.components(separatedBy: "Copied from the earlier file").count == 2,
                "the note travels once: \(again.notes)")
        #expect(model.records.first { $0.id == old.id }?.removal?.reason == .replacedAtPath, "history kept beside its successor")
        #expect(model.records.filter { $0.fullPath == path && $0.removal == nil }.map(\.id) == [again.id])
    }

    // MARK: Truth — the archived twin (GH #528)

    @Test("RED before #478 ruling: a new file that IS archived content keeps the date it was filed under; the rest carries; the archived copy is untouched")
    func archivedTwinKeepsItsFiledDate() async throws {
        let root = try Self.makeRoot("twin"); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "e5", count: 32)
        let archived = Self.record(path: "/Volumes/test_FamilyArchive/30_Video/1990s/test_twin.mov", size: 4_096, md5: "md5-twin")
        archived.contentFixity = Self.fixity(digest, 4_096)
        archived.lifecycleStage = .archived
        archived.userDate = "1990"
        archived.userDateConfidence = UserDateConfidence.known.rawValue
        let path = root.appendingPathComponent("test_tape08.mov").path
        let old = Self.curated(Self.record(path: path, size: 1_000, md5: "aaaa"))
        let model = Self.model(root: root, records: [archived, old])
        let fresh = Self.record(path: path, size: 4_096, md5: "md5-twin")
        fresh.contentFixity = Self.fixity(digest, 4_096)
        await Self.rescan(model, root: root, fresh: [fresh])

        #expect(fresh.userDate == "1990", "the twin shows the archived copy's filed date, not the old file's: \(fresh.userDate ?? "nil")")
        #expect(fresh.userPlace == "Cape Cod" && fresh.tags == ["Reunion"], "the rest of Rick's values carry")
        #expect(fresh.notes.contains("Copied from the earlier file test_tape08.mov"))
        #expect(archived.userDate == "1990" && archived.removal == nil, "the archived copy is untouched")
        #expect(model.records.first { $0.id == old.id }?.userDate == "1984-07", "the history row keeps its own date")
    }

    // MARK: Isolation — the live re-read

    @Test("RED before #478 ruling: a date typed on the OLD record while the scan ran is the one carried (with the note), and the history row has it")
    func dateTypedDuringTheScan() async throws {
        let root = try Self.makeRoot("live"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_tape09.mov").path
        let old = Self.record(path: path, size: 1_000)
        let model = Self.model(root: root, records: [old])   // nothing curated at scan start
        old.userDate = "1991"
        old.userDateConfidence = UserDateConfidence.estimated.rawValue
        let fresh = Self.record(path: path, size: 5_000)
        await Self.rescan(model, root: root, fresh: [fresh])
        #expect(fresh.userDate == "1991")
        #expect(fresh.notes.contains("Copied from the earlier file test_tape09.mov"))
        #expect(model.records.first { $0.id == old.id }?.userDate == "1991")
    }

    // MARK: Scale

    @Test("SCALE: 100k re-seen paths, every other one a different file — inside the budget, ONE summary line",
          .timeLimit(.minutes(1)))
    func scale() async throws {
        let root = try Self.makeRoot("scale"); defer { try? FileManager.default.removeItem(at: root) }
        var old: [VideoRecord] = [], fresh: [VideoRecord] = []
        old.reserveCapacity(100_000); fresh.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let p = root.path + "/d\(i % 100)/test_clip\(i).mov"
            let o = Self.record(path: p, size: 1_000)
            o.userDate = "1984"
            o.tags = ["Reunion"]
            old.append(o)
            fresh.append(Self.record(path: p, size: i % 2 == 0 ? 1_000 : 2_000))
        }
        let model = VideoScanModel()
        model.scanTargets = [CatalogScanTarget(searchPath: root.path)]
        model.records = old
        let clock = ContinuousClock()
        var outcome = ScanMergeOutcome()
        let elapsed = await clock.measure {
            model.snapshotPreservedFieldsForRescan(of: model.scanTargets[0])
            outcome = await Self.rescan(model, root: root, fresh: fresh)
        }
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(8)), "took \(elapsed)")
        #expect(outcome.carriedWithNote == 50_000)
        #expect(fresh.filter { $0.userDate == "1984" }.count == 100_000, "every record carries")
        #expect(fresh.filter { $0.notes.contains("Copied from the earlier file") }.count == 50_000)
        #expect(model.records.filter { $0.removal?.reason == .replacedAtPath }.count == 50_000)
        let said = await Self.console(model)
        #expect(said.contains("50000 files at known paths had changed; your dates and notes were copied onto them with a note — review them"))
        #expect(said.components(separatedBy: "had changed; your dates and notes").count == 2, "one line")
    }

    // MARK: Writer (catalog.sqlite)

    /// A rescan's fresh instance of `source`: new id, no whole-file hash, no
    /// curated values, `bytes` different.
    static func reEncodedProbe(_ scene: CutoverScene, of source: VideoRecord, growBy bytes: Int64 = 4_096) throws -> VideoRecord {
        let fresh = try scene.probe(of: source)
        fresh.sizeBytes = source.sizeBytes + bytes
        fresh.userDate = nil; fresh.userDateConfidence = nil
        fresh.userPlace = nil; fresh.userPlaceConfidence = nil
        fresh.mediaDisposition = .unreviewed; fresh.tags = []; fresh.userNotes = ""
        fresh.confirmedByUserPeople = []; fresh.rejectedPeople = []; fresh.starRating = 0
        fresh.familyMusic = nil; fresh.backupAttestations = []
        return fresh
    }

    static func relaunch(_ scene: CutoverScene) async throws -> VideoScanModel {
        if let committer = scene.model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    @Test("RED before #478 ruling (WRITER): the merge inside an edit's debounce window and during a write hold — the relaunch shows the carried values and the note on the new row, and the old row kept as history with its values")
    func storedThroughTheCommitter() async throws {
        let scene = try CutoverScene.make("rescan_carry_478"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let model = scene.model
        let old = try scene.record(.healthy)
        Self.curated(old)
        #expect(model.saveCatalogNow())
        let path = old.fullPath
        let root = (path as NSString).deletingLastPathComponent
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)

        // Inside the debounce window of an edit on the OLD record …
        old.userNotes = "typed just before the merge"
        model.saveCatalogDebounced()
        // … and during a job's write hold: the merge runs held, commits after.
        #expect(await model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let fresh = try Self.reEncodedProbe(scene, of: old)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        await model.commitScanResults(root: root, volName: "Fixture", targetRecords: [fresh], scanWasComplete: false)
        model.catalogStore.releaseWriteHold()
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene)
        let newRow = try #require(back.records.first { $0.id == fresh.id }, "the new row is stored")
        #expect(newRow.userDate == "1984-07" && newRow.userPlace == "Cape Cod" && newRow.tags == ["Reunion"])
        #expect(newRow.userNotes == "typed just before the merge", "the edit made in the debounce window is the one carried")
        #expect(newRow.notes.contains("Copied from the earlier file \(old.filename)"), "the note is stored: \(newRow.notes)")
        let history = try #require(back.records.first { $0.id == old.id }, "the old row was purged")
        #expect(history.removal?.reason == .replacedAtPath)
        #expect(history.userDate == "1984-07" && history.userNotes == "typed just before the merge")
        if let c = back.catalogCutover.committer { await c.repository.close() }
    }
}
