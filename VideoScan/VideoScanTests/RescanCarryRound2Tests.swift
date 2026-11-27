import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #478, Codex round 2 (2026-11-27): the carry's immutable receipt,
// and the history it promised to keep
//
// Each test is Codex's concrete input, played through catalog.sqlite with a
// save and a relaunch (the writer dimension), red before this round's fix:
//   F1  Undo cleared a value ANOTHER copy of the new file's content holds on
//       its own (the store keeps one value per content, so the clear reached
//       /q.mov too)
//   F2  Undo compared against the mutable history row, so a later edit that
//       happened to equal it was cleared; it now compares against the carry's
//       own receipt (what it set, the exact values)
//   F3  a refused history marker still let the replacement through and purged
//       the earlier row; now the earlier row stays as it was and the
//       replacement waits for the next scan
//   F4  a later complete scan purged the history row when its successor's
//       file was gone (path-based removal); history rows are not removed by path
//   F5  a Missing earlier record bypassed the carry: no note, no history row,
//       and the new file inherited "Missing"
//   F6  a filename with a newline split the Carry line: no Inspector section,
//       no Undo
// Plus: the receipt's grammar survives any filename and any value (logic), and
// a different file at a Missing path never inherits "Missing" even when
// nothing was curated (isolation).
//
// (scale: RescanCarryWithNoteTests.scale covers the carry with receipts at
//  100k; media: not applicable — no file is decoded.)

@MainActor
@Suite("GH #478 round 2 — the carry's receipt, Undo against it, and the history kept", .serialized)
struct RescanCarryRound2Tests {

    typealias C = RescanCarryWithNoteTests

    /// Close `model`'s committer and open the sandbox's catalog again.
    static func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    static func close(_ model: VideoScanModel) async {
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    /// The rescan of `old`'s folder finding `fresh` at its path (the partial
    /// merge: no disk evidence needed).
    static func rescan(_ model: VideoScanModel, at old: VideoRecord, fresh: [VideoRecord], complete: Bool = false) async {
        let root = (old.fullPath as NSString).deletingLastPathComponent
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        await model.commitScanResults(root: root, volName: "Fixture", targetRecords: fresh, scanWasComplete: complete)
    }

    static func isUndone(_ o: RescanCarryWithNote.UndoOutcome) -> Bool {
        if case .undone = o { return true }
        return false
    }

    // MARK: The receipt's grammar

    @Test("LOGIC: the receipt survives any name and any value — newlines, CR, NEL, U+2028, quotes and the marker text itself — on ONE line, and parses back exactly")
    func receiptSurvivesAnyNameAndValue() throws {
        let nasty = "Tape\n01\r\u{85}\u{2028}\"x\" Carry record: {\"earlier\":\"\(UUID().uuidString)\",\"set\":{}}.mov"
        let receipt = RescanCarryNote.Receipt(earlier: UUID(), set: [
            "userNotes": ["line one\nline two\u{2028}three \u{85} Carry record: {}"],
            "tags": ["a\tb", "c"],
            "date": [nil, "known"],
        ])
        let (line, sentence) = RescanCarryNote.line(earlierFilename: nasty, digest: String(repeating: "ab", count: 32),
                                                    stamp: RescanCarryNote.Stamp(Date()), receipt: receipt)
        #expect(!line.unicodeScalars.contains(where: RescanCarryNote.breaksALine), "one line: \(line.debugDescription)")
        #expect(line.split(whereSeparator: \.isNewline).count == 1)
        let active = try #require(RescanCarryNote.active(in: "ffprobe: x\n" + line + "\nPromote 2026-01-01T00:00:00Z: y"))
        #expect(active.receipt == receipt, "the receipt is the carry's, not the one inside the name")
        #expect(active.sentence == sentence)
        #expect(active.lineIndex == 1)
        #expect(sentence.contains("Tape\\n01\\r\\u{85}\\u{2028}"), "the name says what it was: \(sentence)")
        #expect(MachineNote.rescanMerged(kept: line, fresh: "") == line, "history: a rescan keeps it verbatim")
    }

    @Test("LOGIC: a Carry line without a receipt that decodes, or one already undone, offers no undo")
    func noReceiptNoUndo() {
        let stamp = RescanCarryNote.Stamp(Date())
        #expect(RescanCarryNote.active(in: "Carry \(stamp.iso): Copied from the earlier file a.mov at this path.") == nil)
        #expect(RescanCarryNote.active(in: "Carry \(stamp.iso): Copied from the earlier file a.mov. Carry record: {broken") == nil)
        #expect(RescanCarryNote.active(in: "Carry \(stamp.iso): Undone — the values copied from the earlier file a.mov were taken off.") == nil)
    }

    @Test("LOGIC: the carry never claims or overwrites a value the new file's content already holds — that copy's value is shown, and the receipt leaves it out")
    func contentHeldValueIsNeverClaimed() async throws {
        let root = try C.makeRoot("contentheld"); defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "c3", count: 32)
        let q = C.record(path: root.appendingPathComponent("test_q.mov").path, size: 2_000, md5: "q")
        q.contentFixity = C.fixity(digest, 2_000)
        q.starRating = 1
        q.userDate = "1990"
        let path = root.appendingPathComponent("test_p.mov").path
        let old = C.curated(C.record(path: path, size: 1_000, md5: "aaaa"))
        let model = C.model(root: root, records: [q, old])
        let fresh = C.record(path: path, size: 2_000, md5: "q")
        fresh.contentFixity = C.fixity(digest, 2_000)          // already hashed: it IS q's content
        await C.rescan(model, root: root, fresh: [fresh])
        #expect(fresh.starRating == 1 && fresh.userDate == "1990", "the content's own values, never the earlier file's")
        #expect(q.starRating == 1 && q.userDate == "1990", "the other copy is untouched")
        let receipt = try #require(RescanCarryNote.active(in: fresh.notes)?.receipt)
        #expect(receipt.set["stars"] == nil && receipt.set["date"] == nil, "not the carry's: \(receipt.set)")
        #expect(receipt.set["place"] == ["Cape Cod", "estimated"] as [String?], "the rest is the carry's, with the exact value")
        guard case .undone(let report) = RescanCarryWithNote(model: model).undoCarry(on: fresh) else {
            Issue.record("undo refused"); return
        }
        #expect(report == .init(reset: [.place, .disposition, .tags, .userNotes, .people]), "\(report)")
        #expect(fresh.starRating == 1 && fresh.userDate == "1990", "Undo never touches what the carry did not set")
    }

    // MARK: Round 3 (Codex P2): the loader sorts set-valued groups

    @Test("RED before round 3 (Codex P2): tags [\"Reunion\",\"Gold\"] and people [Tim, Donna] carried, hashed, saved, relaunched (the loader sorts them) — Undo takes them off and only then says undone, through a second relaunch")
    func setValuedGroupsCompareOrderInsensitively() async throws {
        let scene = try CutoverScene.make("carry_r3_order"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.healthy)
        C.curated(a)
        #expect(model.saveCatalogNow())
        // Typed in this order just before the scan (not yet read back sorted by
        // a commit): the carry's receipt records them as Rick typed them.
        a.tags = ["Reunion", "Gold"]
        a.confirmedByUserPeople = [ConfirmedTag(name: "Tim", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                                   ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let fresh = try C.reEncodedProbe(scene, of: a)
        await Self.rescan(model, at: a, fresh: [fresh])
        #expect(model.saveCatalogNow())
        fresh.contentFixity = ContentFixity(digest: String(repeating: "f", count: 64), byteCount: fresh.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 77, size: fresh.sizeBytes, mtimeNs: 5),
                                            computedAt: Date())
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let b = try #require(back.records.first { $0.id == fresh.id })
        try #require(Set(b.tags) == ["Reunion", "Gold"], "precondition: the tags are stored")
        try #require(RescanCarryNote.active(in: b.notes)?.receipt.set["tags"] == ["Reunion", "Gold"] as [String?],
                     "precondition: the receipt holds them in the typed order, the loader in another")
        let outcome = RescanCarryWithNote(model: back).undoCarry(on: b)
        guard case .undone(let report) = outcome else { Issue.record("refused: \(outcome)"); return }
        #expect(report.reset.contains(.tags) && report.reset.contains(.people), "\(report)")
        #expect(report.accounted == RescanCarryUndoTests.all7.count, "every receipt group accounted for: \(report)")
        #expect(b.tags.isEmpty, "the carried tags are taken off whatever order the loader gave them: \(b.tags)")
        #expect(b.confirmedByUserPeople.isEmpty, "the carried people too: \(b.confirmedByUserPeople.map(\.name))")
        #expect(RescanCarryNote.active(in: b.notes) == nil, "the line is undone only once the values are off")
        #expect(back.saveCatalogNow())
        let again = try await Self.relaunch(scene, from: back)
        let b2 = try #require(again.records.first { $0.id == fresh.id })
        #expect(b2.tags.isEmpty && b2.confirmedByUserPeople.isEmpty, "relaunch: still off")
        #expect(b2.notes.contains("Undone"))
        await Self.close(again)
    }

    @Test("LOGIC (Codex r3): a receipt naming a group this build does not know is refused whole — nothing cleared, the line not marked undone")
    func unknownReceiptGroupRefusesUndo() async throws {
        let s = try await RescanCarryUndoTests.carried("unknowngroup"); defer { try? FileManager.default.removeItem(at: s.root) }
        let active = try #require(RescanCarryNote.active(in: s.fresh.notes))
        var set = active.receipt.set
        set["moodBoard"] = ["x"]                                     // written by a newer build
        let (line, _) = RescanCarryNote.line(earlierFilename: s.old.filename, digest: nil, stamp: RescanCarryNote.Stamp(Date()),
                                             receipt: RescanCarryNote.Receipt(earlier: s.old.id, set: set))
        s.fresh.notes = line
        guard case .refused(let words) = RescanCarryWithNote(model: s.model).undoCarry(on: s.fresh) else {
            Issue.record("an unaccountable receipt must refuse"); return
        }
        #expect(words.contains("moodBoard"), "\(words)")
        C.expectCurated(s.fresh, "nothing taken off")
        #expect(s.fresh.notes == line, "the line is not marked undone")
    }

    // MARK: F1

    @Test("RED before round 2 (Codex F1): Undo on /p.mov never clears the date /q.mov holds on its own once /p.mov is hashed to /q.mov's content — through save and relaunch")
    func undoKeepsAnotherCopysIndependentValue() async throws {
        let scene = try CutoverScene.make("carry_r2_f1"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.healthy)              // content A at /p.mov
        C.curated(a)                                     // 1984-07, known (and the rest)
        let q = try scene.record(.stalePrint)            // content B at /q.mov holds the same date, independently
        q.userDate = "1984-07"
        q.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(model.saveCatalogNow())

        let fresh = try C.reEncodedProbe(scene, of: a)   // B's bytes now at /p.mov
        await Self.rescan(model, at: a, fresh: [fresh])
        #expect(model.saveCatalogNow())
        fresh.sizeBytes = q.sizeBytes                    // its whole-file hash lands: it IS content B
        fresh.contentFixity = q.contentFixity
        try #require(CatalogCommit.digest(of: fresh) == CatalogCommit.digest(of: q))
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let p = try #require(back.records.first { $0.id == fresh.id })
        try #require(RescanCarryNote.active(in: p.notes) != nil, "precondition: the carry is still undoable after relaunch")
        #expect(Self.isUndone(RescanCarryWithNote(model: back).undoCarry(on: p)))
        #expect(back.records.first { $0.id == q.id }?.userDate == "1984-07", "in memory: /q.mov keeps its own date")
        #expect(back.saveCatalogNow())

        let again = try await Self.relaunch(scene, from: back)
        #expect(again.records.first { $0.id == q.id }?.userDate == "1984-07", "relaunch: /q.mov keeps its own date")
        #expect(again.records.first { $0.id == a.id }?.userDate == "1984-07", "the history row keeps A's date")
        await Self.close(again)
    }

    // MARK: F2

    @Test("RED before round 2 (Codex F2): carried 3 stars, Rick rates B 1 star, another copy of A is rated 1 star (the history row follows) — Undo keeps Rick's 1 star, through relaunch")
    func undoComparesAgainstTheReceiptNotTheHistoryRow() async throws {
        let scene = try CutoverScene.make("carry_r2_f2"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.curatedConflictA)      // content A, two copies
        let otherCopyOfA = try scene.record(.curatedConflictB)
        C.curated(a)
        otherCopyOfA.starRating = 3
        otherCopyOfA.userDate = a.userDate
        otherCopyOfA.userDateConfidence = a.userDateConfidence
        #expect(model.saveCatalogNow())

        let fresh = try C.reEncodedProbe(scene, of: a)   // B at A's path
        await Self.rescan(model, at: a, fresh: [fresh])
        #expect(model.saveCatalogNow())
        try #require(fresh.starRating == 3, "precondition: 3 stars carried")
        fresh.starRating = 1                             // Rick rates B
        #expect(model.saveCatalogNow())
        otherCopyOfA.starRating = 1                      // … and another copy of A
        #expect(model.saveCatalogNow())
        if a.starRating != 1 { a.starRating = 1 }        // the history row follows its content (as the store shows it)
        try #require(a.starRating == 1, "precondition: the history row now equals Rick's later rating")

        #expect(Self.isUndone(RescanCarryWithNote(model: model).undoCarry(on: fresh)))
        #expect(fresh.starRating == 1, "Rick's later rating is not the carry's value: kept")
        #expect(model.saveCatalogNow())
        let back = try await Self.relaunch(scene, from: model)
        #expect(back.records.first { $0.id == fresh.id }?.starRating == 1, "relaunch: Rick's 1 star")
        await Self.close(back)
    }

    // MARK: F3

    @Test("RED before round 2 (Codex F3): a restored record whose marker commit has not run, a write hold, then different bytes at its path — the earlier record stays as it was and the replacement waits; nothing purged, no orphaned note")
    func refusedHistoryMarkerDefersTheReplacement() async throws {
        let scene = try CutoverScene.make("carry_r2_f3"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.healthy)
        C.curated(a)
        VideoScanModel.stampRemoval(a, .removedFromCatalog(at: Date(), reason: .userRemoved))
        #expect(model.saveCatalogNow(), "the removal is stored")
        #expect(model.clearRemoval(a) == nil, "Restore: its commit is asked for …")
        await scene.hold()                                // … but the hold lands first
        let fresh = try C.reEncodedProbe(scene, of: a)
        await Self.rescan(model, at: a, fresh: [fresh])

        #expect(model.records.contains { $0 === a }, "the earlier record is retained")
        #expect(a.removal == nil, "… live, as Rick restored it")
        C.expectCurated(a, "… with its values")
        #expect(!model.records.contains { $0.id == fresh.id }, "the replacement is deferred to the next scan")
        #expect(model.records.filter { $0.fullPath == a.fullPath && $0.removal == nil }.count == 1, "one live row at the path")
        scene.release()
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let kept = try #require(back.records.first { $0.id == a.id }, "the earlier row was purged")
        #expect(kept.removal == nil)
        C.expectCurated(kept, "relaunch: the earlier row keeps Rick's values")
        #expect(!back.records.contains { $0.id == fresh.id }, "no replacement row without its history")
        await Self.close(back)
    }

    // MARK: F4

    @Test("RED before round 2 (Codex F4): carry, Undo, the new file removed outside the app, then a complete scan of the folder — the replacedAtPath history row and its values survive the scan and a relaunch")
    func completeScanKeepsTheHistoryRow() async throws {
        let scene = try CutoverScene.make("carry_r2_f4"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let folder = scene.sandbox.files                       // a real folder: the complete merge stats it
        let a = try scene.freshStored(of: .healthy, path: folder.appendingPathComponent("p.mov").path, digestFill: "a")
        C.curated(a)
        let otherURL = folder.appendingPathComponent("other.mov")
        try Data("unchanged".utf8).write(to: otherURL)
        let other = try scene.freshStored(of: .healthy, path: otherURL.path, digestFill: "b")
        model.records.append(contentsOf: [a, other])
        #expect(model.saveCatalogNow())

        let fresh = try C.reEncodedProbe(scene, of: a)          // B at /p.mov (never on disk: "removed externally")
        await Self.rescan(model, at: a, fresh: [fresh])
        #expect(model.saveCatalogNow())
        #expect(Self.isUndone(RescanCarryWithNote(model: model).undoCarry(on: fresh)))
        #expect(model.saveCatalogNow())
        try #require(a.removal?.reason == .replacedAtPath)

        let otherAgain = try scene.probe(of: other)             // the complete scan sees only other.mov
        await Self.rescan(model, at: other, fresh: [otherAgain], complete: true)
        #expect(model.records.contains { $0 === a }, "in memory: the history row stays")
        #expect(!model.records.contains { $0.id == fresh.id }, "B's file is gone: its row leaves, as before")
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let history = try #require(back.records.first { $0.id == a.id }, "the history row was purged")
        #expect(history.removal?.reason == .replacedAtPath)
        C.expectCurated(history, "relaunch: the history row keeps Rick's values")
        await Self.close(back)
    }

    // MARK: F5

    @Test("RED before round 2 (Codex F5): A at the path already Missing, an unrelated larger file appears — A is kept as history, B shows the provenance note and is NOT Missing, through relaunch")
    func missingEarlierRecordTakesTheCarryPath() async throws {
        let scene = try CutoverScene.make("carry_r2_f5"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.record(.healthy)
        C.curated(a)
        #expect(model.saveCatalogNow())
        #expect(VideoScanModel.stampRemoval(a, .missing(noticedAt: Date(), lastSeen: nil, reason: .missingOnDisk),
                                            kind: .diskFact) == nil)
        #expect(model.saveCatalogNow())
        let fresh = try C.reEncodedProbe(scene, of: a)           // 8 KB where A was 4 KB
        await Self.rescan(model, at: a, fresh: [fresh])

        #expect(fresh.removal == nil, "the new file is on disk: never inherits A's Missing")
        #expect(RescanCarryNote.active(in: fresh.notes)?.earlierID == a.id, "provenance on B: \(fresh.notes)")
        #expect(a.removal?.reason == .replacedAtPath, "A kept as history")
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let b = try #require(back.records.first { $0.id == fresh.id })
        #expect(b.removal == nil)
        #expect(RescanCarryNote.active(in: b.notes)?.earlierID == a.id)
        let history = try #require(back.records.first { $0.id == a.id }, "A was purged")
        #expect(history.removal?.reason == .replacedAtPath)
        C.expectCurated(history, "A keeps Rick's values")
        await Self.close(back)
    }

    @Test("ISOLATION: a different file at a Missing path never inherits Missing, even when nothing there was curated")
    func missingNothingCuratedDropsTheMarker() async throws {
        let root = try C.makeRoot("missingplain"); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("test_gone.mov").path
        let old = C.record(path: path, size: 1_000)
        old.removal = .missing(noticedAt: Date(), lastSeen: nil, reason: .missingOnDisk)
        let model = C.model(root: root, records: [old])
        let fresh = C.record(path: path, size: 2_000)
        await C.rescan(model, root: root, fresh: [fresh])
        #expect(fresh.removal == nil, "a different, present file is not Missing")
        #expect(!fresh.notes.contains("Copied from the earlier file"), "nothing curated: no note")
    }

    // MARK: F6

    @Test("RED before round 2 (Codex F6): filename \"Tape\\n01.mov\" — the Carry line stays one line, the Inspector finds it and Undo works, through relaunch")
    func newlineInTheFilename() async throws {
        let scene = try CutoverScene.make("carry_r2_f6"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let a = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/Clips/Tape\n01.mov")
        C.curated(a)
        model.records.append(a)
        #expect(model.saveCatalogNow())
        let fresh = try C.reEncodedProbe(scene, of: a)
        await Self.rescan(model, at: a, fresh: [fresh])
        #expect(RescanCarryNote.active(in: fresh.notes)?.earlierID == a.id, "\(fresh.notes)")
        #expect(fresh.notes.split(separator: "\n").count == 1, "one line: \(fresh.notes)")
        #expect(model.saveCatalogNow())

        let back = try await Self.relaunch(scene, from: model)
        let b = try #require(back.records.first { $0.id == fresh.id })
        #expect(RescanCarryNote.active(in: b.notes)?.earlierID == a.id)
        #expect(Self.isUndone(RescanCarryWithNote(model: back).undoCarry(on: b)))
        RescanCarryUndoTests.expectBlank(b)
        await Self.close(back)
    }
}
