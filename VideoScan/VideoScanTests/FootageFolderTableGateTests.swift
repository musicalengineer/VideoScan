// FootageFolderTableGateTests.swift
// GH #350: during Fill In Full Hashes the folder Table re-walked every row
// on every model / MFO publish. The fix (FootageFolderTableGate.swift) puts
// the Table behind an Equatable paint value, publishes the rows only when
// they differ, and coalesces in-place repaints through a clock.
//
//   LOGIC   row equality (same record object, same facts) and the publish
//           decision; the host compares ONLY its paint value; each paint
//           input moves it; the throttle's leading / trailing / busy rules;
//           the clock's trailing paint lands; the writer words.
//   SCALE   10k records in 500 folders + loose files, then a commit of 50
//           digest-only changes (contentFixity on the record, the digest
//           on the join's row): the rebuilt rows are EQUAL — no republish —
//           inside an explicit budget.
//   SENSOR  the same 10k / 50 run pins "digest-only writes never change the
//           row array"; a source sensor pins that the folder Table is drawn
//           behind the gate and the rows are published through the gate.
//
// No app launch, no real paths: everything is in memory.

import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row
private typealias Keys = FootageFolders.SortKeys

/// A catalog in memory: records, the join's rows for them, and events.
@MainActor
private struct GateWorld {
    var records: [UUID: VideoRecord] = [:]
    var rows: [Row] = []
    var events: [FootageFolders.Event] = []
    var looseIDs: [UUID] = []

    /// `folders` events of `perFolder` recordings each, the rest loose.
    static func build(total: Int, folders: Int, perFolder: Int) -> GateWorld {
        var w = GateWorld()
        var eventKeys: [[String]] = Array(repeating: [], count: folders)
        for i in 0..<total {
            let rec = VideoRecord()
            rec.filename = "clip\(i).mov"
            rec.sizeBytes = Int64(1_000 + i)
            rec.durationSeconds = 60
            w.records[rec.id] = rec
            let row = Row(id: rec.id, sizeBytes: rec.sizeBytes, durationSeconds: 60, volume: "LaCie",
                          keys: Keys(filename: rec.filename, volume: "LaCie", duration: 60, size: rec.sizeBytes,
                                     date: Date(timeIntervalSince1970: Double(i) * 3_600)))
            w.rows.append(row)
            if i < folders * perFolder { eventKeys[i / perFolder].append(row.contentKey) } else { w.looseIDs.append(rec.id) }
        }
        w.events = eventKeys.enumerated().map { FootageFolders.Event(title: "Event \($0.offset)", contentKeys: $0.element) }
        return w
    }

    var index: FootageFolders.Index { FootageFolders.index(rows: rows, events: events) }

    /// The table's rows exactly as the Catalog pane builds them at the top
    /// (every folder composed open).
    func tableRows(_ index: FootageFolders.Index) -> [FootageFolderTableRow] {
        let display = FootageFolders.compose(index: index, visible: rows.map(\.id), sort: .byName,
                                             open: Set(index.folders.keys), scope: nil)
        let level = FootageFolderLevel.level(scope: nil, index: index, display: display)
        return FootageFolderTableRows.build(level, index: index, record: { records[$0] }, keys: { _ in Keys() })
    }

    /// What Fill In Full Hashes writes for one file: the whole-file digest
    /// on the record, and the join's row reprojected with it.
    mutating func fillFullHash(_ id: UUID, digest: String) {
        guard let rec = records[id], let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rec.contentFixity = ContentFixity(digest: digest, byteCount: rec.sizeBytes,
                                          stamp: FileIdentityStamp(device: 1, inode: UInt64(i + 1), size: rec.sizeBytes, mtimeNs: 0))
        // The join reads the digest through the same rule as the app
        // (`storedFullDigest`); the events identity of a loose file is not
        // read by any folder, so the row keeps its key here.
        rows[i].digest = VideoScanModel.storedFullDigest(rec)
    }
}

private func sha(_ i: Int) -> String { String(format: "%064x", 0xABC0_0000 + i) }

private func paint(rows: [FootageFolderTableRow] = [], selected: Set<UUID> = [], rowSelection: Set<UUID> = [],
                   expanded: Set<UUID> = [], pairTint: Bool = false, angel: Int = 0, revision: UInt64 = 0) -> FootageFolderTablePaint {
    FootageFolderTablePaint(rows: rows, selectedIDs: selected, rowSelection: rowSelection, expanded: expanded,
                            sort: [KeyPathComparator(\FootageFolderTableRow.filename)], pairTint: pairTint,
                            angelBadgeRevision: angel, paintRevision: revision)
}

@MainActor
@Suite("Folder table paint gate (GH #350)")
struct FootageFolderTableGateTests {

    // MARK: Logic — rows

    @Test func rowsRebuiltFromTheSameCatalogAreEqualAndNotRepublished() {
        let w = GateWorld.build(total: 40, folders: 3, perFolder: 5)
        let index = w.index
        let first = w.tableRows(index)
        let again = w.tableRows(index)
        #expect(!first.isEmpty)
        #expect(first == again)
        #expect(!FootageFolderTableRows.shouldPublish(again, over: first))
    }

    @Test func aRecordReplacedByAFreshObjectWithTheSameIDIsANewRow() throws {
        let w = GateWorld.build(total: 10, folders: 0, perFolder: 1)
        let index = w.index
        let before = w.tableRows(index)
        var swapped = w
        let id = try #require(w.looseIDs.first)
        let fresh = VideoRecord(id: id)
        fresh.filename = "clip0.mov"
        swapped.records[id] = fresh
        let after = swapped.tableRows(index)
        #expect(FootageFolderTableRows.shouldPublish(after, over: before),
                "a rescan's fresh object must reach the cells, never the retired one")
    }

    @Test func aVisibleSortFactChangeIsANewRow() throws {
        var w = GateWorld.build(total: 10, folders: 0, perFolder: 1)
        let before = w.tableRows(w.index)
        w.rows[0].keys.filename = "renamed.mov"
        let after = w.tableRows(w.index)
        #expect(FootageFolderTableRows.shouldPublish(after, over: before))
    }

    @Test func aFolderMembershipChangeIsANewRow() {
        var w = GateWorld.build(total: 20, folders: 2, perFolder: 5)
        let before = w.tableRows(w.index)
        w.events[0] = FootageFolders.Event(id: w.events[0].id, title: w.events[0].title,
                                           contentKeys: Array(w.events[0].contentKeys.dropLast()))
        let after = w.tableRows(w.index)
        #expect(FootageFolderTableRows.shouldPublish(after, over: before))
    }

    // MARK: Logic — the host and its paint value

    @Test func theHostComparesOnlyItsPaintValue() {
        let same = paint()
        let a = FootageFolderTableHost(paint: same) { Text("one") }
        let b = FootageFolderTableHost(paint: same) { Text("one") }
        #expect(a == b, "two different content closures, one paint value → no redraw")
        let c = FootageFolderTableHost(paint: paint(revision: 1)) { Text("one") }
        #expect(a != c)
    }

    @Test func everyPaintInputMovesThePaintValue() {
        let id = UUID()
        let base = paint()
        #expect(paint(selected: [id]) != base)
        #expect(paint(rowSelection: [id]) != base)
        #expect(paint(expanded: [id]) != base)
        #expect(paint(pairTint: true) != base)
        #expect(paint(angel: 1) != base)
        #expect(paint(revision: 1) != base)
        var resorted = base
        resorted.sort = [KeyPathComparator(\FootageFolderTableRow.size)]
        #expect(resorted != base)
        let w = GateWorld.build(total: 3, folders: 0, perFolder: 1)
        #expect(paint(rows: w.tableRows(w.index)) != base)
    }

    // MARK: Logic — the throttle and the clock

    @Test func quietCatalogPaintsAtOnceThenCoalescesInsideAQuarterSecond() {
        var t = CatalogPaintThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(t.request(now: t0, busy: false) == .paintNow)
        #expect(t.request(now: t0.addingTimeInterval(0.1), busy: false) == .paintAt(t0.addingTimeInterval(0.25)))
        #expect(t.request(now: t0.addingTimeInterval(0.2), busy: false) == .alreadyScheduled)
        t.didPaint(at: t0.addingTimeInterval(0.25))
        #expect(t.request(now: t0.addingTimeInterval(0.6), busy: false) == .paintNow)
    }

    @Test func whileAJobWritesAtMostOnePaintPerTenSeconds() {
        var t = CatalogPaintThrottle()
        let t0 = Date(timeIntervalSince1970: 2_000)
        #expect(t.request(now: t0, busy: true) == .paintNow)
        #expect(t.request(now: t0.addingTimeInterval(1), busy: true) == .paintAt(t0.addingTimeInterval(10)))
        for s in 2..<10 {
            #expect(t.request(now: t0.addingTimeInterval(Double(s)), busy: true) == .alreadyScheduled,
                    "second \(s): the one trailing paint is already due")
        }
    }

    @Test func aJobEndingBringsTheQuietPaceBack() {
        var t = CatalogPaintThrottle()
        let t0 = Date(timeIntervalSince1970: 3_000)
        #expect(t.request(now: t0, busy: true) == .paintNow)
        #expect(t.request(now: t0.addingTimeInterval(1), busy: true) == .paintAt(t0.addingTimeInterval(10)))
        #expect(t.request(now: t0.addingTimeInterval(2), busy: false) == .paintNow,
                "the job ended: an edit paints now, not at the job's pace")
    }

    @Test func theClocksTrailingPaintLands() async throws {
        let clock = CatalogPaintClock()
        clock.request(busy: false)
        #expect(clock.revision == 1, "leading edge: at once")
        clock.request(busy: false)
        clock.request(busy: false)
        #expect(clock.revision == 1, "inside the gap: coalesced")
        try await Task.sleep(for: .milliseconds(600))
        #expect(clock.revision == 2, "the last request of the burst always lands")
    }

    @Test func writerWords() {
        #expect(CatalogWriteActivity.words(runningJobTitle: nil, scanning: false) == nil)
        #expect(CatalogWriteActivity.words(runningJobTitle: "Fill In Full Hashes", scanning: false) == "Fill In Full Hashes is running")
        #expect(CatalogWriteActivity.words(runningJobTitle: nil, scanning: true) == "a scan is running")
        #expect(CatalogWriteActivity.words(runningJobTitle: "", scanning: false) == nil)
    }

    // MARK: Scale + sensor — 10k records, a commit of 50 digest-only changes

    /// The production shape of #350: ~10k records shown as folders, a hash
    /// job's checkpoint commit of 50 whole-file digests. The rebuilt rows
    /// must equal the old ones (no republish → the gate holds), inside
    /// 300 ms Debug for build + compare (TimingBudget-judged).
    @Test func tenThousandRecordsAndFiftyDigestOnlyChangesRepublishNothing() throws {
        var w = GateWorld.build(total: 10_000, folders: 500, perFolder: 10)
        let before = w.tableRows(w.index)
        #expect(before.count == 500 + 5_000, "500 folders and the 5,000 loose files")
        #expect(before.reduce(0) { $0 + ($1.children?.count ?? 0) } == 5_000)

        for (n, id) in w.looseIDs.prefix(50).enumerated() { w.fillFullHash(id, digest: sha(n)) }
        #expect(w.looseIDs.prefix(50).allSatisfy { w.records[$0]?.contentFixity != nil })
        let index = w.index

        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let after = w.tableRows(index)
        let publish = FootageFolderTableRows.shouldPublish(after, over: before)
        let elapsed = ContinuousClock.now - start

        #expect(!publish, "a digest-only commit must not republish the folder rows (GH #350)")
        #expect(after == before)
        expectWithinTimingBudget("folder rows rebuild + compare, 10k records / 50 digests",
                                 measured: elapsed, budget: PerformanceLane.debugCeiling(.milliseconds(300)), loadBefore: load)
    }

    // MARK: Sensor — the Table is drawn behind the gate

    @Test func theFolderTableIsDrawnBehindThePaintGate() throws {
        let src = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogContent+FolderTable.swift"))
        #expect(src.contains("FootageFolderTableHost(paint: folderTablePaint) { footageFolderTableCore }"))
        #expect(src.contains(".equatable()"))
        #expect(src.contains("FootageFolderTableRows.shouldPublish(rows, over: tableState.folderRows)"),
                "the rows are published only when they differ")
        #expect(!src.contains("tableState.folderRows = folderTableRows("), "no unconditional republish")
        let table = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogContent+Table.swift"))
        #expect(table.contains(".onReceive(model.objectWillChange) { _ in requestFolderPaint() }"))
    }
}
