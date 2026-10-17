// FootageFolderLevelTests.swift
// The two Finder levels of Show ▸ Events & Copies as Folders (Rick
// 2026-10-17; FootageFolderLevel.swift) — the pure presentation step
// between the join's display and the table's rows.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — the top level: folders by date then name, then the loose
//               files (a loose file's copies still under it); the inside
//               level IS the flat event scope minus the folder row; the
//               folder row's words (items · copies, the date range); a
//               folder the join no longer has; the Finder keys.
//   Scale     — 100k rows / 2k events: the top and one inside level
//               inside a budget (TimingBudget-judged).
//   Isolation — N/A (pure values; the Show setting is pinned in
//               FootageFoldersTests).
//   Sensor    — a folder row is never in `selection ∩ displayed`; the
//               table passes NO open set (nothing twists; the level is
//               the scope); the state has no open set left.
// Media matrix: N/A — catalog metadata only; no file is opened.
//
// Suite (filter by SUITE — method-level -only-testing runs zero tests):
//   FootageFolderLevelTests

import AppKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row
private typealias Keys = FootageFolders.SortKeys

private func row(_ name: String, digest: String? = nil, size: Int64 = 1_000, seconds: Double = 60,
                 from: UUID? = nil, kind: String? = nil, volume: String = "LaCie",
                 date: Date = .distantPast, id: UUID = UUID()) -> Row {
    Row(id: id, digest: digest, sizeBytes: size, durationSeconds: seconds, derivedFrom: from, derivationKind: kind,
        volume: volume, keys: Keys(filename: name, volume: volume, duration: seconds, size: size, date: date))
}

private func event(_ title: String, _ rows: [Row], id: UUID = UUID()) -> FootageFolders.Event {
    FootageFolders.Event(id: id, title: title, contentKeys: rows.map(\.contentKey))
}

/// Noon UTC on that day — the same calendar day in every US zone.
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? .distantPast
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

/// Two events — Marks Birthday 1984 (two days, one copy) and Cape 1990 —
/// plus two loose files, one of them with a copy.
private struct Fixture {
    let b1 = row("b1.dv", digest: "b1", size: 100, seconds: 600, date: day(1984, 4, 7))
    let b2 = row("b2.dv", digest: "b2", size: 50, seconds: 300, date: day(1984, 4, 8))
    let bCopy: Row
    let a1 = row("a1.dv", digest: "a1", size: 70, seconds: 120, date: day(1990, 7, 1))
    let x: Row
    let xCopy: Row
    let y = row("y.mov")
    let recX = VideoRecord()
    let marks: FootageFolders.Event
    let cape: FootageFolders.Event
    let index: FootageFolders.Index

    init() {
        bCopy = row("b1.dv", digest: "b1", size: 100, seconds: 600, volume: "Backup", date: day(1984, 4, 7))
        x = row("x.mov", digest: "x", id: recX.id)
        xCopy = row("x.mov", digest: "x", volume: "Backup")
        marks = event("Marks Birthday 1984", [b1, b2])
        cape = event("Cape 1990", [a1])
        index = FootageFolders.index(rows: [a1, b1, b2, bCopy, x, xCopy, y], events: [cape, marks])
    }

    /// The table's order: the Cape recording first, so a name sort would
    /// put its folder before Marks — the date order must win at the top.
    var rows: [Row] { [a1, b1, b2, bCopy, x, xCopy, y] }
    var visible: [UUID] { rows.map(\.id) }

    func display(scope: FootageFolders.Scope?) -> FootageFolders.Display {
        FootageFolders.compose(index: index, visible: visible, sort: .byName, open: [], scope: scope)
    }

    func top() -> FootageFolderLevel.Level {
        FootageFolderLevel.level(scope: nil, index: index, display: display(scope: nil))
    }
}

@Suite("Footage folder levels — the Finder's two levels")
struct FootageFolderLevelTests {

    // MARK: Logic

    @Test func topLevelListsFoldersByDateThenNameThenTheLooseFiles() {
        let f = Fixture()
        let top = f.top()
        #expect(top.rows.map(\.id) == [f.marks.id, f.cape.id, f.x.id, f.xCopy.id, f.y.id],
                "folders first (1984 before 1990, whatever the name sort), then the loose rows in the table's order")
        #expect(top.isTop)
        #expect(top.folderIDs == [f.marks.id, f.cape.id])
        #expect(top.recordIDs == [f.x.id, f.xCopy.id, f.y.id], "the loose files are the only records on screen")
        #expect(top.rows[3].relation?.isCopy == true, "a loose file's copy still sits under it, grey")
    }

    @Test func foldersWithTheSameDateSortByName() {
        let p = row("p.dv", digest: "p", date: day(2001, 1, 1)), q = row("q.dv", digest: "q", date: day(2001, 1, 1))
        let zed = event("Zed", [p]), alpha = event("Alpha", [q])
        let index = FootageFolders.index(rows: [p, q], events: [zed, alpha])
        let display = FootageFolders.compose(index: index, visible: [p.id, q.id], sort: .init(key: .size, ascending: false),
                                             open: [], scope: nil)
        let top = FootageFolderLevel.top(index: index, display: display)
        #expect(top.rows.map(\.id) == [alpha.id, zed.id])
    }

    @Test func folderRowCarriesTheCountsTheSizeAndTheDateRange() throws {
        let f = Fixture()
        let marks = try #require(f.top().folders[f.marks.id])
        #expect(marks.name == "Marks Birthday 1984")
        #expect(marks.items == 3, "two recordings and one copy")
        #expect(marks.copies == 1)
        #expect(marks.itemsWords == "3 items · 1 copy")
        #expect(marks.totalBytes == 250)
        #expect(marks.totalSeconds == 900, "the recordings' running time, not the copy's")
        #expect(marks.dateWords == "Apr 7, 1984 – Apr 8, 1984")
        #expect(marks.date == day(1984, 4, 7))
        let cape = try #require(f.top().folders[f.cape.id])
        #expect(cape.itemsWords == "1 item")
        #expect(cape.dateWords == "Jul 1, 1990", "one day reads as one day")
    }

    @Test func insideLevelIsTheFlatEventScopeWithoutTheFolderRow() {
        let f = Fixture()
        let flat = f.display(scope: .event(f.marks.id))
        let inside = FootageFolderLevel.level(scope: .event(f.marks.id), index: f.index, display: flat)
        #expect(flat.rows.first?.isFolder == true, "the flat scope leads with the folder row")
        #expect(inside.rows == Array(flat.rows.dropFirst()), "inside = the flat rows minus that row, nothing else moves")
        #expect(inside.rows.map(\.id) == [f.b1.id, f.bCopy.id, f.b2.id], "recording · = copy · ≈ the other recording")
        #expect(inside.rows[1].relation?.isCopy == true)
        #expect(inside.rows[2].relation == .sameEvent)
        #expect(inside.folderIDs.isEmpty)
        #expect(inside.recordIDs == [f.b1.id, f.b2.id, f.bCopy.id])
        #expect(!inside.isTop)
    }

    @Test func insideAFamilyIsShowCopiesAndRelated() {
        let f = Fixture()
        let flat = f.display(scope: .family(f.xCopy.id))
        let inside = FootageFolderLevel.level(scope: .family(f.xCopy.id), index: f.index, display: flat)
        #expect(inside.rows.map(\.id) == [f.x.id, f.xCopy.id])
        #expect(inside.rows == flat.rows, "no folder row to drop: the family as the flat view shows it")
    }

    @Test func aFolderTheJoinNoLongerHasSendsTheTableToTheTop() {
        let f = Fixture()
        #expect(FootageFolderLevel.exists(.event(f.marks.id), in: f.index))
        #expect(FootageFolderLevel.exists(.family(f.x.id), in: f.index))
        let withoutMarks = FootageFolders.index(rows: f.rows, events: [f.cape])
        #expect(!FootageFolderLevel.exists(.event(f.marks.id), in: withoutMarks), "merged or dismissed: gone")
        #expect(!FootageFolderLevel.exists(.family(UUID()), in: f.index), "a record that left the catalog: gone")
        #expect(FootageFolderLevel.exists(.event(f.marks.id), in: .empty), "a join not built yet says nothing")
    }

    @Test func aFolderRowTheDisplayNoLongerHasIsDropped() {
        let f = Fixture()
        let stale = FootageFolders.Display(rows: [.folder(FootageFolders.Folder(id: UUID(), title: "Gone"))] + f.display(scope: nil).rows)
        let top = FootageFolderLevel.top(index: f.index, display: stale)
        #expect(top.rows.map(\.id) == [f.marks.id, f.cape.id, f.x.id, f.xCopy.id, f.y.id])
    }

    @Test func theWordsReadLikeTheFinder() {
        #expect(FootageFolderWords.itemsAndCopies(items: 12, copies: 3) == "12 items · 3 copies")
        #expect(FootageFolderWords.itemsAndCopies(items: 1, copies: 0) == "1 item")
        #expect(FootageFolderWords.dateRange(day(1984, 4, 7), day(1984, 4, 7)) == "Apr 7, 1984")
        #expect(FootageFolderWords.dateRange(day(1984, 4, 8), day(1984, 4, 7)) == "Apr 7, 1984 – Apr 8, 1984", "a reversed pair still reads as the span")
        #expect(FootageFolderWords.crumbPath(nil) == "Catalog")
        #expect(FootageFolderWords.crumbPath("Marks Birthday 1984") == "Catalog ▸ Marks Birthday 1984")
    }

    @Test func finderKeysAreTheCommandArrowsBesideTheBareOnes() {
        #expect(FootageFolderKey(commandKeyCode: 125) == .open, "⌘↓ opens the selected folder")
        #expect(FootageFolderKey(commandKeyCode: 126) == .close, "⌘↑ is Enclosing Folder")
        #expect(FootageFolderKey(commandKeyCode: 124) == nil, "⌘→ keeps its owner")
        #expect(FootageFolderKey(keyCode: 126, modifiers: []) == nil, "bare ↑ is the Table's row walk")
        #expect(FootageFolderKey(keyCode: 126, modifiers: [.command]) == .close)
        #expect(FootageFolderKey(keyCode: 126, modifiers: [.command, .function]) == .close, "fn rides along on an arrow key")
        #expect(FootageFolderKey(keyCode: 125, modifiers: [.command, .shift]) == nil, "⇧⌘↓ is not ours")
        #expect(FootageFolderKey(keyCode: 124, modifiers: [.numericPad, .function]) == .open, "bare → as the hardware reports it")
    }

    // MARK: Sensors

    /// A folder row is selectable but never a target: `selection ∩
    /// displayed` sees records only.
    @Test func aFolderRowNeverReachesARowAction() {
        let f = Fixture()
        let top = f.top()
        #expect(!top.recordIDs.contains(f.marks.id))
        let shown = CatalogSelectionPrune.displayed([f.marks.id, f.recX.id], foldersOn: true,
                                                    folderRecordIDs: top.recordIDs, rows: [f.recX])
        #expect(shown == [f.recX.id], "⌘⌫, Promote, ⌘O and the row menu see the loose file, never the folder")
        let insideRows = FootageFolderLevel.level(scope: .event(f.marks.id), index: f.index,
                                                  display: f.display(scope: .event(f.marks.id))).recordIDs
        #expect(CatalogSelectionPrune.displayed([f.marks.id, f.recX.id], foldersOn: true,
                                                folderRecordIDs: insideRows, rows: [f.recX]).isEmpty,
                "inside Marks, the loose file is off screen and the folder id is still no record")
    }

    /// Nothing twists any more: the table composes with no open set and
    /// the level is the scope; the state has no open set left.
    @Test func theTableComposesWithNoOpenSet() throws {
        let table = try code("CatalogContent+FolderTable.swift")
        #expect(table.contains("open: [],"), "the compose request never opens a folder inline")
        #expect(table.contains("FootageFolderLevel.level(scope: tableState.folderScope, index: index, display: display)"))
        #expect(table.contains("case .close, .escape: return leaveFolderByKey()"), "←, ⌘↑ and Esc go up one level")
        #expect(table.contains("tableState.folderRecordIDs = level.recordIDs"), "the displayed set is the level's records")
        let state = try code("CatalogTableState.swift")
        #expect(!state.contains("openFolderIDs"))
        let words = try code("FootageFolderWords.swift")
        #expect(!words.contains("chevron.right"), "no twisty glyph is left in the words")
    }

    // MARK: Scale

    /// 100k rows: 2k events of 20 recordings, 20k copies, the rest loose.
    /// The top level and one inside level each inside 500 ms Debug on the
    /// M4 (TimingBudget-judged on a busy machine).
    @Test func hundredThousandRowsUnderBudget() throws {
        var rows: [Row] = []
        rows.reserveCapacity(100_000)
        let eventCount = 2_000
        var eventKeys: [[String]] = Array(repeating: [], count: eventCount)
        for i in 0..<40_000 {
            let r = row("clip\(i).mov", digest: String(format: "%040x", i), size: Int64(1_000 + i),
                        date: Date(timeIntervalSince1970: Double(i) * 3_600))
            rows.append(r)
            eventKeys[i / 20].append(r.contentKey)
        }
        for i in 0..<20_000 {
            let src = rows[i * 2]
            rows.append(row("clip\(i * 2).mov", digest: src.digest, size: src.sizeBytes, volume: "Backup"))
        }
        while rows.count < 100_000 { rows.append(row("loose\(rows.count).mov")) }
        let events = eventKeys.enumerated().map { FootageFolders.Event(title: "Event \($0.offset)", contentKeys: $0.element) }
        let index = FootageFolders.index(rows: rows, events: events)
        let visible = rows.map(\.id)
        let topDisplay = FootageFolders.compose(index: index, visible: visible, sort: .byName, open: [], scope: nil)
        let first = try #require(events.first?.id)
        let insideDisplay = FootageFolders.compose(index: index, visible: visible, sort: .byName, open: [], scope: .event(first))

        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let top = FootageFolderLevel.level(scope: nil, index: index, display: topDisplay)
        let topTime = ContinuousClock.now - start
        let insideStart = ContinuousClock.now
        let inside = FootageFolderLevel.level(scope: .event(first), index: index, display: insideDisplay)
        let insideTime = ContinuousClock.now - insideStart

        #expect(top.folders.count == eventCount)
        #expect(top.rows.prefix(eventCount).allSatisfy { $0.isFolder }, "every folder before every loose file")
        #expect(top.rows.dropFirst(eventCount).allSatisfy { !$0.isFolder })
        #expect(top.rows.count == eventCount + 40_000, "2k folders and the 40k loose files")
        #expect(inside.rows.count == 30, "20 recordings and their 10 copies")
        expectWithinTimingBudget("FootageFolderLevel.top 100k rows / 2k events",
                                 measured: topTime, budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
        expectWithinTimingBudget("FootageFolderLevel.inside one event of 30",
                                 measured: insideTime, budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
    }
}
