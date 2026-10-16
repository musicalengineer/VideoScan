// FootageFoldersTests.swift
// Footage folders — the Catalog shows events and copies the way the
// Finder shows folders (docs/design/footage_folders_2026_10_16.md §6).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — grouping by event / copies / lineage / loose; the keeper
//               (archived › better transfer › longest); family order
//               (recording · ↳ · = · ≈); a copy outside an event follows
//               its original; a `v1:` hash is never a copy; a superseded
//               row stays with its family; the display with no folders is
//               today's rows in today's order; scopes; open / closed.
//   Scale     — 100k rows, 2k events, 30k copies: index + compose inside
//               the coverage pass's budget (TimingBudget-judged).
//   Isolation — a damaged events file → no folders, no crash; a poisoned
//               Show setting → off. Private temp dir / defaults suite.
//   Sensor    — no view body touches `records`; the folder rows observe
//               only the snapshot; the post-job reveal path is pinned at
//               every job's append site.
//   Structure — the Show option exists and defaults off; the legend and
//               the pill appear only while it is on; the linear table is
//               the one drawn when it is off.
// Media matrix: N/A — catalog metadata only; no file is opened.
//
// Suites (filter by SUITE — method-level -only-testing runs zero tests):
//   FootageFoldersLogicTests · FootageFoldersScaleTests ·
//   FootageFoldersIsolationTests · FootageFoldersSensorTests ·
//   FootageFoldersStructureTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Builders

private typealias Row = FootageFolders.Row
private typealias Keys = FootageFolders.SortKeys

private func row(_ name: String, digest: String? = nil, size: Int64 = 1_000, seconds: Double = 60,
                 from: UUID? = nil, kind: String? = nil, dup: UUID? = nil, volume: String = "LaCie",
                 archived: Bool = false, archiveFile: Bool = false, codec: CodecGeneration = .unknown,
                 height: Int? = nil, bitRate: Int64? = nil, hidden: Bool = false, superseded: Bool = false,
                 date: Date = .distantPast, id: UUID = UUID()) -> Row {
    Row(id: id, digest: digest, sizeBytes: size, durationSeconds: seconds, derivedFrom: from, derivationKind: kind,
        duplicateGroupID: dup, isHidden: hidden, isSuperseded: superseded, isArchived: archived,
        isArchiveFile: archiveFile, codec: codec, frameHeight: height, bitRate: bitRate, volume: volume,
        displayCodec: "", keys: Keys(filename: name, volume: volume, duration: seconds, size: size, date: date))
}

private func event(_ title: String, _ rows: [Row], id: UUID = UUID()) -> FootageFolders.Event {
    FootageFolders.Event(id: id, title: title, contentKeys: rows.map(\.contentKey))
}

private extension FootageFolders.Display {
    var ids: [UUID] { rows.map(\.id) }
    func relation(of id: UUID) -> FootageFolders.Relation? { rows.first { $0.id == id }?.relation }
    var folderIDs: [UUID] { rows.compactMap(\.eventID) }
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

// MARK: - Logic

@Suite("Footage folders — how media is related into folders")
struct FootageFoldersLogicTests {

    @Test func confirmedEventBecomesAFolderAndTheRestStaysLoose() {
        let a = row("a.mov", digest: "aaaa"), b = row("b.mov", digest: "bbbb"), loose = row("z.mov")
        let e = event("Thanksgiving 2009", [a, b])
        let d = FootageFolders.build(rows: [a, b, loose], events: [e])
        #expect(d.ids == [e.id, a.id, b.id, loose.id], "folder (open) · its two recordings · the loose file")
        #expect(d.relation(of: a.id) == .recording)
        #expect(d.relation(of: b.id) == .sameEvent, "a second family in the folder reads ≈")
        #expect(d.relation(of: loose.id) == nil)
        #expect(d.summaries[e.id]?.files == 2)
    }

    @Test func noEventsAndNoCopiesIsTodaysRowsInTodaysOrder() {
        let rows = (0..<5).map { row("f\($0).mov") }
        let d = FootageFolders.build(rows: rows, events: [], sort: .init(key: .size, ascending: false))
        #expect(d.ids == rows.map(\.id), "the display with nothing to fold IS the linear table")
        #expect(d.rows.allSatisfy { $0.relation == nil && !$0.isFolder })
        #expect(d.summaries.isEmpty)
    }

    @Test func copiesByWholeFileDigestAndSizeReadGreyUnderTheRecording() {
        let a = row("tape.dv", digest: "ABCD", size: 500, volume: "LaCie")
        let c = row("tape.dv", digest: "abcd", size: 500, volume: "SanDisk")
        let notACopy = row("tape.dv", digest: "abcd", size: 501, volume: "X9")   // same digest, other size
        let d = FootageFolders.build(rows: [a, c, notACopy], events: [])
        #expect(d.ids.first == a.id)
        #expect(d.relation(of: c.id)?.isCopy == true)
        #expect(d.relation(of: c.id)?.words == "copy · byte for byte, SanDisk")
        #expect(d.relation(of: notACopy.id) == nil, "digest without the size is not a copy")
    }

    @Test func sampledV1HashIsNeverACopy() {
        let a = row("x.flv", digest: "v1:1234", size: 10), b = row("x.flv", digest: "v1:1234", size: 10)
        #expect(a.copyKey == nil)
        let d = FootageFolders.build(rows: [a, b], events: [])
        #expect(d.ids == [a.id, b.id])
        #expect(d.rows.allSatisfy { $0.relation == nil }, "two v1: hashes stay two loose files")
    }

    @Test func duplicateGroupMakesACopyWhenThereIsNoDigest() {
        let g = UUID()
        let a = row("a.mov", dup: g, volume: "LaCie"), b = row("a.mov", dup: g, volume: "X9")
        let d = FootageFolders.build(rows: [a, b], events: [])
        #expect(d.relation(of: b.id)?.words == "copy · same duplicate group, X9")
    }

    @Test func lineageReadsMadeFromItUnderTheSource() {
        let src = row("src.dv", digest: "s1", codec: .original)
        let master = row("src.mkv", digest: "m1", from: src.id, kind: "preservation")
        let d = FootageFolders.build(rows: [master, src], events: [])
        #expect(d.ids == [src.id, master.id], "the source leads, whatever the input order")
        #expect(d.relation(of: master.id) == .madeFrom("made from it · preservation master"))
    }

    @Test func familyOrderIsRecordingThenMadeFromThenCopies() {
        let rec = row("r.dv", digest: "r")
        let copy = row("r.dv", digest: "r", volume: "B")
        let v1 = row("r.mkv", digest: "v", from: rec.id, kind: "transcode")
        let v2 = row("r.mov", digest: "w", from: rec.id, kind: "trim")
        let d = FootageFolders.build(rows: [copy, v2, rec, v1], events: [])
        #expect(d.ids == [rec.id, v1.id, v2.id, copy.id], "recording · ↳ (by name) · = — the copy the versions were made from leads, even listed last")
        #expect(d.rows.map { $0.relation?.tier ?? 0 } == [0, 1, 1, 2])
    }

    @Test func copyOutsideAnyEventFollowsItsOriginalIntoTheFolder() {
        let original = row("party.mov", digest: "p1", volume: "LaCie")
        let stray = row("party.mov", digest: "p1", volume: "Backup")
        let e = event("Birthday", [original])
        // Two identical files: the first the catalog scanned is the recording (a full tie on the keeper rule).
        let d = FootageFolders.build(rows: [original, stray], events: [e])
        #expect(d.ids == [e.id, original.id, stray.id])
        #expect(d.relation(of: stray.id)?.isCopy == true)
        #expect(d.summaries[e.id]?.copies == 1)
        #expect(d.summaries[e.id]?.files == 2)
    }

    @Test func versionOutsideAnyEventFollowsItsSourceToo() {
        let src = row("x.dv", digest: "x")
        let edit = row("x.vs.edit.mov", digest: "y", from: src.id, kind: "editing")
        let e = event("Christmas", [src])
        let d = FootageFolders.build(rows: [src, edit], events: [e])
        #expect(d.ids == [e.id, src.id, edit.id])
        #expect(d.relation(of: edit.id) == .madeFrom("made from it · editing copy"))
    }

    @Test func keeperIsTheArchivedFileElseTheBetterTransferElseTheLongest() {
        let g = UUID()
        // Same duplicate group, three transfers.
        let short = row("short.mov", seconds: 100, dup: g, codec: .original)
        let long = row("long.mov", seconds: 120, dup: g, codec: .delivery)
        let archived = row("arch.mov", seconds: 50, dup: g, archived: true)
        #expect(FootageFolders.build(rows: [short, long, archived], events: []).ids.first == archived.id, "archived wins")
        #expect(FootageFolders.build(rows: [short, long], events: []).ids.first == long.id, "longer by > 5 % wins")
        let a = row("a.mov", seconds: 100, dup: g, codec: .original)
        let b = row("b.mov", seconds: 103, dup: g, codec: .delivery)
        #expect(FootageFolders.build(rows: [b, a], events: []).ids.first == a.id, "within 5 %: the original-generation codec")
        let hd = row("hd.mov", seconds: 100, dup: g, height: 1080), sd = row("sd.mov", seconds: 100, dup: g, height: 480)
        #expect(FootageFolders.build(rows: [sd, hd], events: []).ids.first == hd.id, "then the larger frame")
        let hi = row("hi.mov", seconds: 100, dup: g, bitRate: 9_000), lo = row("lo.mov", seconds: 100, dup: g, bitRate: 2_000)
        #expect(FootageFolders.build(rows: [lo, hi], events: []).ids.first == hi.id, "then the bit rate")
        let x = row("x.mov", seconds: 100, dup: g), y = row("y.mov", seconds: 104, dup: g)
        #expect(FootageFolders.build(rows: [x, y], events: []).ids.first == y.id, "tie on the ladder: the longest")
    }

    @Test func theArchiveCopyOfARecordingCarriesTheFamily() {
        // Promote copies the bytes: same digest, derivedFrom the source.
        let src = row("tape.dv", digest: "t", size: 9)
        let promoted = row("tape.dv", digest: "t", size: 9, from: src.id, kind: "promote", archived: true, archiveFile: true)
        let d = FootageFolders.build(rows: [src, promoted], events: [])
        #expect(d.ids == [promoted.id, src.id])
        #expect(d.relation(of: src.id)?.isCopy == true, "the original reads as the copy of the archive's file")
    }

    @Test func supersededRowStaysWithItsFamilyWhenShown() {
        let original = row("damaged.mov", digest: "d1", superseded: true)
        let repaired = row("damaged.vs.repaired.mov", digest: "d2", from: original.id, kind: "rebuildAudio")
        let e = event("Easter", [original, repaired])
        let shown = FootageFolders.build(rows: [original, repaired], events: [e])
        #expect(shown.ids == [e.id, original.id, repaired.id], "one family: the original and its repair")
        #expect(shown.relation(of: repaired.id)?.tier == 1)
        #expect(shown.summaries[e.id]?.files == 1, "a superseded row is not counted in the folder's summary")
        let hidden = FootageFolders.build(rows: [original, repaired], events: [e], visible: [repaired.id])
        #expect(hidden.ids == [e.id, repaired.id], "filtered out: the repair still sits in the folder")
    }

    @Test func foldersAndLooseFilesSortTogetherByTheTableKey() {
        let a = row("a.mov", seconds: 10), m = row("m.mov", digest: "m", seconds: 30), z = row("z.mov", seconds: 50)
        let e = event("Middle", [m])
        let byName = FootageFolders.build(rows: [a, m, z], events: [e], open: [])
        #expect(byName.ids == [a.id, e.id, z.id], "Middle sorts between a and z; closed folder shows no members")
        let byDuration = FootageFolders.build(rows: [z, a, m], events: [e], sort: .init(key: .duration, ascending: false), open: [],
                                              visible: [z.id, a.id])
        #expect(byDuration.ids == [z.id, a.id], "a folder with no visible member is not shown")
        let descending = FootageFolders.build(rows: [a, m, z], events: [e], sort: .init(key: .duration, ascending: false), open: [],
                                              visible: [z.id, a.id, m.id])
        #expect(descending.ids == [z.id, e.id, a.id], "loose rows keep the table's order; the folder (30 s) merges in")
    }

    @Test func membersInsideAFolderFollowFamilyOrderThenTheSort() {
        let r1 = row("b.mov", digest: "r1", seconds: 10, volume: "M"), r2 = row("a.mov", digest: "r2", seconds: 20, volume: "L")
        let c1 = row("b.mov", digest: "r1", seconds: 10, volume: "Z"), c2 = row("b.mov", digest: "r1", seconds: 10, volume: "A")
        let e = event("E", [r1, r2])
        let d = FootageFolders.build(rows: [r1, r2, c1, c2], events: [e], sort: .init(key: .volume, ascending: true))
        #expect(d.ids == [e.id, r2.id, r1.id, c2.id, c1.id], "keepers by the sort; the copies under theirs, by the sort")
    }

    @Test func eventScopeShowsOneFolderOpenAndFamilyScopeShowsOneFamily() {
        let a = row("a.mov", digest: "a"), b = row("b.mov", digest: "b"), copyA = row("a.mov", digest: "a", volume: "Y")
        let e1 = event("One", [a]), e2 = event("Two", [b])
        let scoped = FootageFolders.build(rows: [a, b, copyA], events: [e1, e2], open: [], scope: .event(e1.id))
        #expect(scoped.ids == [e1.id, a.id, copyA.id], "scope forces the folder open and hides everything else")
        let lone = row("lone.mov"), twin = row("lone.mov", digest: "l"), twin2 = row("lone.mov", digest: "l", volume: "B")
        let fam = FootageFolders.build(rows: [lone, twin, twin2], events: [], scope: .family(twin2.id))
        #expect(fam.ids == [twin.id, twin2.id])
        #expect(fam.rows.first?.relation == nil, "the keeper is a plain row in its own scope")
        #expect(fam.relation(of: twin2.id)?.isCopy == true)
        #expect(FootageFolders.build(rows: [lone], events: [], scope: .family(lone.id)).ids == [lone.id], "no family: just the file")
    }

    @Test func folderSummaryCountsFilesCopiesTimeArchivedAndDate() {
        let day = Date(timeIntervalSince1970: 1_259_236_800)   // 2009-11-26 12:00 UTC (a day in every US zone)
        let r = row("r.dv", digest: "r", size: 100, seconds: 600, archived: true, date: day)
        let c = row("r.dv", digest: "r", size: 100, seconds: 600, volume: "B", archived: true, date: day)
        let v = row("r.mkv", digest: "v", size: 50, seconds: 600, from: r.id, kind: "transcode")
        let other = row("o.mov", digest: "o", size: 7, seconds: 60, date: day.addingTimeInterval(86_400))
        let hidden = row("junk.mov", digest: "j", size: 999, hidden: true)
        let e = event("Thanksgiving", [r, other, hidden])
        let d = FootageFolders.build(rows: [r, c, v, other, hidden], events: [e])
        let s = try! #require(d.summaries[e.id])
        #expect(s.files == 4, "hidden rows are not counted")
        #expect(s.copies == 1)
        #expect(s.totalSeconds == 660, "running time sums the recordings, not their copies or versions")
        #expect(s.totalBytes == 257)
        #expect(s.archivedCount == 2)
        #expect(s.dateWords == "Nov 26, 2009", "the earliest recording's day")
    }

    @Test func eventsComeStraightFromTheDecisions() {
        let e = EventRecord(name: "Birthday", categories: ["Birthday"])
        let gone = EventRecord(name: "Old", categories: [], state: .dismissed)
        let d = EventsDecisionSnapshot(events: [e, gone], decisions: [
            .member(eventID: e.id, range: ContentRange(contentKey: "k1"), verdict: .accepted),
            .member(eventID: e.id, range: ContentRange(contentKey: "k2"), verdict: .accepted),
            .member(eventID: e.id, range: ContentRange(contentKey: "k2"), verdict: .rejected),
            .member(eventID: gone.id, range: ContentRange(contentKey: "k3"), verdict: .accepted),
        ])
        let events = FootageFolders.Event.events(in: d)
        #expect(events.map(\.title) == ["Birthday"], "a dismissed event is no folder")
        #expect(events.first?.contentKeys == ["k1"], "a rejected member is out")
    }

    @Test func selectionPruneIsUnchangedAndAFolderIdSurvivesThroughRefreshRows() throws {
        let a = VideoRecord(), folder = UUID()
        #expect(CatalogSelectionPrune.visibleSelection([a.id, folder], rows: [a]) == [a.id], "today's rule, untouched")
        let state = try code("CatalogTableState.swift")
        #expect(state.contains(".union(selectedIDs.intersection(tableState.folderIDs))"), "a selected folder row survives refreshRows")
    }

    @Test func looseFamilyCarriesItsRelativesUnderItsFirstVisibleMember() {
        let keeper = row("k.mov", digest: "k", seconds: 100), copy = row("k.mov", digest: "k", seconds: 100, volume: "B")
        let other = row("o.mov")
        let d = FootageFolders.build(rows: [other, keeper, copy], events: [])
        #expect(d.ids == [other.id, keeper.id, copy.id], "the family sits where its first member was; the keeper leads it")
        #expect(d.rows[1].relation == nil && d.relation(of: copy.id)?.isCopy == true)
        let hiddenKeeper = FootageFolders.build(rows: [keeper, copy], events: [], visible: [copy.id])
        #expect(hiddenKeeper.ids == [copy.id] && hiddenKeeper.rows[0].relation == nil, "a filtered-out keeper: the copy reads plain")
    }

    @Test func sortMappingRoundTripsEveryColumn() {
        for c in FootageFolderSort.columns {
            let rec = [c.recordComparator(.reverse)]
            let sort = FootageFolderSort.sort(from: rec)
            #expect(sort.key == c.key && sort.ascending == false, "\(c.key)")
            let rows = FootageFolderSort.rowComparators(from: rec)
            #expect(rows.count == 1)
            #expect(FootageFolderSort.recordComparators(from: rows).first?.keyPath == c.record, "\(c.key) round-trips")
        }
        #expect(FootageFolderSort.sort(from: []) == .byName)
    }
}

// MARK: - Scale

@Suite("Footage folders — scale")
struct FootageFoldersScaleTests {

    /// 100k rows: 2k events of 20 recordings, 30k copies (one in three
    /// recordings has a copy, by digest or by group), 10k versions, the
    /// rest loose. Index + compose inside the coverage pass's 1.5 s
    /// Debug budget on the M4 (TimingBudget-judged on a busy machine).
    @Test func hundredThousandRowsUnderBudget() {
        var rows: [Row] = []
        rows.reserveCapacity(100_000)
        var events: [FootageFolders.Event] = []
        let eventCount = 2_000
        var eventKeys: [[String]] = Array(repeating: [], count: eventCount)
        var sources: [UUID] = []
        for i in 0..<60_000 {
            let digest = String(format: "%040x", i)
            let r = row("clip\(i).mov", digest: digest, size: Int64(1_000 + i), seconds: Double(30 + i % 600),
                        volume: "Vol\(i % 7)", archived: i % 11 == 0, date: Date(timeIntervalSince1970: Double(i) * 3_600))
            rows.append(r)
            if i < eventCount * 20 { eventKeys[i / 20].append(r.contentKey) }
            if i % 6 == 0 { sources.append(r.id) }
        }
        for i in 0..<30_000 {
            let src = rows[i * 2]
            if i % 2 == 0 {
                rows.append(row("clip\(i * 2).mov", digest: src.digest, size: src.sizeBytes, seconds: src.durationSeconds, volume: "Backup"))
            } else {
                let g = UUID()
                rows.append(row("dup\(i).mov", dup: g, volume: "Backup"))
                rows.append(row("dup\(i).mov", dup: g, volume: "X9"))
            }
        }
        for (i, src) in sources.prefix(10_000).enumerated() {
            rows.append(row("v\(i).mkv", digest: "v\(i)", from: src, kind: "transcode"))
        }
        while rows.count < 100_000 { rows.append(row("loose\(rows.count).mov")) }
        for (i, keys) in eventKeys.enumerated() { events.append(.init(title: "Event \(i)", contentKeys: keys)) }

        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let index = FootageFolders.index(rows: rows, events: events)
        let indexed = ContinuousClock.now - start
        let open = Set(index.folders.keys)
        let composeStart = ContinuousClock.now
        let display = FootageFolders.compose(index: index, visible: rows.map(\.id), sort: .init(key: .date, ascending: false),
                                             open: open, scope: nil)
        let composed = ContinuousClock.now - composeStart

        #expect(index.folders.count == eventCount)
        #expect(display.folderIDs.count == eventCount)
        #expect(display.rows.count >= 100_000, "every visible row appears (plus a folder row per event)")
        expectWithinTimingBudget("FootageFolders.index 100k rows / 2k events / 30k copies",
                                 measured: indexed, budget: PerformanceLane.debugCeiling(.milliseconds(1_500)), loadBefore: load)
        expectWithinTimingBudget("FootageFolders.compose 100k visible, all folders open",
                                 measured: composed, budget: PerformanceLane.debugCeiling(.milliseconds(1_500)), loadBefore: load)
    }
}

// MARK: - Isolation

@Suite("Footage folders — isolation")
struct FootageFoldersIsolationTests {

    /// A damaged decisions file: the store reads what it can (nothing),
    /// goes read-only, and the join makes no folder — never a crash.
    @MainActor
    @Test func damagedEventsFileMakesNoFoldersAndDoesNotCrash() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VideoScan-tests/folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EventsDecisionStore(directory: dir)
        try Data("{ this is not json".utf8).write(to: store.fileURL)
        _ = await store.load()
        let events = FootageFolders.Event.events(in: store.snapshot())
        #expect(events.isEmpty)
        let a = row("a.mov", digest: "a"), b = row("a.mov", digest: "a", volume: "B")
        let d = FootageFolders.build(rows: [a, b], events: events)
        #expect(d.folderIDs.isEmpty)
        #expect(d.ids == [a.id, b.id], "copies still fold; nothing else moves")
    }

    /// Anything but a Bool under the key reads as OFF.
    @Test func poisonedShowSettingReadsAsOff() throws {
        let suite = "FootageFoldersTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "absent → off")
        defaults.set("yes", forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "a string → off, never on")
        defaults.set(["on": true], forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "a dictionary → off")
        CatalogFootageFoldersSetting.set(true, defaults)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == true, "a real Bool round-trips")
    }

    @MainActor
    @Test func snapshotPublishesOnlyOnChange() async {
        let s = FootageFoldersSnapshot()
        let a = row("a.mov", digest: "a"), b = row("a.mov", digest: "a", volume: "B")
        let index = FootageFolders.index(rows: [a, b], events: [])
        s.publish(index: index)
        s.publish(index: index)
        #expect(s.indexPublishCount == 1)
        s.composeNow(visible: [a.id, b.id], sort: .byName, open: [], scope: nil)
        s.composeNow(visible: [a.id, b.id], sort: .byName, open: [], scope: nil)
        #expect(s.displayPublishCount == 1)
        #expect(s.display.ids == [a.id, b.id])
        s.stop()
        #expect(s.display == .empty)
    }
}

// MARK: - Sensors (source-level)

@Suite("Footage folders — sensors")
struct FootageFoldersSensorTests {

    /// The folder view's file never touches the records array: rows come
    /// from the published display and O(1) id lookups.
    @Test func folderTableNeverReadsRecords() throws {
        let table = try code("CatalogContent+FolderTable.swift")
        #expect(!table.contains("records"), "CatalogContent+FolderTable.swift must not read `records`")
        #expect(!table.contains("tableData.filter"), "no filter pass over the rows in the folder file")
        let snapshot = try code("FootageFoldersSnapshot.swift")
        #expect(snapshot.contains("final class FootageFoldersSnapshot: ObservableObject"))
        #expect(snapshot.contains("guard new != index else { return }"), "index publish is equality-gated")
        #expect(snapshot.contains("guard new != display else { return }"), "display publish is equality-gated")
        #expect(snapshot.contains("Task.detached"), "the join and the compose run off the main actor")
    }

    /// The table observes ONLY the snapshot's display; the rows are built
    /// in that event handler, never in a body.
    @Test func folderRowsObserveOnlyTheSnapshot() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains(".onReceive(folderDisplayPublisher) { rebuildFolderRows($0) }"))
        #expect(table.contains("model.footageFolders.$display"))
        #expect(table.contains("if showFootageFolders {\n            footageFolderTable\n        } else {\n            catalogTableBase\n        }"),
                "off = the linear table, nothing else")
        let folder = try code("CatalogContent+FolderTable.swift")
        #expect(folder.contains("Table(folderRows, selection: $selectedIDs, sortOrder: folderSortBinding)"))
        #expect(!folder.contains("@ObservedObject") && !folder.contains("@EnvironmentObject"),
                "no second observation path into the folder table")
    }

    /// The post-job reveal: every job's derivative enters through the ONE
    /// door, and the Catalog pane observes the landing.
    @Test func everyDerivativeAppendGoesThroughTheOneDoor() throws {
        for job in ["TranscodeJob.swift", "ReformatJob.swift", "TrimJob.swift", "RebuildAudioJob.swift", "CleanupJob.swift"] {
            let src = try code(job)
            #expect(src.contains("model.adoptDerivative(newRec, at:"), "\(job) adopts its derivative through the model")
            #expect(!src.contains("model.records.append(newRec)"), "\(job) no longer appends on its own")
        }
        let model = try code("FootageFoldersSnapshot.swift")
        #expect(model.contains("lastDerivativeLanding = DerivativeLanding(id: newRec.id, sourceID: sourceID"))
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains(".onChange(of: model.lastDerivativeLanding)"))
        let folder = try code("CatalogContent+FolderTable.swift")
        #expect(folder.contains("func revealDerivative(_ landing: DerivativeLanding)"))
        #expect(folder.contains("selectedIDs = [landing.id]"))
        #expect(folder.contains("CatalogTableReveal.scrollSelectionIntoView()"))
    }

    /// The join is kept warm only while the option is on and the pane is
    /// on screen — the linear view pays nothing.
    @Test func joinRunsOnlyWhileWanted() throws {
        let snapshot = try code("FootageFoldersSnapshot.swift")
        #expect(snapshot.contains("guard footageFoldersWanted else { return }"))
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("footageFoldersOptionChanged(on: false)"), "the pane leaving the screen stops the join")
        let model = try code("VideoScanModel.swift")
        #expect(model.contains("scheduleFootageFoldersRefresh()"), "rides the one debounced catalog-change pass")
    }

    /// No key handler on the Table (Rick 2026-10-05); the folder keys ride
    /// the existing NSEvent monitor under the files-table focus rule.
    @Test func folderKeysUseTheMonitorNotATableKeyHandler() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(!table.contains(".onKeyPress"))
        let folder = try code("CatalogContent+FolderTable.swift")
        #expect(!folder.contains(".onKeyPress"))
        #expect(folder.contains("spaceShouldToggleLivePreview()"), "same focus rule as Space")
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("if handleFolderKey(event) { return nil }"))
        #expect(FootageFolderKey(keyCode: 124) == .open)
        #expect(FootageFolderKey(keyCode: 123) == .close)
        #expect(FootageFolderKey(keyCode: 53) == .escape)
        #expect(FootageFolderKey(keyCode: 126) == nil, "↑ is never ours")
    }
}

// MARK: - Structure

@Suite("Footage folders — the Show option and its chrome")
struct FootageFoldersStructureTests {

    @Test func showOptionExistsAndDefaultsOff() throws {
        let toolbar = try code("CatalogToolbar.swift")
        #expect(toolbar.contains("FootageFoldersShowToggle(isOn: $showFootageFolders)"), "the Show menu offers it")
        let toggle = try code("CatalogContent+FolderTable.swift")
        #expect(toggle.contains("Label(FootageFolderWords.showOptionTitle"))
        #expect(FootageFolderWords.showOptionTitle == "Events & Copies as Folders")
        let content = try code("ContentView.swift")
        #expect(content.contains("@State private var showFootageFolders: Bool = CatalogFootageFoldersSetting.isOn()"))
        #expect(content.contains(".onChange(of: showFootageFolders) { CatalogFootageFoldersSetting.set(showFootageFolders) }"),
                "remembered per user")
        #expect(CatalogFootageFoldersSetting.isOn(UserDefaults(suiteName: "FootageFolders-empty-\(UUID())") ?? .standard) == false
                || UserDefaults.standard.object(forKey: CatalogFootageFoldersSetting.key) != nil)
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("var showFootageFolders: Bool = false"), "off unless the parent says otherwise")
    }

    @Test func legendAppearsOnlyWhileOn() throws {
        let helpers = try code("CatalogHelpers.swift")
        let legend = try #require(helpers.range(of: "footageFolderLegend"))
        let guardRange = try #require(helpers.range(of: "if showFootageFolders {", options: .backwards, range: helpers.startIndex..<legend.lowerBound))
        #expect(helpers.distance(from: guardRange.upperBound, to: legend.lowerBound) < 120, "the legend sits directly under the option's guard")
        #expect(FootageFolderWords.legend.contains("↳") && FootageFolderWords.legend.contains("=")
                && FootageFolderWords.legend.contains("⊂") && FootageFolderWords.legend.contains("≈"))
    }

    @Test func showingPillOnlyWhileOn() {
        var s = CatalogShowingSummary.State()
        #expect(!CatalogShowingSummary.pills(for: s).map(\.text).contains(FootageFolderWords.showingPill))
        s.footageFolders = true
        #expect(CatalogShowingSummary.pills(for: s).map(\.text).contains(FootageFolderWords.showingPill))
    }

    @Test func rowMenuItemsOnlyWhileOn() throws {
        let folder = try code("CatalogContent+FolderTable.swift")
        let items = try #require(folder.range(of: "func footageFolderItems(rec: VideoRecord) -> some View {"))
        let body = folder[items.upperBound...].prefix(200)
        #expect(body.contains("if showFootageFolders {"), "the two items add nothing to the row menu while the option is off")
        let organize = try code("CatalogRowContextMenu+Organize.swift")
        #expect(organize.contains("footageFolderItems(rec: rec)"), "they live in the find group")
    }

    @Test func relationGlyphsAndWordsAreTheDesignsFour() {
        #expect(FootageFolders.Relation.madeFrom("x").glyph == "↳")
        #expect(FootageFolders.Relation.copy("x").glyph == "=")
        #expect(FootageFolders.Relation.clip("x").glyph == "⊂")
        #expect(FootageFolders.Relation.sameEvent.glyph == "≈")
        #expect(FootageFolders.Relation.recording.glyph == nil)
        #expect(FootageFolders.Relation.sameEvent.words == "same event · different footage")
        #expect(FootageFolderWords.filesAndCopies(files: 1, copies: 0) == "1 file")
        #expect(FootageFolderWords.filesAndCopies(files: 5, copies: 2) == "5 files · 2 copies")
        #expect(FootageFolderWords.crumb("Thanksgiving 2009") == "‹ All · Thanksgiving 2009")
    }
}
