// FolderLabelsTests.swift
// Folders as labels (2026-10-19): one file in many folders, folder kinds,
// the folder inspector, the folder log lines.
//   LOGIC     — a content in two folders shows under BOTH; its second row
//               takes an alias id, so every row id is unique; the
//               row ⇄ record selection map; a version of a two-folder
//               recording follows it into both; kind colours; the
//               inspector's counting rules; log lines name every file and
//               the console caps at 20.
//   SCALE     — 100k records, every one in two folders: the join and the
//               compose stay unique and inside the debug budget; the
//               inspector facts for a 100k-file folder inside its budget.
//   SENSOR    — the folder table hands ROW ids to the menus and maps them
//               to records; the inspector facts are computed in a handler,
//               never in a body.
// Media matrix: N/A (no media opened). Synthetic names only.
//
// Suites (filter by SUITE): FolderLabelsLogicTests · FolderLabelsScaleTests · FolderLabelsSensorTests

import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row
private typealias Keys = FootageFolders.SortKeys

private func row(_ name: String, digest: String? = nil, size: Int64 = 1_000, seconds: Double = 60,
                 from: UUID? = nil, kind: String? = nil, volume: String = "LaCie", date: Date = .distantPast) -> Row {
    Row(digest: digest, sizeBytes: size, durationSeconds: seconds, derivedFrom: from, derivationKind: kind, volume: volume,
        keys: Keys(filename: name, volume: volume, duration: seconds, size: size, date: date))
}

@Suite("Folder labels — logic")
struct FolderLabelsLogicTests {

    @Test("a content in two folders shows under both; the second row is an alias; every row id is unique")
    func overlapShowsUnderEveryFolderWithUniqueRowIDs() {
        let a = row("a.mov", digest: "a"), b = row("b.mov", digest: "b")
        let dad = FootageFolders.Event(title: "Dad", contentKeys: [a.contentKey], kind: .person)
        let xmas = FootageFolders.Event(title: "Christmas 1990", contentKeys: [a.contentKey, b.contentKey])
        let index = FootageFolders.index(rows: [a, b], events: [dad, xmas])
        #expect(Set(index.folders(of: a.id)) == [dad.id, xmas.id])
        #expect(index.folders(of: b.id) == [xmas.id])
        #expect(index.folders[dad.id]?.kind == .person)
        let display = FootageFolders.compose(index: index, visible: [a.id, b.id], sort: .byName, open: [dad.id, xmas.id], scope: nil)
        let ids = display.rows.map(\.id)
        #expect(Set(ids).count == ids.count, "Table identity: no duplicate row ids")
        let aRows = display.rows.filter { $0.recordID == a.id }
        #expect(aRows.count == 2, "a.mov under Christmas 1990 and under Dad")
        #expect(aRows.contains { $0.id == a.id }, "its first row keeps the record id")
        #expect(aRows.contains { $0.id != a.id }, "its second row is an alias")
        let level = FootageFolderLevel.level(scope: nil, index: index, display: display)
        #expect(level.children[dad.id]?.compactMap(\.recordID) == [a.id])
        #expect(Set(level.children[xmas.id]?.compactMap(\.recordID) ?? []) == [a.id, b.id])
        #expect(level.recordIDs(expanded: [dad.id, xmas.id]) == [a.id, b.id], "the displayed set is RECORDS")
    }

    @Test("the alias id is deterministic and differs from both inputs")
    func aliasIsStable() {
        let f = UUID(), r = UUID()
        #expect(FootageFolderRowID.alias(folder: f, record: r) == FootageFolderRowID.alias(folder: f, record: r))
        #expect(FootageFolderRowID.alias(folder: f, record: r) != r)
        #expect(FootageFolderRowID.alias(folder: f, record: r) != f)
    }

    @Test("rows ⇄ records: the clicked row stays highlighted; a record set from elsewhere lands on its first row")
    func rowSelectionMapsBothWays() {
        let rec = UUID(), alias = FootageFolderRowID.alias(folder: UUID(), record: rec), folderA = UUID(), folderB = UUID()
        let refs: [UUID: FolderRowRef] = [rec: FolderRowRef(record: rec, folder: folderA),
                                          alias: FolderRowRef(record: rec, folder: folderB)]
        #expect(FolderRowSelection.recordIDs(of: [alias], refs: refs) == [rec])
        #expect(FolderRowSelection.rows(for: [rec], remembered: [alias], refs: refs) == [alias], "Rick's click is kept")
        let other = UUID()
        #expect(FolderRowSelection.rows(for: [other], remembered: [alias], refs: refs) == [other], "a new selection wins")
        #expect(FolderRowSelection.commonFolder(of: [alias], refs: refs) == folderB, "Move / Remove act on THAT folder")
        #expect(FolderRowSelection.commonFolder(of: [rec, alias], refs: refs) == nil, "two folders: no single source")
    }

    @Test("a version of a recording that is in two folders follows it into both; a 2 : 1 family only into the majority")
    func versionFollowsEveryLeadingFolder() {
        let a = row("a.mov", digest: "a")
        let v = row("a.vs.mkv", digest: "v", from: a.id, kind: "transcode")
        let one = FootageFolders.Event(title: "One", contentKeys: [a.contentKey])
        let two = FootageFolders.Event(title: "Two", contentKeys: [a.contentKey])
        let index = FootageFolders.index(rows: [a, v], events: [one, two])
        #expect(Set(index.folders(of: v.id)) == [one.id, two.id])
    }

    @Test("kind colours: event blue, person green, other grey — three different tokens")
    func kindTintsAreDistinct() {
        #expect(FootageFolderWords.folderTint(for: .event) == FootageFolderWords.folderTint)
        #expect(FootageFolderWords.folderTint(for: .person) == FootageFolderWords.personFolderTint)
        #expect(FootageFolderWords.folderTint(for: .other) == FootageFolderWords.otherFolderTint)
        #expect(FootageFolderWords.personFolderTint != FootageFolderWords.folderTint)
        #expect(FolderKind(word: nil) == .event, "an old row reads as an event")
        #expect(FolderKind(word: "album") == .event, "an unknown word never crashes")
        #expect(FolderKind.allCases.map(\.title) == ["Event", "Person", "Other"])
    }

    @Test("an old file's event (no kind key) decodes as an event; the kind round-trips")
    func eventRecordKindDecodes() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let old = #"{"categories":[],"createdAt":"2026-10-19T16:43:30Z","id":"11111111-0000-0000-0000-000000000001","name":"X","state":"confirmed","updatedAt":"2026-10-19T16:43:30Z"}"#
        #expect(try dec.decode(EventRecord.self, from: Data(old.utf8)).kind == .event)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let person = EventRecord(name: "Dad", categories: [], kind: .person)
        #expect(try dec.decode(EventRecord.self, from: enc.encode(person)).kind == .person)
    }

    @Test("inspector facts: files, recordings, duration once per recording, size per file, dates, volumes, online")
    func inspectorFactsCount() {
        let e = EventRecord(name: "Synthetic Beach 1988", categories: [], createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            kind: .event)
        let d1 = Date(timeIntervalSince1970: 600_000_000), d2 = Date(timeIntervalSince1970: 600_100_000)
        let members = [
            FolderInspectorFacts.Member(contentKey: "a", sizeBytes: 100, durationSeconds: 60, date: d1, volume: "LaCie", isOnline: true),
            FolderInspectorFacts.Member(contentKey: "a", sizeBytes: 100, durationSeconds: 60, date: d1, volume: "SanDisk", isOnline: false),
            FolderInspectorFacts.Member(contentKey: "b", sizeBytes: 50, durationSeconds: 30, date: d2, volume: "LaCie", isOnline: true),
            FolderInspectorFacts.Member(contentKey: "c", sizeBytes: 10, durationSeconds: 5, date: nil, volume: "", isOnline: true),
        ]
        let f = FolderInspectorFacts(event: e, title: "Synthetic Beach 1988", members: members)
        #expect(f.files == 4)
        #expect(f.recordings == 3)
        #expect(f.totalSeconds == 95, "a copy adds no running time")
        #expect(f.totalBytes == 260, "every file's bytes")
        #expect(f.earliest == d1)
        #expect(f.latest == d2)
        #expect(f.volumes == ["LaCie", "SanDisk"])
        #expect(f.online == 3)
        #expect(f.onlineWords == "3 of 4 online")
        #expect(f.kind == .event)
        let empty = FolderInspectorFacts(event: e, title: "Empty", members: [])
        #expect(empty.dateRangeWords == "undated")
        #expect(empty.onlineWords == "—")
    }

    @Test("log lines: every filename in the file line, 20 then 'and N more' on the console")
    func logLinesNameFiles() {
        let names = (1...25).map { "clip\($0).mov" }
        let line = EventsFolderLog.created("Synthetic Thanksgiving 1990", kind: .event, files: names)
        #expect(line.full.hasPrefix("Created folder Synthetic Thanksgiving 1990 (event) with 25 files: clip1.mov, clip2.mov"))
        #expect(line.full.contains("clip25.mov"))
        #expect(line.console.contains("clip20.mov"))
        #expect(!line.console.contains("clip21.mov"))
        #expect(line.console.hasSuffix("… and 5 more"))
        let few = EventsFolderLog.moved(from: "Dad", to: "Synthetic Picnic", files: ["a.mov", "b.mov"])
        #expect(few.full == "Moved 2 files from folder Dad to folder Synthetic Picnic: a.mov, b.mov")
        #expect(few.console == few.full)
        #expect(EventsFolderLog.added(to: "Dad", kind: .person, files: ["a.mov"]).full == "Added 1 file to folder Dad (person): a.mov")
        #expect(EventsFolderLog.removed(from: "Dad", files: ["a.mov"]).full == "Removed 1 file from folder Dad: a.mov — the files are untouched")
        #expect(EventsFolderLog.renamed(from: "Dad", to: "Father", kind: .person, files: []).full == "Renamed folder Dad to Father (person), 0 files")
        #expect(EventsFolderLog.kindChanged("Dad", from: .event, to: .person, files: ["a.mov"]).full
                == "Changed folder Dad's kind from event to person, 1 file: a.mov")
        #expect(EventsFolderLog.deleted("Dad", kind: .person, files: ["a.mov"]).full
                == "Deleted folder Dad (person), 1 file: a.mov — the label only; the files are untouched")
    }
}

@Suite("Folder labels — scale")
struct FolderLabelsScaleTests {

    @Test("100k records, each in two folders: unique row ids, inside the debug budget")
    func hundredThousandInTwoFoldersEach() {
        var rows: [Row] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            rows.append(row("clip\(i).mov", digest: String(format: "%040x", i), date: Date(timeIntervalSince1970: Double(i) * 60)))
        }
        // 1,000 event folders of 100 files, and 500 person folders of 200 — every file in exactly two.
        var events: [FootageFolders.Event] = []
        for e in 0..<1_000 { events.append(.init(title: "Event \(e)", contentKeys: rows[(e * 100)..<(e * 100 + 100)].map(\.contentKey))) }
        for p in 0..<500 {
            events.append(.init(title: "Person \(p)", contentKeys: rows[(p * 200)..<(p * 200 + 200)].map(\.contentKey), kind: .person))
        }
        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let index = FootageFolders.index(rows: rows, events: events)
        let display = FootageFolders.compose(index: index, visible: rows.map(\.id), sort: .byName, open: Set(index.folders.keys), scope: nil)
        let measured = ContinuousClock.now - start
        let ids = display.rows.map(\.id)
        #expect(index.folders.count == 1_500)
        #expect(display.rows.count == 200_000 + 1_500, "every file twice, plus a row per folder")
        #expect(Set(ids).count == ids.count, "no duplicate row ids at scale")
        expectWithinTimingBudget("FootageFolders index + compose, 100k files × 2 folders",
                                 measured: measured, budget: PerformanceLane.debugCeiling(.milliseconds(3_000)), loadBefore: load)
    }

    @Test("folder inspector facts for a 100k-file folder inside its budget")
    func inspectorFactsAtScale() {
        let e = EventRecord(name: "Big", categories: [])
        let members = (0..<100_000).map { i in
            FolderInspectorFacts.Member(contentKey: "k\(i / 2)", sizeBytes: Int64(i), durationSeconds: 1,
                                        date: Date(timeIntervalSince1970: Double(i)), volume: "Vol\(i % 9)", isOnline: i % 3 != 0)
        }
        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let facts = FolderInspectorFacts(event: e, title: "Big", members: members)
        let measured = ContinuousClock.now - start
        #expect(facts.files == 100_000)
        #expect(facts.recordings == 50_000)
        #expect(facts.volumes.count == 9)
        expectWithinTimingBudget("FolderInspectorFacts, 100k member files", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
    }
}

@Suite("Folder labels — sensors")
struct FolderLabelsSensorTests {

    @Test("SENSOR: the folder table maps ROW ids to records before any row action, and the inspector is filled in a handler")
    func rowIDsBecomeRecordsAndTheInspectorIsAHandler() throws {
        let table = try SourceTree.appCode(named: "CatalogContent+FolderTable.swift")
        #expect(table.contains("selection: folderSelectionBinding"))
        #expect(table.contains("FolderRowSelection.recordIDs(of: ids, refs: tableState.folderRowRefs)"))
        #expect(table.contains("folderMembershipItems(recordIDs: displayedIDs(among: fileIDs), inFolder: rowsFolder(ids))"))
        #expect(table.contains("openRows(ids: displayedIDs(among: fileIDs)"), "Return / double-click opens only rows on screen")
        #expect(table.contains("refreshFolderInspector()"))
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        #expect(helpers.contains("FolderInspectorView(facts: facts)"))
        #expect(helpers.contains("refreshFolderInspector()"))
        let view = try SourceTree.appCode(named: "FolderInspectorView.swift")
        for token in ["model.records", "records.filter", "for r in records"] {
            #expect(!view.contains(token), "the folder inspector view reads one value: \(token)")
        }
    }
}
