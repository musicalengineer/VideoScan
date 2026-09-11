// NotesRepairMigrationTests.swift
// GH #176 — the one-time userNotes repair at the model level: backup
// before mutation, marker beside the catalog, idempotence, and a
// census-shaped run that reproduces the live numbers (2026-09-11:
// 13,879 records, 9,988 with userNotes, 9,979 all-machine, 9 human).
//
// Isolation: every model here gets its own CatalogStore(directory:) in a
// temp dir (test_ prefix) — the shared store is never touched, and the
// marker file lives beside the temp catalog, not in any defaults domain.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Notes repair migration (GH #176)")
struct NotesRepairMigrationTests {

    private struct Sandbox {
        let root: URL
        let catalogDir: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func backups() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: catalogDir.path)) ?? [])
                .filter { $0.hasPrefix("catalog.pre-notes-repair.") && $0.hasSuffix(".json") }
                .sorted()
        }
    }

    private func makeSandbox(_ label: String) throws -> (Sandbox, VideoScanModel) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_notes_repair_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let dir = root.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        return (Sandbox(root: root, catalogDir: dir), model)
    }

    private func record(_ name: String, notes: String = "", userNotes: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/test_vol/\(name)"
        r.directory = "/Volumes/test_vol"
        r.notes = notes
        r.userNotes = userNotes
        return r
    }

    static let ffprobeBlob = "Unsupported codec with id 98314 for input stream 0\n    Last message repeated 2 times\nCould not open codec for input stream 1"
    static let recipeLine = "FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.612 → Donna?"
    static let cleanupLine = "copy at /Volumes/CrucialX9/reel.mov (from /Volumes/OldBook/reel.mov) removed 2026-08-18; identical bytes"

    @Test("mixed / all-machine / human-only / empty: machine lines move back signed, human lines stay, backup first")
    func fixtureCatalog() throws {
        let (sb, model) = try makeSandbox("fixture")
        defer { sb.cleanup() }
        let mixed = record("mixed.mov", notes: "[aac @ 0x1] channel layout guessed",
                           userNotes: "Unsupported codec with id 98314 for input stream 0\nMark’s first birthday, Nov 1984, nice videos of Donna\n\(Self.recipeLine)")
        let allMachine = record("machine.mov", userNotes: Self.ffprobeBlob + "\n" + Self.cleanupLine)
        let humanOnly = record("human.mov", notes: "[mov @ 0x2] moov atom not found", userNotes: "Donna and Libby on Porch")
        let empty = record("empty.mov")
        let alreadySigned = record("signed.mov", notes: "scan: Added as a document", userNotes: "")
        model.records = [mixed, allMachine, humanOnly, empty, alreadySigned]

        let summary = try #require(model.repairMachineTextInUserNotes())
        #expect(summary.recordsCleaned == 2)
        #expect(summary.linesMoved == 2 + 4)
        #expect(summary.humanNotesKept == 2, "mixed keeps its human line; human-only keeps its note")

        #expect(mixed.userNotes == "Mark’s first birthday, Nov 1984, nice videos of Donna")
        #expect(mixed.notes == "[aac @ 0x1] channel layout guessed\nffprobe: Unsupported codec with id 98314 for input stream 0\nrecipe: \(Self.recipeLine)")
        #expect(allMachine.userNotes.isEmpty)
        #expect(allMachine.notes == "ffprobe: Unsupported codec with id 98314 for input stream 0\nffprobe: Last message repeated 2 times\nffprobe: Could not open codec for input stream 1\ncleanup: \(Self.cleanupLine)")
        #expect(humanOnly.userNotes == "Donna and Libby on Porch")
        #expect(humanOnly.notes == "[mov @ 0x2] moov atom not found")
        #expect(empty.notes.isEmpty && empty.userNotes.isEmpty)
        #expect(alreadySigned.notes == "scan: Added as a document")
        // Every line now in `notes` carries an author.
        for r in model.records {
            for line in r.notes.split(separator: "\n") {
                #expect(MachineNote.author(of: line) != nil, "\(r.filename): \(line)")
            }
            #expect(!ArchiveAngelCandidate.humanNoteLines(r.userNotes).contains { MachineNote.isMachineLine($0) })
        }

        // Backup: written BEFORE mutation, so it decodes to the polluted state.
        let backups = sb.backups()
        #expect(backups.count == 1, "\(backups)")
        let backupPath = try #require(summary.backupPath)
        let backupName = try #require(backups.first)
        #expect(backupPath.hasSuffix(backupName))
        let before = try #require(model.catalogStore.loadRecords(fromSnapshotAtPath: backupPath))
        #expect(before.count == 5)
        let beforeMachine = try #require(before.first { $0.filename == "machine.mov" })
        #expect(beforeMachine.userNotes == Self.ffprobeBlob + "\n" + Self.cleanupLine, "backup holds the pre-repair userNotes")
        // Marker beside the catalog.
        #expect(FileManager.default.fileExists(atPath: model.notesRepairMarkerPath))
        #expect((model.notesRepairMarkerPath as NSString).deletingLastPathComponent == sb.catalogDir.path)
    }

    @Test("idempotent: a second run is a no-op and writes no second backup")
    func idempotent() throws {
        let (sb, model) = try makeSandbox("idem")
        defer { sb.cleanup() }
        let r = record("a.mov", userNotes: Self.ffprobeBlob + "\nthis is a test abcdefgh")
        model.records = [r]
        let first = try #require(model.repairMachineTextInUserNotes())
        #expect(first.recordsCleaned == 1)
        let notesAfter = r.notes, userAfter = r.userNotes
        // Marker gate.
        #expect(model.repairMachineTextInUserNotes() == nil)
        #expect(r.notes == notesAfter && r.userNotes == userAfter)
        #expect(sb.backups().count == 1)
        // Even with the marker removed, the rule itself finds nothing to move.
        try FileManager.default.removeItem(atPath: model.notesRepairMarkerPath)
        let again = try #require(model.repairMachineTextInUserNotes())
        #expect(again.recordsCleaned == 0 && again.backupPath == nil)
        #expect(r.notes == notesAfter && r.userNotes == userAfter)
        #expect(sb.backups().count == 1, "a clean catalog never gets a backup")
    }

    @Test("a clean catalog writes the marker and no backup")
    func cleanCatalog() throws {
        let (sb, model) = try makeSandbox("clean")
        defer { sb.cleanup() }
        model.records = [record("a.mov", notes: "ffprobe: x", userNotes: "Donna and Libby on Porch"), record("b.mov")]
        let summary = try #require(model.repairMachineTextInUserNotes())
        #expect(summary == VideoScanModel.NotesRepairSummary(recordsCleaned: 0, linesMoved: 0, humanNotesKept: 1, backupPath: nil))
        #expect(sb.backups().isEmpty)
        #expect(FileManager.default.fileExists(atPath: model.notesRepairMarkerPath))
    }

    @Test("read-only viewer never repairs (the save would be refused and the marker would hide the repair)")
    func readOnlyViewerSkips() throws {
        let (sb, model) = try makeSandbox("ro")
        defer { sb.cleanup() }
        let r = record("a.mov", userNotes: Self.ffprobeBlob)
        model.records = [r]
        model.catalogStore.isReadOnly = true
        #expect(model.repairMachineTextInUserNotes() == nil)
        #expect(r.userNotes == Self.ffprobeBlob)
        #expect(!FileManager.default.fileExists(atPath: model.notesRepairMarkerPath))
    }

    @Test("census 2026-09-11: 13,879 records → 9,979 cleaned, 9 human notes kept, 22,462 lines accounted for")
    func censusShape() throws {
        let (sb, model) = try makeSandbox("census")
        defer { sb.cleanup() }
        // The nine human lines (two records carry two lines, as in the catalog).
        let human: [String] = [
            "Donna and Libby on Porch",
            "this is a test abcdefgh",
            "Mark’s first birthday, Nov 1984, nice videos of Donna. Thanksgiving in Brockton larger Breen family.\nSue, Barry, Ellen, Paul, Beth, Tim, and lots of kids.",
            "Dan’s Kindergarten, Franklin Backyard, Rick Dancing to songs with kids, etc.",
            "Video of Rick and kids at Dad Breen’s house circa 1985",
            "m2v DVD-authoring intermediate format from Dec 2009 me or Avid DVD export encoded JustPatsHouse.mov for a DVD\nThe better news: the true master is intact one folder up — /…/Avid Users/JustPatsHouse.mov,",
            "Mark’s first birthday, Nov 1984, nice videos of Donna. Thanksgiving in Brockton larger Breen family.\nSue, Barry, Ellen, Paul, Beth, Tim, and lots of kids.",
            "Dan’s Kindergarten, Franklin Backyard, Rick Dancing to songs with kids, etc.",
            "Donna and Libby on Porch",
        ]
        // Machine shapes weighted like the census (per-record blobs).
        let machineBlobs: [String] = [
            "Unsupported codec with id 98314 for input stream 0\n    Last message repeated 2 times",
            "Unsupported codec with id 98314 for input stream 0\nUnsupported codec with id 98314 for input stream 1\nCould not open codec for input stream 1",
            "Unsupported codec with id 98315 for input stream 0\nConsider increasing the value of the 'analyzeduration' (0) and 'probesize' (5000000) options",
            "File could not be analyzed — moov atom not found",
            Self.recipeLine,
            "Unsupported codec with id 98314 for input stream 0\n" + Self.recipeLine,
            Self.cleanupLine,
            "File is corrupt or incomplete — missing media index (moov atom not found)",
            "File contains invalid or unreadable data (invalid data found when processing input)",
            "Promote 2026-09-09T17:20:11Z: promoted to Master Archive as BreenFamilyArchive/1990s/x.mov",
        ]
        var recs: [VideoRecord] = []
        var lines = 0
        for i in 0..<9_979 {
            let blob = machineBlobs[i % machineBlobs.count]
            lines += blob.split(separator: "\n").count
            recs.append(record("m\(i).mov", notes: i % 3 == 0 ? "[aac @ 0x\(i)] x" : "", userNotes: blob))
        }
        for (i, h) in human.enumerated() {
            lines += h.split(separator: "\n").count
            recs.append(record("h\(i).mov", userNotes: h))
        }
        for i in 0..<(13_879 - 9_979 - 9) { recs.append(record("e\(i).mov")) }
        #expect(recs.count == 13_879)
        #expect(recs.filter { !$0.userNotes.isEmpty }.count == 9_988)
        model.records = recs

        let t0 = Date()
        let summary = try #require(model.repairMachineTextInUserNotes())
        let elapsed = Date().timeIntervalSince(t0)
        #expect(summary.recordsCleaned == 9_979)
        #expect(summary.humanNotesKept == 9)
        #expect(summary.backupPath != nil)
        #expect(model.records.filter { !$0.userNotes.isEmpty }.count == 9)
        #expect(model.records.allSatisfy { !ArchiveAngelCandidate.humanNoteLines($0.userNotes).contains { MachineNote.isMachineLine($0) } })
        #expect(model.records.allSatisfy { r in r.notes.split(separator: "\n").allSatisfy { MachineNote.author(of: $0) != nil } })
        #expect(summary.linesMoved == lines - human.reduce(0) { $0 + $1.split(separator: "\n").count })
        #expect(elapsed < 10, "repair + backup of 13,879 records took \(elapsed)s")
        #expect(model.repairMachineTextInUserNotes() == nil, "marker set")
    }
}
