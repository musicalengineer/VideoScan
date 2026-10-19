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
//   FootageFoldersStructureTests · FootageFoldersSelectionTests

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

    /// codex 2026-10-16 P2: A → transcode B → promoted byte-copy C of B.
    /// C shares B's copy group, so it used to enter the roots, win the
    /// keeper (archived) and turn B into "copy" and A into "same event".
    /// Roots are ORIGINALS: a byte-copy of a derivative inherits the
    /// derivative's place — "= copy" of B, which is "↳ made from" A.
    @Test func aByteCopyOfADerivativeInheritsTheDerivativesPlace() {
        let a = row("tape.dv", digest: "a", size: 9, codec: .original)
        let b = row("tape.mkv", digest: "b", size: 5, from: a.id, kind: "transcode")
        let c = row("tape.mkv", digest: "b", size: 5, from: b.id, kind: "promote", volume: "Archive", archived: true, archiveFile: true)
        let d = FootageFolders.build(rows: [a, b, c], events: [])
        #expect(d.ids == [a.id, b.id, c.id], "the original A keeps the family; the archive's copy of a derivative does not")
        #expect(d.relation(of: b.id) == .madeFrom("made from it · transcode"), "B is made from A")
        #expect(d.relation(of: c.id) == .copy("copy · byte for byte with tape.mkv, Archive"), "C is a copy of B, not a second version of A")
        let e = event("Easter", [a])
        let folded = FootageFolders.build(rows: [c, b, a], events: [e])
        #expect(folded.ids == [e.id, a.id, b.id, c.id], "the same in a folder, whatever the input order")
        #expect(folded.summaries[e.id]?.copies == 1)
    }

    /// codex 2026-10-16 P2: A in E1, its derivative B in E2, an unassigned
    /// C in A's duplicate group. The family vote (1 : 1, UUID tie) could
    /// send C to E2; a copy follows ITS OWN copy group's assigned member
    /// first — C's group is A's, so C is in E1.
    @Test func anUnassignedCopyFollowsItsOwnCopyGroupsEvent() throws {
        let g = UUID()
        let a = row("a.mov", dup: g), b = row("a.mkv", digest: "b", from: a.id, kind: "transcode"), c = row("a.mov", dup: g, volume: "Backup")
        // E2's id sorts first, so a tied vote would pick E2 under the old rule.
        let e1 = event("One", [a], id: try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")))
        let e2 = event("Two", [b], id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        let index = FootageFolders.index(rows: [a, b, c], events: [e1, e2])
        #expect(index.folderOf[a.id] == e1.id && index.folderOf[b.id] == e2.id, "own events are kept")
        #expect(index.folderOf[c.id] == e1.id, "C follows its copy group (A's) into E1, never the tie-break")
        #expect(index.family(of: c.id)?.keeper == a.id)
        // A member whose copy group has NO assigned member still follows the family's vote.
        let d = row("a.vs.edit.mov", digest: "d", from: a.id, kind: "editing")
        let a2 = row("a2.mov", digest: "a2", from: a.id, kind: "trim")
        let majority = FootageFolders.index(rows: [a, b, c, d, a2], events: [event("One", [a, a2], id: e1.id), e2])
        #expect(majority.folderOf[d.id] == e1.id, "no copy-group mate with an event: the family's majority (E1, 2 : 1)")
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

    /// codex 2026-10-16 P2: a stored NUMBER bridges to Bool through NSNumber
    /// (`1 as? Bool == true`), so a poisoned 1 turned the folders on. Only
    /// a plist boolean reads as on; 1, 1.0, "true" and [true] read as off.
    @Test func onlyAPlistBooleanReadsAsOn() throws {
        let suite = "FootageFoldersTests-strict-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "the integer 1 → off")
        defaults.set("true", forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "the string \"true\" → off")
        defaults.set(1.0, forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "the double 1.0 → off")
        defaults.set([true], forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "an array holding true → off")
        defaults.set(true, forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == true, "a plist boolean true → on")
        defaults.set(false, forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFootageFoldersSetting.isOn(defaults) == false, "a plist boolean false → off")
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
        #expect(folder.contains("Table(of: FootageFolderTableRow.self, selection: $selectedIDs, sortOrder: folderSortBinding)"))
        #expect(folder.contains("ForEach(folderRows) { row in"), "the rows are the event handler's folderRows")
        #expect(folder.contains("DisclosureTableRow(row, isExpanded: folderExpansion(row.id))"),
                "a folder twists open in place through the table's own expansion state")
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
        #expect(FootageFolderKey(keyCode: 124) == nil, "bare → is the outline's twist-open (2026-10-18)")
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

// MARK: - Selection (codex 2026-10-16 P1: a hidden selection must never reach a row action)

@Suite("Footage folders — a hidden selection never reaches ⌘⌫, Promote or the row menu")
struct FootageFoldersSelectionTests {

    /// Every row action takes `selection ∩ displayed` through ONE accessor —
    /// never the raw selection, never `tableData` alone (which is pre-scope).
    @Test func everyRowActionGoesThroughTheDisplayedSelection() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(!table.contains("tableData.filter { selectedIDs.contains($0.id) }"), "⌘⌫ no longer filters the raw selection")
        #expect(table.contains("let targets = displayedSelectedRecords"), "⌘⌫ trashes the displayed selection")
        #expect(!table.contains("CatalogPromoteScope.recordIDs(selection: selectedIDs"), "Promote no longer reads the raw selection")
        #expect(table.contains("CatalogPromoteScope.recordIDs(selection: displayedSelection, visibleRows: tableData)"))
        #expect(!table.contains("openRows(ids: selectedIDs"), "⌘O no longer opens the raw selection")
        #expect(table.contains("openRows(ids: displayedSelection"))
        let menu = try code("CatalogRowContextMenu.swift")
        #expect(menu.contains("let shown = displayedIDs(among: ids)"), "the row menu (Transcode, Verify, Analyze, Move to Trash…) sees only rows on screen")
        let folder = try code("CatalogContent+FolderTable.swift")
        #expect(folder.contains("openRows(ids: displayedIDs(among: ids)"), "Return / double-click opens only rows on screen")
    }

    /// The reveal asks the display before it selects; a row the filter or
    /// the scope would not show is never selected.
    @Test func theRevealChecksTheDisplayBeforeSelecting() throws {
        let folder = try code("CatalogContent+FolderTable.swift")
        let reveal = try #require(folder.range(of: "func revealDerivative(_ landing: DerivativeLanding)"))
        let select = try #require(folder.range(of: "selectedIDs = [landing.id]"))
        let between = folder[reveal.upperBound..<select.lowerBound]
        #expect(between.contains("DerivativeReveal.plan("), "the plan comes before any selection")
        #expect(folder.contains("tableState.folderRecordIDs = "), "the folder rows publish the displayed record ids")
        #expect(folder.contains("pruneSelectionToDisplay()"), "every display change prunes the selection against what it shows")
    }

    // Two events, one file each, plus a derivative of A that just landed
    // (the index does not know it yet — exactly the reveal's moment).
    private struct Stage {
        let a = VideoRecord(), b = VideoRecord(), d = VideoRecord()
        let rowA: Row, rowB: Row
        let eventA: FootageFolders.Event, eventB: FootageFolders.Event
        let index: FootageFolders.Index
        var tableData: [VideoRecord] { [a, b, d] }

        init() {
            rowA = row("a.mov", digest: "a", id: a.id)
            rowB = row("b.mov", digest: "b", id: b.id)
            eventA = event("A", [rowA])
            eventB = event("B", [rowB])
            index = FootageFolders.index(rows: [rowA, rowB], events: [eventA, eventB])
        }

        /// What the folder table shows under `scope` (all folders open).
        func displayed(scope: FootageFolders.Scope?) -> Set<UUID> {
            let d = FootageFolders.compose(index: index, visible: tableData.map(\.id), sort: .byName,
                                           open: [eventA.id, eventB.id], scope: scope)
            return Set(d.rows.compactMap(\.recordID))
        }

        func landing() -> DerivativeLanding {
            DerivativeLanding(id: d.id, sourceID: a.id, kind: "transcode", at: Date())
        }
    }

    /// The codex scenario: scoped to event B while a transcode from event A
    /// runs; its derivative lands → NOT selected, and ⌘⌫'s target set is empty.
    @Test func derivativeFromAnotherEventLandsUnselectedWhileScopedElsewhere() {
        let s = Stage()
        let scope = FootageFolders.Scope.event(s.eventB.id)
        let plan = DerivativeReveal.plan(landing: s.landing(), inTable: true, foldersOn: true, scope: scope, index: s.index)
        #expect(plan == .outsideScope, "the reveal leaves the selection alone and only logs")
        // Even if something DID select it, no row action can reach it.
        let shown = CatalogSelectionPrune.displayed([s.d.id], foldersOn: true,
                                                    folderRecordIDs: s.displayed(scope: scope), rows: s.tableData)
        #expect(shown.isEmpty, "the derivative is not on screen under scope B")
        #expect(s.tableData.filter { shown.contains($0.id) }.isEmpty, "⌘⌫'s target set is empty")
        #expect(CatalogPromoteScope.recordIDs(selection: shown, visibleRows: s.tableData).isEmpty, "Promote sees nothing")
    }

    /// A scoped view's bulk action never sees members outside the scope.
    @Test func scopedBulkActionNeverSeesMembersOutsideTheScope() {
        let s = Stage()
        let selection: Set<UUID> = [s.a.id, s.b.id]
        let inA = CatalogSelectionPrune.displayed(selection, foldersOn: true,
                                                  folderRecordIDs: s.displayed(scope: .event(s.eventA.id)), rows: s.tableData)
        #expect(inA == [s.a.id], "scoped to A: only A, although B is selected too")
        let unscoped = CatalogSelectionPrune.displayed(selection, foldersOn: true,
                                                       folderRecordIDs: s.displayed(scope: nil), rows: s.tableData)
        #expect(unscoped == selection, "no scope: both")
        let family = CatalogSelectionPrune.displayed(selection, foldersOn: true,
                                                     folderRecordIDs: s.displayed(scope: .family(s.b.id)), rows: s.tableData)
        #expect(family == [s.b.id], "Show Copies & Related… on B: only B")
    }

    /// Pruning after a scope change drops the ids the scope hid; a selected
    /// folder row survives (it is not a record).
    @Test func pruningAfterAScopeChangeDropsHiddenIDs() {
        let s = Stage()
        let selection: Set<UUID> = [s.a.id, s.b.id, s.eventB.id]
        let kept = CatalogSelectionPrune.displayed(selection, foldersOn: true,
                                                   folderRecordIDs: s.displayed(scope: .event(s.eventB.id)), rows: s.tableData)
            .union(selection.intersection([s.eventA.id, s.eventB.id]))
        #expect(kept == [s.b.id, s.eventB.id], "A is hidden by the scope and dropped; B and the folder row stay")
    }

    /// The option OFF path still prunes against the linear rows, and the
    /// folder set — stale or not — is ignored.
    @Test func optionOffStillPrunesAgainstTheLinearRows() {
        let s = Stage()
        let stray = UUID()
        let kept = CatalogSelectionPrune.displayed([s.a.id, stray], foldersOn: false,
                                                   folderRecordIDs: [stray], rows: [s.a])
        #expect(kept == [s.a.id], "off: a row is a row; an id that is not a row is dropped even if a stale folder set lists it")
        #expect(CatalogSelectionPrune.displayed([], foldersOn: false, folderRecordIDs: [], rows: s.tableData).isEmpty)
        // On, the folder set and the rows both have to agree (the compose is asynchronous).
        let lagging = CatalogSelectionPrune.displayed([s.a.id, s.b.id], foldersOn: true,
                                                      folderRecordIDs: [s.a.id, s.b.id], rows: [s.a])
        #expect(lagging == [s.a.id], "on: a display that lags the rows can never widen the set")
    }

    /// The reveal's four answers.
    @Test func revealPlanSelectsOnlyWhatTheListCanShow() {
        let s = Stage()
        let landing = s.landing()
        #expect(DerivativeReveal.plan(landing: landing, inTable: false, foldersOn: false, scope: nil, index: s.index) == .hiddenByFilter)
        #expect(DerivativeReveal.plan(landing: landing, inTable: false, foldersOn: true, scope: .event(s.eventA.id), index: s.index) == .hiddenByFilter,
                "a filter that hides it wins over any scope")
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: false, scope: nil, index: s.index) == .select, "option off: the linear table shows it")
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: nil, index: s.index) == .select, "no scope: loose until the join places it")
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: .event(s.eventA.id), index: s.index) == .openScopeAndSelect,
                "scoped to the source's own event: clear the scope, open the folder, select")
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: .event(s.eventB.id), index: s.index) == .outsideScope)
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: .family(s.a.id), index: s.index) == .openScopeAndSelect,
                "Show Copies & Related… on the source: the same")
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: .family(s.b.id), index: s.index) == .outsideScope)
        // Once the join has placed the row in the scoped event, it is simply selected.
        let rowD = row("a.mkv", digest: "d", from: s.a.id, kind: "transcode", id: s.d.id)
        let placed = FootageFolders.index(rows: [s.rowA, s.rowB, rowD], events: [s.eventA, s.eventB])
        #expect(DerivativeReveal.plan(landing: landing, inTable: true, foldersOn: true, scope: .event(s.eventA.id), index: placed) == .select)
    }
}

// MARK: - A folder's own title is searchable (2026-10-19)
//
// A folder's own title is searchable (Rick 2026-10-19): with Show ▸ As
// folders on, "thanksgiving" in any case shows the "Thanksgiving · 1984"
// folder with its visible members, even when no member's own fields
// carry the word.
//
// Five dimensions: Logic (title rule, casing, NFC, what never answers by
// title, hits-first union) · Scale (100k rows / 2k folders) · Media matrix
// N/A (no file is opened) · Isolation N/A (pure values; no global state) ·
// Sensor (computeFiltered adds the titled folders' members; a late join
// re-runs the filter).

private let titleCasings = ["Thanksgiving", "thanksgiving", "THANKSGIVING", "tHANKSgiving"]


private func folderRow(_ name: String, id: UUID = UUID()) -> FootageFolders.Row {
    FootageFolders.Row(id: id, sizeBytes: 1_000, durationSeconds: 60, volume: "LaCie",
                       keys: FootageFolders.SortKeys(filename: name, volume: "LaCie", duration: 60, size: 1_000))
}

@MainActor
@Suite("Footage folders — a folder's title is searchable")
struct FootageFolderTitleSearchTests {

    @Test func titleAnswersInEveryCasing() {
        let a = folderRow("Tape12.dv"), b = folderRow("Tape13.dv")
        let e = FootageFolders.Event(title: "Thanksgiving · 1984", contentKeys: [a.contentKey, b.contentKey])
        let index = FootageFolders.index(rows: [a, b], events: [e])
        for q in titleCasings + ["thanks", "1984", "thanksgiving 1984", "1984 THANKSGIVING", "\"thanksgiving · 1984\""] {
            #expect(FootageFolderTitleSearch.folderIDs(answering: q, in: index) == [e.id], "\(q)")
            #expect(FootageFolderTitleSearch.memberIDs(answering: q, in: index) == [a.id, b.id], "\(q)")
        }
    }

    @Test func otherQueriesDoNotAnswerByTitle() {
        let a = folderRow("Tape12.dv")
        let e = FootageFolders.Event(title: "Thanksgiving · 1984", contentKeys: [a.contentKey])
        let index = FootageFolders.index(rows: [a], events: [e])
        for q in ["", "   ", "christmas", "thanksgiving christmas", "1980s", "year:1984", "tag:thanksgiving", "people:thanksgiving"] {
            #expect(FootageFolderTitleSearch.folderIDs(answering: q, in: index).isEmpty, "\"\(q)\" is about the files, not the name")
        }
        #expect(FootageFolderTitleSearch.folderIDs(answering: "thanksgiving", in: .empty).isEmpty)
    }

    /// Accents: an NFD title (as macOS file names arrive) matches an NFC query.
    @Test func decomposedTitleMatchesComposedQuery() {
        let a = folderRow("x.mov")
        let e = FootageFolders.Event(title: "Cafe\u{301} Night", contentKeys: [a.contentKey])
        let index = FootageFolders.index(rows: [a], events: [e])
        #expect(FootageFolderTitleSearch.folderIDs(answering: "CAFÉ", in: index) == [e.id])
    }

    /// The members join the hits; the hits keep their order; nothing the
    /// view's filters removed (absent from the candidates) comes back.
    @Test func addingKeepsHitsFirstAndNeverResurrectsAFilteredRow() {
        func rec(_ n: String) -> VideoRecord { let r = VideoRecord(); r.fullPath = "/V/\(n)"; r.filename = n; return r }
        let hit1 = rec("h1"), hit2 = rec("h2"), member = rec("m"), hidden = rec("gone")
        let out = FootageFolderTitleSearch.adding(folderMembers: [member.id, hit2.id, hidden.id],
                                                  from: [hit1, member, hit2], to: [hit2, hit1])
        #expect(out.map(\.id) == [hit2.id, hit1.id, member.id])
        #expect(FootageFolderTitleSearch.adding(folderMembers: [], from: [member], to: [hit1]).map(\.id) == [hit1.id])
    }

    /// End to end through the join: the lowercase word shows the folder
    /// with ALL its visible members although no member's own fields carry it.
    @Test func lowercaseWordShowsTheFolderWithItsMembers() {
        let tape12 = VideoRecord(), tape13 = VideoRecord(), other = VideoRecord()
        for (r, n) in [(tape12, "Tape12.dv"), (tape13, "Tape13.dv"), (other, "Beach.mov")] {
            r.fullPath = "/Volumes/FamilyArchive/\(n)"
            r.filename = n
            r.directory = "/Volumes/FamilyArchive"
        }
        let records = [tape12, tape13, other]
        let rows = records.map { FootageFolders.Row(id: $0.id, keys: FootageFolders.SortKeys(filename: $0.filename)) }
        let e = FootageFolders.Event(title: "Thanksgiving · 1984", contentKeys: [rows[0].contentKey, rows[1].contentKey])
        let index = FootageFolders.index(rows: rows, events: [e])
        let search = CatalogSearchIndex()
        search.rebuild(records: records)
        for q in titleCasings {
            let hits = search.filter(records: records, query: q)
            #expect(hits.isEmpty, "no member's own field says thanksgiving")
            let shown = FootageFolderTitleSearch.adding(
                folderMembers: FootageFolderTitleSearch.memberIDs(answering: q, in: index), from: records, to: hits)
            let display = FootageFolders.compose(index: index, visible: shown.map(\.id), sort: .byName,
                                                 open: [e.id], scope: nil)
            #expect(display.rows.compactMap(\.eventID) == [e.id], "the folder shows for \"\(q)\"")
            #expect(Set(display.rows.compactMap(\.recordID)) == [tape12.id, tape13.id], "with both members, not Beach")
        }
    }

    /// Sensor: the catalog's filter pass adds the titled folders' members
    /// only while the folder view is on, from the search's own input.
    @Test func computeFilteredAddsTitledFolderMembers() throws {
        let helpers = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogHelpers.swift"))
        #expect(helpers.contains("FootageFolderTitleSearch.memberIDs(answering: searchText, in: model.footageFolders.index)"))
        #expect(helpers.contains("FootageFolderTitleSearch.adding(folderMembers:"))
        let table = try SourceTree.strippingComments(SourceTree.appSource(named: "CatalogContent+Table.swift"))
        #expect(table.contains(".onReceive(folderIndexPublisher.dropFirst())"), "a join that lands after the query re-runs the filter")
    }

    /// Scale: 100k rows, 2k folders — the title pass is cheap.
    @Test func titleSearchAtScale() {
        var rows: [FootageFolders.Row] = []
        rows.reserveCapacity(100_000)
        var events: [FootageFolders.Event] = []
        for i in 0..<100_000 { rows.append(FootageFolders.Row(digest: String(format: "%040x", i))) }
        for f in 0..<2_000 {
            let keys = (0..<20).map { rows[f * 20 + $0].contentKey }
            events.append(.init(title: f % 100 == 0 ? "Thanksgiving \(1900 + f / 10)" : "Event \(f)", contentKeys: keys))
        }
        let index = FootageFolders.index(rows: rows, events: events)
        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let ids = FootageFolderTitleSearch.memberIDs(answering: "THANKSGIVING", in: index)
        let elapsed = ContinuousClock.now - start
        #expect(ids.count == 20 * 20, "20 titled folders × 20 members")
        expectWithinTimingBudget("FootageFolderTitleSearch.memberIDs 2k folders",
                                 measured: elapsed, budget: PerformanceLane.debugCeiling(.milliseconds(50)), loadBefore: load)
    }
}
