import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// "Correct a family note" in the Family Tree (2026-09-29): take back,
// reword, or move one note about one person — nothing is ever erased; the
// old text stays in the file, hidden unless Rick asks to see corrections.
//
// App-level dimensions (the core rules live in VideoScanCore's
// CyberBrainCorrectionTests):
//   Logic     — the draft remembers who it is about; remove / edit / move
//               through the model, with START / OUTCOME log lines
//   Refusals  — viewer mode, unknown item, not current, not about the
//               person being viewed, target missing: file byte-identical
//   Isolation — temp CyberBrain root only; a stale row (poisoned state:
//               the file changed under the pane) is refused
//   Sensor    — addNote never reads selectedID; every correction write
//               goes through CyberBrainWriter.correct

// MARK: - Fixtures

/// John C. Latta (b. 1805) and his son John Robert Latta (b. 1835) — the
/// 9/29 incident — plus an unrelated Mary.
private let lattaGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I10@ INDI
1 NAME John C. /Latta/
1 SEX M
1 BIRT
2 DATE 1805
1 DEAT
2 DATE 1880
1 FAMS @F1@
0 @I11@ INDI
1 NAME John Robert /Latta/
1 SEX M
1 BIRT
2 DATE 1835
1 DEAT
2 DATE 1911
1 FAMC @F1@
0 @I12@ INDI
1 NAME Mary /Hudson/
1 SEX F
0 @F1@ FAM
1 HUSB @I10@
1 CHIL @I11@
0 TRLR
"""

private let sep20 = ISO8601DateFormatter().date(from: "2026-09-20T15:00:00Z")!
private let sep29 = ISO8601DateFormatter().date(from: "2026-09-29T16:00:00Z")!
private let passage = "John Robert Latta served in the 49th Pennsylvania Infantry."

private func tempRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FamilyTreeNoteCorrection-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func brainBytes(_ root: URL) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
}

/// Thread-safe line capture for the model's correction log.
private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

@MainActor
private func makeModel(root: URL?) -> FamilyTreeLiveModel {
    let model = FamilyTreeLiveModel(
        originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
        cyberBrainRootURL: root, noteAuthor: "Rick", pronunciationFallback: { .shipped })
    model.install(graph: GedcomFamilyGraph(gedcomText: lattaGedcom))
    model.loadCyberBrainNow()
    return model
}

// MARK: - Draft owner

@Suite("Family tree note correction — draft owner")
@MainActor
struct FamilyTreeNoteDraftOwnerTests {

    /// The 9/29 incident: typing starts on the son, the selection moves to
    /// the father, Save is pressed. The note must land on the SON.
    @Test func aDraftIsSavedOnThePersonItWasStartedFor() throws {
        let root = try tempRoot("draft")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel(root: root)
        model.select("@I11@")
        model.noteDraftChanged(isEmpty: false)
        #expect(model.noteDraftOwner?.personID == "@I11@")
        #expect(model.noteDraftOwner?.name == "John Robert Latta")
        #expect(model.noteDraftOwner?.shortName == "John Latta")
        #expect(model.noteDraftOwner?.years == "1835–1911")

        model.select("@I10@")
        #expect(model.noteDraftIsForAnotherPerson, "the pane must warn: this note is about John Robert Latta")
        #expect(model.noteDraftOwner?.personID == "@I11@", "the owner survives the selection change")

        try model.saveNoteDraft(passage, date: sep20)
        #expect(model.noteDraftOwner == nil)
        let archive = try CyberBrainLoader(rootURL: root).load()
        let sonNotes = archive.people.first { $0.gedcomPersonID == "@I11@" }?.notes.map(\.text) ?? []
        let fatherNotes = archive.people.first { $0.gedcomPersonID == "@I10@" }?.notes.map(\.text) ?? []
        #expect(sonNotes == [passage])
        #expect(fatherNotes.isEmpty, "the father never gets the son's note")
    }

    @Test func emptyingTheDraftForgetsTheOwnerAndTheNextDraftTakesTheNewSelection() {
        let model = makeModel(root: nil)
        model.select("@I11@")
        model.noteDraftChanged(isEmpty: false)
        model.select("@I10@")
        model.noteDraftChanged(isEmpty: false)   // more typing: still the son's
        #expect(model.noteDraftOwner?.personID == "@I11@")
        model.noteDraftChanged(isEmpty: true)
        #expect(model.noteDraftOwner == nil)
        #expect(!model.noteDraftIsForAnotherPerson)
        model.noteDraftChanged(isEmpty: false)
        #expect(model.noteDraftOwner?.personID == "@I10@")
        model.discardNoteDraft()
        #expect(model.noteDraftOwner == nil)
    }
}

// MARK: - Corrections through the model

/// The incident, on disk: the son's passage saved on the father (as the
/// old code did), plus one ordinary note on the father.
@MainActor
private func incidentModel(_ tag: String) throws -> (FamilyTreeLiveModel, URL, LineSink) {
    let root = try tempRoot(tag)
    let seeded = makeModel(root: root)
    try seeded.addNote(passage, about: "@I10@", date: sep20)
    try seeded.addNote("Farmed in Huntingdon County.", about: "@I10@", date: sep20)
    let model = makeModel(root: root)
    let sink = LineSink()
    model.correctionLog = { sink.append($0) }
    model.select("@I10@")
    return (model, root, sink)
}

@MainActor
private func row(_ model: FamilyTreeLiveModel, _ text: String) throws -> FamilyTreeNote {
    try #require(model.selectedNotes.first { $0.text == text })
}

private func backupCount(_ root: URL) -> Int {
    (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("backups").path))?.count ?? 0
}

@Suite("Family tree note correction — model")
@MainActor
struct FamilyTreeNoteCorrectionModelTests {

    @Test func moveTakesTheNoteOffTheFatherAndPutsItOnTheSon() throws {
        let (model, root, sink) = try incidentModel("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try row(model, passage)
        #expect(note.treePersonID == "@I10@")

        let receipt = try model.moveNote(note, toTreePerson: "@I11@", date: sep29)
        #expect(model.selectedNotes.map(\.text) == ["Farmed in Huntingdon County."])
        model.select("@I11@")
        #expect(model.selectedNotes.map(\.text) == [passage])

        // The old item is still in the file, retracted, pointing at the copy.
        let archive = try CyberBrainLoader(rootURL: root).load()
        let old = try #require(archive.people.flatMap(\.items).first { $0.id == note.id })
        #expect(old.status == .retracted && old.text == passage)
        #expect(old.correction?.movedToItemID == receipt.newItemID)

        // Audit trail: START then OUTCOME with old → new, file, backup.
        let lines = sink.lines
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("[family-tree-notes] START move item=\(note.id) about John C. Latta (@I10@) → John Robert Latta (@I11@)") == true)
        let outcome = try #require(lines.last)
        #expect(outcome.contains("OUTCOME success move"))
        #expect(outcome.contains("→ \(receipt.toPersonID ?? "?")"))
        #expect(outcome.contains("file \(root.path)"))
        #expect(outcome.contains("backup \(receipt.backupURL?.path ?? "none")"))
        #expect(outcome.contains("to revert"))
    }

    @Test func removeAndEditAndTheCorrectionsView() throws {
        let (model, root, sink) = try incidentModel("remove-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        try model.removeNote(try row(model, passage), reason: .wrongPerson, date: sep29)
        try model.editNote(try row(model, "Farmed in Huntingdon County."),
                           newText: "Farmed wheat in Huntingdon County.", date: sep29)
        #expect(model.selectedNotes.map(\.text) == ["Farmed wheat in Huntingdon County."])
        #expect(model.selectedCorrections.isEmpty, "hidden until asked for")
        #expect(model.selectedNotes.first?.earlierVersions.isEmpty == true)

        model.showsNoteCorrections = true
        let removed = try #require(model.selectedCorrections.first)
        #expect(model.selectedCorrections.count == 1)
        #expect(removed.text == passage && removed.style == .retracted)
        #expect(removed.caption == "Removed \(FamilyTreeNoteCorrectionLine.shortDay(sep29)) — wrong person")
        let earlier = try #require(model.selectedNotes.first?.earlierVersions.first)
        #expect(earlier.text == "Farmed in Huntingdon County." && earlier.style == .earlierWording)
        #expect(earlier.caption == "Earlier wording · changed \(FamilyTreeNoteCorrectionLine.shortDay(sep29))")

        // The switch is per window, not per person: it stays on.
        model.select("@I11@")
        #expect(model.showsNoteCorrections)
        model.showsNoteCorrections = false
        model.select("@I10@")
        #expect(model.selectedCorrections.isEmpty)
        #expect(sink.lines.filter { $0.contains("OUTCOME success") }.count == 2)
    }

    @Test func aMovedNoteShowsWhereItWent() throws {
        let (model, root, _) = try incidentModel("moved-caption")
        defer { try? FileManager.default.removeItem(at: root) }
        try model.moveNote(try row(model, passage), toTreePerson: "@I11@", date: sep29)
        model.showsNoteCorrections = true
        #expect(model.selectedCorrections.map(\.caption)
                == ["Moved \(FamilyTreeNoteCorrectionLine.shortDay(sep29)) to John Robert Latta"])
    }

    @Test func moveCandidatesCarryYearsAndLeaveOutThePersonBeingViewed() {
        let model = makeModel(root: nil)
        let rows = model.moveCandidates(matching: "John Latta", excluding: "@I10@")
        #expect(rows.map(\.id) == ["@I11@"])
        #expect(rows.first?.years == "1835–1911")
        #expect(model.moveCandidates(matching: "  ", excluding: "@I10@").isEmpty)
    }

    /// Every refusal: named, logged, and the file byte-identical.
    @Test func refusalsLeaveTheFileByteIdentical() throws {
        let (model, root, sink) = try incidentModel("refuse")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try brainBytes(root)
        let backupsBefore = backupCount(root)
        let note = try row(model, passage)

        // Viewer mode (an injected center — the process stays master).
        let viewer = ViewerModeCenter()
        viewer.reset(sink: { _ in })
        viewer.install(.viewer(masterHostname: "RicksM4.local"))
        model.viewerCenter = viewer
        #expect(throws: ViewerWriteGuard.RefusedError.self) {
            try model.removeNote(note, reason: .wrongPerson, date: sep29)
        }
        #expect(viewer.refusals.contains { $0.contains("FamilyTreeLiveModel.removeNote") })
        model.viewerCenter = ViewerModeCenter()

        // Unknown item.
        let ghost = FamilyTreeNote(id: "note.ghost", text: note.text, kind: note.kind,
                                   confidence: note.confidence, privacy: note.privacy,
                                   createdAt: note.createdAt, attribution: note.attribution,
                                   cyberBrainPersonID: note.cyberBrainPersonID, treePersonID: note.treePersonID)
        #expect(throws: CyberBrainWriter.CorrectionRefusal.unknownItem("note.ghost")) {
            try model.removeNote(ghost, reason: .duplicate, date: sep29)
        }
        // Not about the person the row claims (row forged onto Mary).
        let forged = FamilyTreeNote(id: note.id, text: note.text, kind: note.kind,
                                    confidence: note.confidence, privacy: note.privacy,
                                    createdAt: note.createdAt, attribution: note.attribution,
                                    cyberBrainPersonID: note.cyberBrainPersonID, treePersonID: "@I12@")
        #expect(throws: CyberBrainWriter.CorrectionRefusal.notAboutViewedPerson(note.id, "Mary Hudson")) {
            try model.removeNote(forged, reason: .duplicate, date: sep29)
        }
        // Target missing / same person.
        #expect(throws: CyberBrainWriter.CorrectionRefusal.targetMissing) {
            try model.moveNote(note, toTreePerson: "@I404@", date: sep29)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.self) {
            try model.moveNote(note, toTreePerson: "@I10@", date: sep29)
        }
        // Empty / unchanged edit.
        #expect(throws: CyberBrainWriter.CorrectionRefusal.emptyText) {
            try model.editNote(note, newText: "  ", date: sep29)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.unchangedText) {
            try model.editNote(note, newText: passage, date: sep29)
        }
        #expect(try brainBytes(root) == before)
        #expect(backupCount(root) == backupsBefore, "a refusal takes no backup")
        let refusedLines = sink.lines.filter { $0.contains("OUTCOME refused") }
        #expect(refusedLines.count == 7)
        #expect(refusedLines.allSatisfy { $0.hasSuffix("file unchanged") })
        #expect(!sink.lines.contains { $0.contains("OUTCOME success") })

        // Not current: already removed.
        try model.removeNote(note, reason: .wrongPerson, date: sep29)
        let after = try brainBytes(root)
        #expect(throws: CyberBrainWriter.CorrectionRefusal.itemNotCurrent(note.id)) {
            try model.removeNote(note, reason: .wrongPerson, date: sep29)
        }
        #expect(try brainBytes(root) == after)
    }
}

// MARK: - Isolation

@Suite("Family tree note correction — isolation")
@MainActor
struct FamilyTreeNoteCorrectionIsolationTests {

    /// Poisoned state: the pane shows a row, then another writer (Hallie,
    /// a second window) corrects the same note on disk. The stale row is
    /// refused and nothing is written.
    @Test func aStaleRowIsRefusedWhenTheFileChangedUnderThePane() throws {
        let (model, root, _) = try incidentModel("stale")
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try row(model, passage)
        let other = makeModel(root: root)
        other.select("@I10@")
        try other.removeNote(try row(other, passage), reason: .duplicate, date: sep29)
        let after = try brainBytes(root)
        #expect(throws: CyberBrainWriter.CorrectionRefusal.itemNotCurrent(note.id)) {
            try model.moveNote(note, toTreePerson: "@I11@", date: sep29)
        }
        #expect(try brainBytes(root) == after)
    }

    /// A test model never reaches the real App Support brain: with no
    /// injected root it refuses, and creates nothing.
    @Test func withoutABrainDirectoryNothingIsReadOrWritten() throws {
        let model = makeModel(root: nil)
        #expect(model.cyberBrainRootURL == nil)
        let note = FamilyTreeNote(id: "note.x", text: "x", kind: .note, confidence: .confirmed,
                                  privacy: .family, createdAt: sep20, attribution: "",
                                  cyberBrainPersonID: "person.x", treePersonID: "@I10@")
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try model.removeNote(note, reason: .wrongPerson, date: sep29)
        }
        #expect(throws: CyberBrainWriter.WriteError.self) {
            try model.addNote("x", about: "@I10@")
        }
    }
}

// MARK: - Sensors

@Suite("Family tree note correction — sensors")
struct FamilyTreeNoteCorrectionSensorTests {

    // By NAME, wherever the file lives (folder reorg 69b616f1).
    private static func source(_ name: String) throws -> String {
        try SourceTree.appSource(named: name)
    }

    /// The body of `func <name>(` up to the next line that closes a
    /// four-space-indented member.
    private static func body(of function: String, in text: String) throws -> String {
        let start = try #require(text.range(of: "func \(function)("))
        let rest = text[start.lowerBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.upperBound])
    }

    /// 9/29: addNote read `selectedID` at save time. It must take the person
    /// as a parameter and never look at the selection.
    @Test func addNoteNeverReadsTheSelection() throws {
        let text = try Self.source("FamilyTreeLiveModel.swift")
        let addNote = try Self.body(of: "addNote", in: text)
        #expect(addNote.contains("about personID: String"))
        #expect(!addNote.contains("selectedID"), "addNote must not read the selection")
        let save = try Self.body(of: "saveNoteDraft", in: text)
        #expect(!save.contains("selectedID"), "the draft saves on its owner")
        let view = try Self.source("FamilyTreeView.swift")
        #expect(!view.contains("model.addNote("), "the view saves through the draft owner only")
    }

    /// Every correction write goes through the core's durable writer: one
    /// call site, inside the one audited path.
    @Test func everyCorrectionGoesThroughTheDurableWriter() throws {
        let text = try Self.source("FamilyTreeLiveModel.swift")
        #expect(text.components(separatedBy: "CyberBrainWriter.correct(").count - 1 == 1)
        let path = try Self.body(of: "correctNote", in: text)
        #expect(path.contains("CyberBrainWriter.correct("))
        #expect(path.contains("ViewerWriteGuard.check("))
        for verb in ["removeNote", "editNote", "moveNote"] {
            #expect(try Self.body(of: verb, in: text).contains("correctNote("), Comment(rawValue: verb))
        }
        let ui = try Self.source("FamilyTreeNoteCorrectionUI.swift")
        #expect(!ui.contains("CyberBrainWriter"), "the sheet never writes the file itself")
    }
}
