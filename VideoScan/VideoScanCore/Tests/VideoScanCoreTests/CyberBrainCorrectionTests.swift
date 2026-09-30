import Foundation
import Testing
@testable import VideoScanCore

// "Correct a family note" (2026-09-29): take back, reword, or move one note
// about one person — nothing is ever erased; the old text stays in the
// file, hidden unless Rick asks to see corrections.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   Logic     — each operation; every refusal leaves the file byte-identical
//   Loader    — accepts every corrected archive, rejects malformed ones,
//               a file without corrections re-encodes byte-identically
//   Hallie    — the index never sees removed / moved-away / superseded
//               text and does see the moved / edited result
//   Scale     — 10k-item archive, one durable correction within a budget
//   Isolation — temp roots only; poisoned roots (missing file, corrupt
//               file, symlinked root) are refused and left alone
//   Sensor    — every write in CyberBrainCorrections.swift goes through the
//               writer's one durable `save`

// MARK: - Fixtures

private let written = ISO8601DateFormatter().date(from: "2026-09-20T15:00:00Z")!
private let fixDay = ISO8601DateFormatter().date(from: "2026-09-29T16:00:00Z")!

private let noteSource = CyberBrainSource(
    id: "source.family-tree-notes-rick.2026-09-20", type: .profileNote,
    title: "Family Tree notes (Rick)", attribution: "Rick")
private let graveSource = CyberBrainSource(
    id: "source.research.findagrave-com-memorial-1", type: .officialRecord,
    title: "Find a Grave memorial", attribution: "confirmed by Rick",
    notes: "URL: https://www.findagrave.com/memorial/1")

/// The 9/29 incident in miniature: a passage about the SON (b. 1835) saved
/// on the FATHER (b. 1805). Both are linked to their tree records.
private func lattaArchive() -> CyberBrainArchive {
    CyberBrainArchive(
        archiveID: "family", displayName: "Family CyberBrain",
        people: [
            CyberBrainPerson(
                id: "person.john-c-latta.i10", gedcomPersonID: "@I10@",
                canonicalName: "John C. Latta",
                notes: [
                    CyberBrainItem(
                        id: "research.john-c-latta.2026-09-20", kind: .note,
                        text: "John Robert Latta served in the 49th Pennsylvania Infantry.",
                        subjectPersonIDs: ["person.john-c-latta.i10"],
                        sourceIDs: [graveSource.id], confidence: .confirmed, privacy: .family,
                        createdAt: written, updatedAt: written),
                    CyberBrainItem(
                        id: "note.john-c-latta.2026-09-20", kind: .note,
                        text: "Farmed in Huntingdon County.",
                        subjectPersonIDs: ["person.john-c-latta.i10"],
                        sourceIDs: [noteSource.id], confidence: .confirmed, privacy: .family,
                        createdAt: written, updatedAt: written),
                ]),
            CyberBrainPerson(
                id: "person.mary-latta", canonicalName: "Mary Latta",
                notes: [
                    CyberBrainItem(
                        id: "caption.mary-latta.2026-09-20", kind: .note,
                        text: "Mary and John at the farm.",
                        subjectPersonIDs: ["person.mary-latta", "person.john-c-latta.i10"],
                        sourceIDs: [noteSource.id], confidence: .probable, privacy: .family,
                        createdAt: written, updatedAt: written),
                ]),
        ],
        sources: [noteSource, graveSource])
}

private let incidentID = "research.john-c-latta.2026-09-20"
private let fatherID = "person.john-c-latta.i10"
private let son = CyberBrainWriter.NoteCorrection.MoveTarget(
    name: "John Robert Latta", gedcomPersonID: "@I11@")

private func request(_ op: CyberBrainWriter.NoteCorrection.Operation,
                     item: String = incidentID, viewed: String = fatherID,
                     by: String = "Rick") -> CyberBrainWriter.NoteCorrection {
    .init(itemID: item, viewedPersonID: viewed, operation: op, by: by, date: fixDay)
}

private func tempRoot(_ tag: String = "corr") throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CyberBrainCorrection-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func install(_ archive: CyberBrainArchive, at root: URL) throws -> Data {
    let data = try CyberBrainWriter.encode(archive)
    try data.write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
    return data
}

private func fileBytes(_ root: URL) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
}

private func allItems(_ archive: CyberBrainArchive) -> [String: CyberBrainItem] {
    Dictionary(uniqueKeysWithValues: archive.people.flatMap(\.items).map { ($0.id, $0) })
}

// MARK: - Logic

@Suite("CyberBrain corrections — operations")
struct CyberBrainCorrectionOperationTests {

    @Test func removeRetractsTheItemAndKeepsItsText() throws {
        let receipt = try CyberBrainWriter.correcting(
            request(.remove(reason: .wrongPerson, detail: nil)), in: lattaArchive())
        let item = try #require(allItems(receipt.archive)[incidentID])
        #expect(item.status == .retracted)
        #expect(item.text == "John Robert Latta served in the 49th Pennsylvania Infantry.", "never erased")
        #expect(item.updatedAt == fixDay)
        #expect(item.createdAt == written)
        #expect(item.correction == CyberBrainCorrection(action: .removed, reason: .wrongPerson, at: fixDay, by: "Rick"))
        #expect(receipt.action == .removed && receipt.newItemID == nil)
        // Nothing else moved.
        #expect(receipt.archive.people.flatMap(\.items).count == lattaArchive().people.flatMap(\.items).count)
        #expect(receipt.archive.sources == lattaArchive().sources)
    }

    @Test func removeWithOtherNeedsAReasonAndKeepsItShort() throws {
        #expect(throws: CyberBrainWriter.CorrectionRefusal.detailRequired) {
            try CyberBrainWriter.correcting(request(.remove(reason: .other, detail: "  ")), in: lattaArchive())
        }
        let long = String(repeating: "x", count: CyberBrainCorrection.maximumDetailLength + 1)
        #expect(throws: CyberBrainWriter.CorrectionRefusal.detailTooLong(281)) {
            try CyberBrainWriter.correcting(request(.remove(reason: .other, detail: long)), in: lattaArchive())
        }
        let ok = try CyberBrainWriter.correcting(
            request(.remove(reason: .other, detail: " Find a Grave had the wrong son ")), in: lattaArchive())
        #expect(allItems(ok.archive)[incidentID]?.correction?.detail == "Find a Grave had the wrong son")
    }

    @Test func editSupersedesWithANewItemCarryingEverythingButTheWords() throws {
        let receipt = try CyberBrainWriter.correcting(
            request(.edit(newText: "Farmed in Huntingdon County, Pennsylvania."),
                    item: "note.john-c-latta.2026-09-20"),
            in: lattaArchive())
        let items = allItems(receipt.archive)
        let old = try #require(items["note.john-c-latta.2026-09-20"])
        let newID = try #require(receipt.newItemID)
        let new = try #require(items[newID])
        #expect(old.status == .superseded)
        #expect(old.text == "Farmed in Huntingdon County.")
        #expect(old.correction?.action == .edited)
        #expect(new.status == .active)
        #expect(new.supersedesItemID == old.id)
        #expect(new.text == "Farmed in Huntingdon County, Pennsylvania.")
        #expect(new.subjectPersonIDs == old.subjectPersonIDs)
        #expect(new.kind == old.kind && new.sourceIDs == old.sourceIDs)
        #expect(new.confidence == old.confidence && new.privacy == old.privacy)
        #expect(new.id != old.id && new.id.hasPrefix("note."))
        // Lives beside the old one, on the same person.
        let father = try #require(receipt.archive.people.first { $0.id == fatherID })
        #expect(father.notes.map(\.id).contains(new.id))
    }

    @Test func editRefusesEmptyOrUnchangedWords() {
        let id = "note.john-c-latta.2026-09-20"
        #expect(throws: CyberBrainWriter.CorrectionRefusal.emptyText) {
            try CyberBrainWriter.correcting(request(.edit(newText: " \n"), item: id), in: lattaArchive())
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.unchangedText) {
            try CyberBrainWriter.correcting(request(.edit(newText: " Farmed in Huntingdon County. "), item: id), in: lattaArchive())
        }
    }

    @Test func moveCreatesTheLinkedSonAndKeepsTheOriginalDay() throws {
        let receipt = try CyberBrainWriter.correcting(request(.move(to: son)), in: lattaArchive())
        #expect(receipt.createdTargetPerson)
        let sonPerson = try #require(receipt.archive.people.first { $0.gedcomPersonID == "@I11@" })
        #expect(sonPerson.canonicalName == "John Robert Latta")
        #expect(receipt.toPersonID == sonPerson.id)
        let moved = try #require(sonPerson.notes.first)
        #expect(moved.id == receipt.newItemID)
        #expect(moved.text == "John Robert Latta served in the 49th Pennsylvania Infantry.")
        #expect(moved.sourceIDs == [graveSource.id])
        #expect(moved.confidence == .confirmed && moved.privacy == .family && moved.kind == .note)
        #expect(moved.createdAt == written, "keeps the day it was first written")
        #expect(moved.updatedAt == fixDay)
        #expect(moved.subjectPersonIDs == [sonPerson.id])
        #expect(moved.id.hasPrefix("research."))
        let old = try #require(allItems(receipt.archive)[incidentID])
        #expect(old.status == .retracted)
        #expect(old.correction == CyberBrainCorrection(
            action: .moved, reason: .wrongPerson, at: fixDay, by: "Rick",
            movedToPersonID: sonPerson.id, movedToItemID: moved.id))
    }

    @Test func moveUsesTheExistingLinkedPersonAndNeverMergesJrSr() throws {
        // The son already has a record, linked by pointer, under a nickname.
        var archive = lattaArchive()
        archive = CyberBrainArchive(
            archiveID: archive.archiveID, displayName: archive.displayName,
            people: archive.people + [CyberBrainPerson(
                id: "person.bob", gedcomPersonID: "@I11@", canonicalName: "Bob Latta")],
            sources: archive.sources)
        let linked = try CyberBrainWriter.correcting(request(.move(to: son)), in: archive)
        #expect(!linked.createdTargetPerson)
        #expect(linked.toPersonID == "person.bob")
        #expect(linked.archive.people.count == archive.people.count)

        // A same-name person linked to a DIFFERENT record is never reused.
        let twin = CyberBrainArchive(
            archiveID: "family", displayName: "t",
            people: lattaArchive().people + [CyberBrainPerson(
                id: "person.other-john", gedcomPersonID: "@I99@", canonicalName: "John Robert Latta")],
            sources: lattaArchive().sources)
        let fresh = try CyberBrainWriter.correcting(request(.move(to: son)), in: twin)
        #expect(fresh.createdTargetPerson)
        #expect(fresh.toPersonID != "person.other-john")
    }

    @Test func refusalsNameTheReason() {
        let archive = lattaArchive()
        #expect(throws: CyberBrainWriter.CorrectionRefusal.unknownItem("nope")) {
            try CyberBrainWriter.correcting(request(.remove(reason: .duplicate, detail: nil), item: "nope"), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.notAboutViewedPerson(incidentID, "Mary Latta")) {
            try CyberBrainWriter.correcting(request(.remove(reason: .duplicate, detail: nil), viewed: "person.mary-latta"), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.targetMissing) {
            try CyberBrainWriter.correcting(request(.move(to: .init(name: "", gedcomPersonID: "@I11@"))), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.targetMissing) {
            try CyberBrainWriter.correcting(request(.move(to: .init(name: "John Robert Latta", gedcomPersonID: " "))), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.sameTarget("John C. Latta")) {
            try CyberBrainWriter.correcting(request(.move(to: .init(name: "John C. Latta", gedcomPersonID: "@I10@"))), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.sharedNoteCannotMove(2)) {
            try CyberBrainWriter.correcting(request(.move(to: son), item: "caption.mary-latta.2026-09-20"), in: archive)
        }
        #expect(throws: CyberBrainWriter.CorrectionRefusal.noAuthor) {
            try CyberBrainWriter.correcting(request(.remove(reason: .duplicate, detail: nil), by: " "), in: archive)
        }
    }

    @Test func aCorrectedItemCannotBeCorrectedAgain() throws {
        let removed = try CyberBrainWriter.correcting(
            request(.remove(reason: .wrongPerson, detail: nil)), in: lattaArchive()).archive
        for op: CyberBrainWriter.NoteCorrection.Operation in [
            .remove(reason: .duplicate, detail: nil), .edit(newText: "x"), .move(to: son),
        ] {
            #expect(throws: CyberBrainWriter.CorrectionRefusal.itemNotCurrent(incidentID)) {
                try CyberBrainWriter.correcting(request(op), in: removed)
            }
        }
        // An edited item's OLD version is not current either; the new one is.
        let id = "note.john-c-latta.2026-09-20"
        let edited = try CyberBrainWriter.correcting(request(.edit(newText: "Farmed."), item: id), in: lattaArchive())
        #expect(throws: CyberBrainWriter.CorrectionRefusal.itemNotCurrent(id)) {
            try CyberBrainWriter.correcting(request(.edit(newText: "Again."), item: id), in: edited.archive)
        }
        let editedID = try #require(edited.newItemID)
        let again = try CyberBrainWriter.correcting(
            request(.edit(newText: "Farmed wheat."), item: editedID), in: edited.archive)
        // A chain of two edits still validates (the first version's
        // superseder is itself superseded now).
        try CyberBrainValidator.validate(again.archive)
    }

    @Test func removingASharedCaptionRetractsItForEveryone() throws {
        let receipt = try CyberBrainWriter.correcting(
            request(.remove(reason: .wrongInformation, detail: nil), item: "caption.mary-latta.2026-09-20"),
            in: lattaArchive())
        let index = try CyberBrainIndex(archive: receipt.archive)
        #expect(!index.allActiveItems(for: fatherID).contains { $0.id == "caption.mary-latta.2026-09-20" })
        #expect(index.allActiveItems(for: "person.mary-latta").isEmpty)
    }
}

// MARK: - Durable

@Suite("CyberBrain corrections — durable save")
struct CyberBrainCorrectionDurableTests {

    @Test func everyRefusalLeavesTheFileByteIdentical() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try install(lattaArchive(), at: root)
        let refused: [CyberBrainWriter.NoteCorrection] = [
            request(.remove(reason: .wrongPerson, detail: nil), item: "missing"),
            request(.remove(reason: .wrongPerson, detail: nil), viewed: "person.mary-latta"),
            request(.remove(reason: .other, detail: nil)),
            request(.edit(newText: "")),
            request(.edit(newText: "John Robert Latta served in the 49th Pennsylvania Infantry.")),
            request(.move(to: .init(name: "", gedcomPersonID: ""))),
            request(.move(to: .init(name: "John C. Latta", gedcomPersonID: "@I10@"))),
            request(.move(to: son), item: "caption.mary-latta.2026-09-20"),
            request(.remove(reason: .duplicate, detail: nil), by: ""),
        ]
        for req in refused {
            #expect(throws: CyberBrainWriter.CorrectionRefusal.self) { try CyberBrainWriter.correct(req, rootURL: root) }
            #expect(try fileBytes(root) == before, Comment(rawValue: "\(req.operation)"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path),
                "a refusal never even takes a backup")
    }

    @Test func aSuccessfulCorrectionIsAtomicWithABackupOfTheOldFile() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try install(lattaArchive(), at: root)
        let receipt = try CyberBrainWriter.correct(request(.move(to: son)), rootURL: root)
        let backup = try #require(receipt.backupURL)
        #expect(try Data(contentsOf: backup) == before, "the backup is the file as it was")
        #expect(backup.deletingLastPathComponent().lastPathComponent == "backups")
        let reloaded = try CyberBrainLoader(rootURL: root).load()
        #expect(allItems(reloaded)[incidentID]?.status == .retracted)
        let newID = try #require(receipt.newItemID)
        #expect(allItems(reloaded)[newID]?.status == .active)
        #expect(try CyberBrainWriter.encode(reloaded) == fileBytes(root))
    }
}

// MARK: - Loader

@Suite("CyberBrain corrections — loader")
struct CyberBrainCorrectionLoaderTests {

    /// Real-shaped: a told-me passage, a research note with a URL source,
    /// a service event, pronunciations, an old-style superseded pair. No
    /// correction anywhere — the shape every file on disk has today.
    static let realShapedJSON = """
    {
      "archiveID" : "family",
      "displayName" : "Family CyberBrain",
      "people" : [
        {
          "aliases" : [
            "Dad Breen"
          ],
          "anecdotes" : [

          ],
          "biographyPassages" : [
            {
              "confidence" : "probable",
              "createdAt" : "2026-08-21T15:00:00Z",
              "disputesItemIDs" : [

              ],
              "id" : "told.dad-breen.2026-08-21",
              "kind" : "biography",
              "privacy" : "family",
              "sourceIDs" : [
                "source.told-by-rick.2026-08-21"
              ],
              "status" : "superseded",
              "subjectPersonIDs" : [
                "person.dad-breen"
              ],
              "text" : "He repaired typewriters.",
              "updatedAt" : "2026-08-22T15:00:00Z"
            },
            {
              "confidence" : "probable",
              "createdAt" : "2026-08-22T15:00:00Z",
              "disputesItemIDs" : [

              ],
              "id" : "told.dad-breen.2026-08-22",
              "kind" : "biography",
              "privacy" : "family",
              "sourceIDs" : [
                "source.told-by-rick.2026-08-21"
              ],
              "status" : "active",
              "subjectPersonIDs" : [
                "person.dad-breen"
              ],
              "supersedesItemID" : "told.dad-breen.2026-08-21",
              "text" : "He repaired typewriters for forty years.",
              "updatedAt" : "2026-08-22T15:00:00Z"
            }
          ],
          "canonicalName" : "Richard Hardin Breen Sr",
          "gedcomPersonID" : "@I1@",
          "id" : "person.dad-breen",
          "lifeEvents" : [
            {
              "confidence" : "confirmed",
              "createdAt" : "2026-09-23T15:00:00Z",
              "disputesItemIDs" : [

              ],
              "id" : "event.dad-breen.service",
              "kind" : "event",
              "privacy" : "family",
              "service" : {
                "basis" : "confirmedByFamily",
                "combat" : "unknown",
                "conflict" : "worldWarII",
                "engagements" : [

                ],
                "force" : "United States Marine Corps"
              },
              "sourceIDs" : [
                "source.told-by-rick.2026-08-21"
              ],
              "status" : "active",
              "subjectPersonIDs" : [
                "person.dad-breen"
              ],
              "text" : "Dad was a Marine.",
              "updatedAt" : "2026-09-23T15:00:00Z"
            }
          ],
          "notes" : [
            {
              "confidence" : "confirmed",
              "createdAt" : "2026-08-29T15:00:00Z",
              "disputesItemIDs" : [

              ],
              "id" : "research.dad-breen.2026-08-29",
              "kind" : "note",
              "privacy" : "family",
              "sourceIDs" : [
                "source.research.https-example-org-a"
              ],
              "status" : "active",
              "subjectPersonIDs" : [
                "person.dad-breen"
              ],
              "text" : "Obituary, Berkshire Eagle.",
              "updatedAt" : "2026-08-29T15:00:00Z"
            }
          ],
          "pronunciations" : {
            "Breen" : "BREEN"
          },
          "terminology" : [

          ]
        }
      ],
      "schemaVersion" : 1,
      "sources" : [
        {
          "attribution" : "Rick",
          "id" : "source.told-by-rick.2026-08-21",
          "notes" : "Recorded in conversation; not yet verified against documents.",
          "sourceDate" : {
            "displayText" : "2026-08-21",
            "precision" : "day",
            "qualifier" : "exact",
            "value" : "2026-08-21"
          },
          "title" : "Told to Hallie by Rick, 2026-08-21",
          "type" : "familyWitness"
        },
        {
          "attribution" : "confirmed by Rick",
          "id" : "source.research.https-example-org-a",
          "locator" : "People/dad/research/cache/abc.json",
          "notes" : "URL: https://example.org/a · Found by Research Person, retrieved 2026-08-29; confirmed by Rick on 2026-08-29.",
          "title" : "Berkshire Eagle",
          "type" : "officialRecord"
        }
      ]
    }
    """

    @Test func aFileWithoutCorrectionsReEncodesByteIdentically() throws {
        let root = try tempRoot("bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(Self.realShapedJSON.utf8)
        // The fixture is exactly what the writer emits (sanity: otherwise
        // the byte test below would prove nothing).
        let decoded = try CyberBrainLoaderTestAccess.decode(bytes)
        #expect(try CyberBrainWriter.encode(decoded) == bytes)
        try bytes.write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
        let loaded = try CyberBrainLoader(rootURL: root).load()
        #expect(loaded.people.flatMap(\.items).allSatisfy { $0.correction == nil })
        #expect(try CyberBrainWriter.encode(loaded) == bytes)
        #expect(!String(decoding: try CyberBrainWriter.encode(loaded), as: UTF8.self).contains("\"correction\""))
    }

    @Test func everyCorrectedArchiveLoadsBack() throws {
        let ops: [CyberBrainWriter.NoteCorrection] = [
            request(.remove(reason: .wrongPerson, detail: nil)),
            request(.remove(reason: .other, detail: "the wrong John")),
            request(.edit(newText: "Farmed wheat."), item: "note.john-c-latta.2026-09-20"),
            request(.move(to: son)),
        ]
        for op in ops {
            let root = try tempRoot("load")
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try install(lattaArchive(), at: root)
            let receipt = try CyberBrainWriter.correct(op, rootURL: root)
            let loaded = try CyberBrainLoader(rootURL: root).load()
            #expect(allItems(loaded)[op.itemID]?.correction?.action == receipt.action)
            #expect(try CyberBrainWriter.encode(loaded) == fileBytes(root), "stable after reload")
        }
    }

    /// Hand-build a malformed item on top of the fixture and expect the
    /// validator to refuse it.
    private func rejects(_ mutate: (CyberBrainItem) -> CyberBrainItem, _ why: Comment) {
        let archive = lattaArchive()
        let people = archive.people.map { p in
            CyberBrainPerson(
                id: p.id, gedcomPersonID: p.gedcomPersonID, canonicalName: p.canonicalName,
                notes: p.notes.map { $0.id == incidentID ? mutate($0) : $0 })
        }
        let bad = CyberBrainArchive(archiveID: "family", displayName: "d", people: people, sources: archive.sources)
        #expect(throws: CyberBrainError.self, why) { try CyberBrainValidator.validate(bad) }
    }

    @Test func malformedCorrectionsAreRejected() {
        let removed = CyberBrainCorrection(action: .removed, reason: .wrongPerson, at: fixDay, by: "Rick")
        rejects({ $0.withCorrection(status: .active, updatedAt: fixDay, correction: removed) },
                "a correction on an active item")
        rejects({ $0.withCorrection(status: .superseded, updatedAt: fixDay, correction: removed) },
                "removed but superseded")
        rejects({ $0.withCorrection(status: .superseded, updatedAt: fixDay,
                                    correction: .init(action: .edited, reason: .wrongInformation, at: fixDay, by: "Rick")) },
                "edited with nothing superseding it")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .moved, reason: .wrongPerson, at: fixDay, by: "Rick",
                                                      movedToPersonID: "person.nobody", movedToItemID: "note.john-c-latta.2026-09-20")) },
                "moved to a person who does not exist")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .moved, reason: .wrongPerson, at: fixDay, by: "Rick",
                                                      movedToPersonID: "person.mary-latta", movedToItemID: "nothing")) },
                "moved to an item that does not exist")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .moved, reason: .wrongPerson, at: fixDay, by: "Rick",
                                                      movedToPersonID: "person.mary-latta", movedToItemID: "note.john-c-latta.2026-09-20")) },
                "moved copy is not about the new person")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .moved, reason: .duplicate, at: fixDay, by: "Rick",
                                                      movedToPersonID: "person.mary-latta", movedToItemID: "caption.mary-latta.2026-09-20")) },
                "a move for a reason other than wrong person")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .removed, reason: .wrongPerson, at: fixDay, by: "Rick",
                                                      movedToPersonID: "person.mary-latta")) },
                "a removal that claims a destination")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .removed, reason: .other,
                                                      detail: String(repeating: "y", count: 281), at: fixDay, by: "Rick")) },
                "detail over 280 characters")
        rejects({ $0.withCorrection(status: .retracted, updatedAt: fixDay,
                                    correction: .init(action: .removed, reason: .other, at: fixDay, by: "  ")) },
                "nobody made it")
    }

    @Test func anUnknownKeyInsideACorrectionFailsClosed() throws {
        let root = try tempRoot("unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try install(lattaArchive(), at: root)
        _ = try CyberBrainWriter.correct(request(.remove(reason: .wrongPerson, detail: nil)), rootURL: root)
        let text = try String(decoding: fileBytes(root), as: UTF8.self)
        let poisoned = text.replacingOccurrences(of: "\"action\" : \"removed\"",
                                                 with: "\"action\" : \"removed\", \"undo\" : true")
        #expect(poisoned != text)
        try Data(poisoned.utf8).write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
        #expect(throws: CyberBrainError.self) { try CyberBrainLoader(rootURL: root).load() }
    }
}

/// Decode without the loader's filesystem checks (fixture sanity only).
enum CyberBrainLoaderTestAccess {
    static func decode(_ data: Data) throws -> CyberBrainArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CyberBrainArchive.self, from: data)
    }
}

// MARK: - What Hallie sees

@Suite("CyberBrain corrections — Hallie's view")
struct CyberBrainCorrectionHallieTests {

    @Test func removedMovedAndSupersededTextIsInvisibleAndTheResultIsVisible() throws {
        var archive = lattaArchive()
        let moved = try CyberBrainWriter.correcting(request(.move(to: son)), in: archive)
        archive = moved.archive
        let edited = try CyberBrainWriter.correcting(
            request(.edit(newText: "Farmed wheat in Huntingdon County."), item: "note.john-c-latta.2026-09-20"),
            in: archive)
        archive = edited.archive
        let removed = try CyberBrainWriter.correcting(
            request(.remove(reason: .duplicate, detail: nil), item: "caption.mary-latta.2026-09-20"), in: archive)
        archive = removed.archive

        let index = try CyberBrainIndex(archive: archive)
        let sonID = try #require(moved.toPersonID)
        let fatherText = index.evidence(for: fatherID, privacyCeiling: .private, limit: 50).map(\.text)
        #expect(fatherText == ["Farmed wheat in Huntingdon County."])
        #expect(index.evidence(for: sonID, privacyCeiling: .private).map(\.text)
                == ["John Robert Latta served in the 49th Pennsylvania Infantry."])
        #expect(index.evidence(for: "person.mary-latta", privacyCeiling: .private).isEmpty)
        #expect(index.familyAccounts(forPersonID: fatherID, privacyCeiling: .private).map(\.text)
                == ["Farmed wheat in Huntingdon County."])
        // Hallie's resolver finds the son by name, with only his note.
        guard case .resolved(let found) = index.resolve("John Robert Latta") else {
            Issue.record("the son is not resolvable"); return
        }
        #expect(found.id == sonID)
        // The owner's corrections view sees all three old versions.
        let hidden = Set(index.hiddenItems(for: fatherID).map(\.id))
        #expect(hidden == [incidentID, "note.john-c-latta.2026-09-20", "caption.mary-latta.2026-09-20"])
    }
}

// MARK: - Scale

@Suite("CyberBrain corrections — scale")
struct CyberBrainCorrectionScaleTests {

    /// 10k items across 1,000 people: one durable correction (load, apply,
    /// validate, probe-load, backup, rename). Budget is a Debug ceiling —
    /// generous enough for a loaded battery machine, tight enough that an
    /// O(items²) slip (1e8 comparisons) fails it.
    static let budget: Duration = .seconds(5)

    @Test func oneCorrectionInATenThousandItemArchive() throws {
        let root = try tempRoot("scale")
        defer { try? FileManager.default.removeItem(at: root) }
        var people: [CyberBrainPerson] = []
        for p in 0..<1_000 {
            let id = "person.p\(p)"
            let items = (0..<10).map { i in
                CyberBrainItem(id: "note.p\(p).\(i)", kind: .note, text: "Fact \(i) about person \(p).",
                               subjectPersonIDs: [id], sourceIDs: [noteSource.id],
                               confidence: .confirmed, privacy: .family,
                               createdAt: written, updatedAt: written)
            }
            people.append(CyberBrainPerson(id: id, gedcomPersonID: "@I\(p)@",
                                           canonicalName: "Person \(p) Scale", notes: items))
        }
        let archive = CyberBrainArchive(archiveID: "family", displayName: "scale",
                                        people: people, sources: [noteSource])
        #expect(archive.people.flatMap(\.items).count == 10_000)
        _ = try install(archive, at: root)

        let start = ContinuousClock.now
        let receipt = try CyberBrainWriter.correct(
            .init(itemID: "note.p999.9", viewedPersonID: "person.p999",
                  operation: .move(to: .init(name: "Person 3 Scale", gedcomPersonID: "@I3@")),
                  by: "Rick", date: fixDay),
            rootURL: root)
        let elapsed = ContinuousClock.now - start
        #expect(receipt.toPersonID == "person.p3")
        #expect(elapsed < Self.budget, "one correction over 10k items took \(elapsed)")
        print("[cyberbrain-correction scale] 10k items, one move: \(elapsed)")
    }
}

// MARK: - Isolation (poisoned roots)

@Suite("CyberBrain corrections — isolation")
struct CyberBrainCorrectionIsolationTests {

    @Test func aMissingArchiveIsRefusedWithoutCreatingAnything() throws {
        let parent = try tempRoot("missing")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("cyberbrain", isDirectory: true)
        #expect(throws: CyberBrainWriter.CorrectionRefusal.noArchive) {
            try CyberBrainWriter.correct(request(.remove(reason: .wrongPerson, detail: nil)), rootURL: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path), "a refused correction creates no directory")
    }

    @Test func aCorruptArchiveIsNeverReplaced() throws {
        let root = try tempRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let poison = Data("{ \"schemaVersion\": 1, \"people\": [".utf8)
        try poison.write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
        #expect(throws: (any Error).self) {
            try CyberBrainWriter.correct(request(.remove(reason: .wrongPerson, detail: nil)), rootURL: root)
        }
        #expect(try fileBytes(root) == poison)
    }

    @Test func aSymlinkedRootIsRefused() throws {
        let real = try tempRoot("real")
        let parent = try tempRoot("link")
        defer {
            try? FileManager.default.removeItem(at: real)
            try? FileManager.default.removeItem(at: parent)
        }
        let before = try install(lattaArchive(), at: real)
        let link = parent.appendingPathComponent("cyberbrain")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) {
            try CyberBrainWriter.correct(request(.remove(reason: .wrongPerson, detail: nil)), rootURL: link)
        }
        #expect(try fileBytes(real) == before)
    }
}

// MARK: - Sensor

@Suite("CyberBrain corrections — write-path sensor")
struct CyberBrainCorrectionWritePathSensorTests {

    /// Every byte the correction code writes goes through the writer's one
    /// durable `save` (temp → probe-load → backup → atomic rename). A second
    /// writer added here later — a `Data.write`, a FileManager copy/move,
    /// a raw `open(... O_WRONLY ...)` — would bypass the backup and the
    /// probe load, so it fails this sensor.
    @Test func correctionsWriteOnlyThroughTheDurableSave() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/CyberBrainCorrections.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        for forbidden in [".write(", "createFile", "copyItem", "moveItem", "removeItem",
                          "replaceItem", "O_WRONLY", "rename(", "FileHandle", "createDirectory"] {
            #expect(!code.contains(forbidden), Comment(rawValue: "CyberBrainCorrections.swift must not call \(forbidden)"))
        }
        // Exactly one save call, and it is the durable one.
        #expect(code.components(separatedBy: "try save(").count - 1 == 1)
        #expect(code.contains("try save(receipt.archive, root: root, hadExisting: true)"))
    }
}
