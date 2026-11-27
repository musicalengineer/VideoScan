import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #478: "Undo Carry" — the carry is ONE undoable action
//
// The carry's stored marker is its Carry line in the new record's machine
// notes (no schema change). Undo takes off every curated group that still
// holds the value copied from the earlier record (back to the new record's
// prior value: blank, as the probe made it), leaves a group Rick changed since
// as he set it, never writes a date the seam fixes, rewrites the Carry line as
// undone, and leaves the earlier record (history) untouched.
//
// Dimensions:
//   logic      undo restores the prior values; a later edit survives; a second
//              undo and a missing earlier record are refused with words
//   truth      the archived twin's filed date is never written by undo; the
//              note's grammar is machine text that survives a rescan
//   writer     catalog.sqlite: refused across a viewer flip, then taken inside
//              a debounce window and after a write hold; relaunch shows the
//              undone values, the undone note and the untouched history row
//   (scale: undo is one record's notes — O(lines); the carry's scale test is
//    RescanCarryWithNoteTests.scale)

@MainActor
@Suite("GH #478 — Undo Carry puts back the new record's own values", .serialized)
struct RescanCarryUndoTests {

    typealias C = RescanCarryWithNoteTests

    /// One carry: the old curated record, the new file's record carrying.
    static func carried(_ label: String) async throws -> (model: VideoScanModel, old: VideoRecord, fresh: VideoRecord, root: URL) {
        let root = try C.makeRoot(label)
        let path = root.appendingPathComponent("test_\(label).mov").path
        let old = C.curated(C.record(path: path, size: 1_000, md5: "aaaa"))
        let model = C.model(root: root, records: [old])
        let fresh = C.record(path: path, size: 2_000, md5: "bbbb")
        await C.rescan(model, root: root, fresh: [fresh])
        try #require(RescanCarryNote.active(in: fresh.notes)?.earlierID == old.id, "precondition: carried with a note")
        return (model, old, fresh, root)
    }

    static func expectBlank(_ r: VideoRecord, except: Set<String> = []) {
        if !except.contains("date") { #expect(r.userDate == nil && r.userDateConfidence == nil) }
        #expect(r.userPlace == nil && r.userPlaceConfidence == nil)
        #expect(r.mediaDisposition == .unreviewed)
        #expect(r.tags.isEmpty)
        #expect(r.userNotes.isEmpty)
        #expect(r.confirmedByUserPeople.isEmpty && r.rejectedPeople.isEmpty)
        if !except.contains("stars") { #expect(r.starRating == 0) }
    }

    @Test("undo puts the new record's prior (blank) values back, marks the note undone, and leaves the history row as it was")
    func undoRestoresPriorValues() async throws {
        let s = try await Self.carried("undo"); defer { try? FileManager.default.removeItem(at: s.root) }
        let outcome = RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh)
        #expect(outcome == .undone(reset: 7, keptYours: 0, keptShared: 0, dateFixed: false), "\(outcome)")
        Self.expectBlank(s.fresh)
        #expect(RescanCarryNote.active(in: s.fresh.notes) == nil, "the Inspector stops offering the undo")
        #expect(s.fresh.notes.contains("Undone — the values copied from the earlier file test_undo.mov were taken off this record"),
                "\(s.fresh.notes)")
        #expect(s.fresh.notes.components(separatedBy: "\n").count == 1, "the Carry line is rewritten in place, not doubled")
        #expect(s.old.removal?.reason == .replacedAtPath)
        C.expectCurated(s.old, "the earlier record keeps its values")
        let said = await C.console(s.model)
        #expect(said.contains("Undo Carry: test_undo.mov — 7 put back to blank, 0 you changed since left as you set them"), "\(said)")
    }

    @Test("a value Rick changed after the carry stays as he set it; the rest is taken off")
    func laterEditSurvives() async throws {
        let s = try await Self.carried("edited"); defer { try? FileManager.default.removeItem(at: s.root) }
        s.fresh.starRating = 1
        let outcome = RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh)
        #expect(outcome == .undone(reset: 6, keptYours: 1, keptShared: 0, dateFixed: false))
        #expect(s.fresh.starRating == 1, "Rick's later edit")
        Self.expectBlank(s.fresh, except: ["stars"])
    }

    @Test("a second undo and an undo whose earlier record is gone are refused, and touch nothing")
    func refusals() async throws {
        let s = try await Self.carried("refuse"); defer { try? FileManager.default.removeItem(at: s.root) }
        // The earlier record is not in the catalog: refuse, nothing touched.
        s.model.records.removeAll { $0 === s.old }
        let notesBefore = s.fresh.notes
        guard case .refused(let words) = RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh) else {
            Issue.record("undo without the earlier record must refuse"); return
        }
        #expect(words.contains("is not in the catalog"))
        C.expectCurated(s.fresh, "nothing taken off")
        #expect(s.fresh.notes == notesBefore)
        // Back in: undo, then a second undo is refused.
        s.model.records.append(s.old)
        guard case .undone = RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh) else {
            Issue.record("with the earlier record back, the undo is taken"); return
        }
        #expect(RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh) == .refused("test_refuse.mov has no carry to undo"))
    }

    @Test("TRUTH: on a copy of archived content, undo never writes the date it was filed under")
    func archivedTwinDateUntouchedByUndo() async throws {
        let root = try C.makeRoot("undotwin"); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "e7", count: 32)
        let archived = C.record(path: "/Volumes/test_FamilyArchive/30_Video/1990s/test_undotwin.mov", size: 4_096, md5: "m")
        archived.contentFixity = C.fixity(digest, 4_096)
        archived.lifecycleStage = .archived
        archived.userDate = "1990"
        archived.userDateConfidence = UserDateConfidence.known.rawValue
        let path = root.appendingPathComponent("test_undotwin_new.mov").path
        let old = C.curated(C.record(path: path, size: 1_000))
        let model = C.model(root: root, records: [archived, old])
        let fresh = C.record(path: path, size: 4_096, md5: "m")
        fresh.contentFixity = C.fixity(digest, 4_096)
        await C.rescan(model, root: root, fresh: [fresh])
        try #require(fresh.userDate == "1990")
        let outcome = RescanCarryWithNote(model: model).undoCarry(on: fresh)
        #expect(outcome == .undone(reset: 6, keptYours: 0, keptShared: 0, dateFixed: true), "\(outcome)")
        #expect(fresh.userDate == "1990", "the filed date is not undone — archived means fixed")
        #expect(archived.userDate == "1990")
        Self.expectBlank(fresh, except: ["date"])
    }

    @Test("the Carry line is machine text (author scan), never a probe diagnostic, so it survives a rescan; a person's 'Carry …' note is not a carry")
    func noteGrammar() {
        let receipt = RescanCarryNote.Receipt(earlier: UUID(), set: ["stars": ["3"], "date": ["1984-07", nil]])
        let (full, sentence) = RescanCarryNote.line(earlierFilename: "a.mov", digest: nil, stamp: RescanCarryNote.Stamp(Date()),
                                                    receipt: receipt)
        #expect(MachineNote.author(of: full) == MachineNote.Author.scan.rawValue)
        #expect(!MachineNote.isProbeDiagnostic(Substring(full)))
        #expect(MachineNote.rescanMerged(kept: full, fresh: "ffprobe: x").contains(full))
        let active = RescanCarryNote.active(in: "ffprobe: x\n" + full)
        #expect(active == RescanCarryNote.Active(sentence: sentence, receipt: receipt, lineIndex: 1))
        #expect(RescanCarryNote.active(in: "Carry the tapes to Tim's on Sunday") == nil)
        #expect(MachineNote.author(of: "Carry the tapes to Tim's on Sunday") == nil, "a human line stays human")
    }

    // MARK: Writer (catalog.sqlite)

    @Test("WRITER: refused across a viewer flip; taken inside a debounce window after a write hold; the relaunch shows the undone values, the undone note and the untouched history row")
    func undoStoredThroughTheCommitter() async throws {
        let scene = try CutoverScene.make("undo_carry_478"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let model = scene.model
        let old = try scene.record(.healthy)
        C.curated(old)
        #expect(model.saveCatalogNow())
        let root = (old.fullPath as NSString).deletingLastPathComponent
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = try C.reEncodedProbe(scene, of: old)
        model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        await model.commitScanResults(root: root, volName: "Fixture", targetRecords: [fresh], scanWasComplete: false)
        #expect(model.saveCatalogNow())
        try #require(RescanCarryNote.active(in: fresh.notes) != nil)

        // Across a viewer flip: refused, nothing touched.
        model.updateReadOnlyFacts { $0.viewerRole = true }
        #expect(RescanCarryWithNote(model: model).undoCarry(on: fresh) == .refused("this session is read-only"))
        C.expectCurated(fresh, "a viewer's undo touches nothing")
        model.updateReadOnlyFacts { $0.viewerRole = false }

        // During a write hold, then inside the debounce window of another edit.
        #expect(await model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        fresh.starRating = 2                         // Rick's edit after the carry
        model.saveCatalogDebounced()
        #expect(RescanCarryWithNote(model: model).undoCarry(on: fresh) == .undone(reset: 6, keptYours: 1, keptShared: 0, dateFixed: false))
        model.catalogStore.releaseWriteHold()
        #expect(model.saveCatalogNow())

        let back = try await C.relaunch(scene)
        let newRow = try #require(back.records.first { $0.id == fresh.id })
        Self.expectBlank(newRow, except: ["stars"])
        #expect(newRow.starRating == 2, "Rick's later edit is stored")
        #expect(RescanCarryNote.active(in: newRow.notes) == nil)
        #expect(newRow.notes.contains("Undone — the values copied from the earlier file"))
        let history = try #require(back.records.first { $0.id == old.id })
        #expect(history.removal?.reason == .replacedAtPath)
        C.expectCurated(history, "the history row keeps its values after relaunch")
        if let c = back.catalogCutover.committer { await c.repository.close() }
    }
}
