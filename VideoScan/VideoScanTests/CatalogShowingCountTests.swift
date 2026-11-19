// CatalogShowingCountTests.swift
// The Showing box's last part, "1,247 of 18,903" (Rick 2026-11-18): how many
// files the table lists, of the catalog's not-removed rows.
//
//   LOGIC      both forms ("1,247 of 18,903" / "18,903"), zero shown
//              ("0 of N"), grouping by locale, the VoiceOver words, the box
//              line and tooltip carry it; nil (table not computed yet) draws
//              no count rather than a guess.
//   TRUTH      the count IS the table's rows: from CatalogRows.rows (the one
//              function) across filter / search / person / volume / drive /
//              pairs / held / focus changes, and through the real
//              CatalogContent.computeFiltered — the rows it returns and the
//              count it publishes, in the same call; plus a mounted view with
//              a live search index (the search engine needs the model).
//   SCALE      100k rows: the plain pass with the count stays inside the
//              existing filter budget; the count itself is two Ints.
//   ISOLATION  removed rows never count toward the total; a poisoned held set
//              and an empty catalog.
//   SENSOR     the box, the toolbar and computeFiltered read the count — none
//              walks records for it; the count is the words' size, primary
//              colour, and not clickable.
//   MEDIA      N/A — no media is opened.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Count = CatalogShowingSummary.ShownCount
private let enUS = Locale(identifier: "en_US")

@Suite("Showing box count — words")
struct CatalogShowingCountWordsTests {

    @Test("LOGIC: narrowed reads “1,247 of 18,903”; nothing narrows reads just “18,903”; zero reads “0 of N”")
    func bothForms() {
        #expect(CatalogShowingSummary.countText(Count(shown: 1_247, total: 18_903), locale: enUS) == "1,247 of 18,903")
        #expect(CatalogShowingSummary.countText(Count(shown: 18_903, total: 18_903), locale: enUS) == "18,903")
        #expect(CatalogShowingSummary.countText(Count(shown: 0, total: 18_903), locale: enUS) == "0 of 18,903")
        #expect(CatalogShowingSummary.countText(Count(shown: 0, total: 0), locale: enUS) == "0")
        #expect(CatalogShowingSummary.countText(Count(shown: 7, total: 7), locale: enUS) == "7")
        // Grouping follows the locale (German groups with a dot).
        #expect(CatalogShowingSummary.countText(Count(shown: 1_247, total: 18_903), locale: Locale(identifier: "de_DE"))
                == "1.247 of 18.903")
    }

    @Test("LOGIC: VoiceOver says “1,247 of 18,903 files shown”")
    func accessibilityWords() {
        #expect(CatalogShowingSummary.countAccessibility(Count(shown: 1_247, total: 18_903), locale: enUS)
                == "1,247 of 18,903 files shown")
        #expect(CatalogShowingSummary.countAccessibility(Count(shown: 18_903, total: 18_903), locale: enUS)
                == "18,903 files shown")
        #expect(CatalogShowingSummary.countAccessibility(Count(shown: 1, total: 1), locale: enUS) == "1 file shown")
        #expect(CatalogShowingSummary.countAccessibility(Count(shown: 1, total: 5), locale: enUS) == "1 of 5 files shown")
    }

    @Test("LOGIC: the sentence and tooltip carry the count after the filter words; no count, no number")
    func sentenceAndHelp() {
        var s = CatalogShowingSummary.State(viewFilters: [.videosWithSound], hasMasterArchive: true)
        #expect(!CatalogShowingSummary.sentence(for: s).contains(" of "), "nil = the table has not run: no guess")
        s.shownCount = Count(shown: 0, total: 3)
        let sentence = CatalogShowingSummary.sentence(for: s)
        #expect(sentence.hasPrefix("Showing Including archived, Videos with Sound, Connected drives"))
        #expect(sentence.hasSuffix(", 0 of 3 files shown"))
        #expect(CatalogShowingSummary.help(for: s).contains("0 of 3 files shown."))
        // The words lines are unchanged — the box draws the count after each one.
        #expect(CatalogShowingSummary.boxLines(for: s).first == "Including archived · Videos with Sound · Connected drives")
    }
}

// MARK: - TRUTH (the one function)

@Suite("Showing box count — the table's rows (truth)")
struct CatalogShowingCountTruthTests {

    private func rec(_ name: String, stream: StreamType = .videoAndAudio, volume: String = "T") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/\(volume)/\(name)"
        r.directory = "/Volumes/\(volume)"
        r.streamTypeRaw = stream.rawValue
        return r
    }

    /// A catalog with every narrowing represented, and two removed rows.
    private func catalog() -> [VideoRecord] {
        let beach = rec("beach.mov"), beach2 = rec("beach 2.mov", stream: .videoOnly, volume: "U")
        let song = rec("song.mp3", stream: .audioOnly), lake = rec("lake.mov", volume: "U")
        let dated = rec("dated.mov"); dated.userDate = "1992"; dated.userDateConfidence = "known"
        let gone = rec("beach gone.mov"); gone.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let gone2 = rec("gone.mp3", stream: .audioOnly); gone2.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let donna = rec("donna.mov")
        donna.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        return [beach, beach2, song, lake, dated, gone, gone2, donna]
    }

    @Test("TRUTH: across filter, search, person, volume, drives, pairs, held and focus — shown == the rows listed, total == the not-removed rows")
    func countIsTheRows() {
        let all = catalog()
        let notRemoved = all.filter { $0.purgedAt == nil }.count   // counted here, not by the code under test
        #expect(notRemoved == 6)
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        var steps: [(String, CatalogRows.State)] = [("nothing", s)]
        for f in CatalogViewFilter.allCases { var t = s; t.filters = [f]; steps.append(("filter \(f)", t)) }
        var t = s; t.searchText = "beach"; steps.append(("search", t))
        t.filters = [.audioOnly]; steps.append(("search + Audio Only = 0", t))
        t = s; t.person = CatalogPerson(id: UUID(), name: "Donna", keys: ["donna"]); steps.append(("person", t))
        t = s; t.volumePrefixes = ["/Volumes/U"]; steps.append(("volume", t))
        t = s; t.showDisconnectedMedia = false; t.engines.isReachable = { !$0.hasPrefix("/Volumes/U") }
        steps.append(("connected drives", t))
        t = s; t.showPairsOnly = true; steps.append(("pairs only", t))
        t = s; t.filters = [.needsDate]; t.held = [all[4].id]; steps.append(("held row", t))
        t = s; t.focusIDs = [all[0].id, all[3].id]; steps.append(("focus", t))
        for (name, state) in steps {
            let out = CatalogRows.rows(all, state)
            #expect(out.shownCount.shown == out.rows.count, "\(name)")
            #expect(out.shownCount.total == notRemoved, "\(name): the total is the catalog, not the view")
        }
        // The nothing-narrows case is the bare form; a search is the "of" form.
        #expect(CatalogRows.rows(all, s).shownCount.isEverything)
        var search = s; search.searchText = "beach"
        #expect(CatalogShowingSummary.countText(CatalogRows.rows(all, search).shownCount, locale: enUS) == "2 of 6")
        search.filters = [.audioOnly]
        #expect(CatalogShowingSummary.countText(CatalogRows.rows(all, search).shownCount, locale: enUS) == "0 of 6")
    }

    /// Regression (coordinator 2026-11-18): set-aside and superseded rows are
    /// hidden whatever Rick chooses, yet they were in the total — so a list
    /// with NOTHING narrowing read "N of M", as if a filter hid files.
    @Test("TRUTH: no user narrowing + set-aside + superseded rows ⇒ the bare form; only a user choice makes “of”")
    func alwaysHiddenRowsAreNotInTheTotal() {
        let a = rec("a.mov"), b = rec("b.mov", volume: "U")
        let setAside = rec("still.jpg"); setAside.setAsideReason = "still image"
        let superseded = rec("broken.mov"); superseded.supersededByID = a.id
        let gone = rec("gone.mov"); gone.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let all = [a, b, setAside, superseded, gone]
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        let open = CatalogRows.rows(all, s).shownCount
        #expect(open == Count(shown: 2, total: 2))
        #expect(CatalogShowingSummary.countText(open, locale: enUS) == "2", "nothing narrows: no “of”")
        // Hiding disconnected drives IS a user choice (Show menu, named "Connected drives"):
        // the disconnected row stays in the total.
        s.showDisconnectedMedia = false
        s.engines.isReachable = { !$0.hasPrefix("/Volumes/U") }
        #expect(CatalogShowingSummary.countText(CatalogRows.rows(all, s).shownCount, locale: enUS) == "1 of 2")
        // A focus set reads against the same total.
        s.focusIDs = [a.id]
        #expect(CatalogRows.rows(all, s).shownCount.total == 2)
    }

    @Test("ISOLATION: removed rows never count — even when every row is removed, or the catalog is empty")
    func removedNeverCounts() {
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        let gone = rec("gone.mov"); gone.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(CatalogRows.rows([gone], s).shownCount == Count(shown: 0, total: 0))
        #expect(CatalogRows.rows([], s).shownCount == Count(shown: 0, total: 0))
        // The (app-unused) reveal lists the removed row but the total still excludes it.
        s.showRemoved = true
        #expect(CatalogRows.rows([gone, rec("a.mov")], s).shownCount.total == 1)
        // A poisoned held set adds nothing to either number.
        s.showRemoved = false
        s.held = [UUID(), gone.id]
        #expect(CatalogRows.rows([gone, rec("a.mov")], s).shownCount == Count(shown: 1, total: 1))
    }
}

// MARK: - TRUTH (the real view)

/// Reference cell the view's sink writes into (≈ a C++ `int& out`).
@MainActor private final class CountBox { var value: Count? }

@MainActor
@Suite("Showing box count — computeFiltered publishes the rows it returns (truth)")
struct CatalogShowingCountViewTests {

    private func rec(_ name: String, at dir: URL) -> VideoRecord {
        let r = VideoRecord()
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))   // reachable
        r.fullPath = url.path
        r.filename = name
        r.directory = dir.path
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    private func view(_ records: [VideoRecord], box: CountBox, filters: Set<CatalogViewFilter> = [],
                      person: CatalogPerson? = nil, searchText: String = "") -> CatalogContent {
        CatalogContent(
            records: records,
            selectedIDs: .constant([]),
            focusedPane: FocusState<CatalogPane?>().projectedValue,
            sortOrder: .constant([]),
            searchText: searchText,
            searchHitCount: .constant(0),
            shownCountSink: Binding(get: { box.value }, set: { box.value = $0 }),
            filterTargetPaths: [],
            personFilter: person,
            showPairsOnly: false,
            viewFilters: filters,
            showDisconnectedMedia: false,
            previewImage: nil,
            previewFilename: "",
            previewOfflineVolumeName: nil,
            showInspector: .constant(false),
            onSort: { _ in },
            onSelect: { _ in },
            onClearPreview: {})
    }

    @Test("TRUTH: change a filter or the person → the published count equals the returned rows, in the same call")
    func filterAndPersonChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("count_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = rec("a.mov", at: dir), b = rec("b.mov", at: dir), c = rec("c.mov", at: dir)
        b.userDate = "1992"; b.userDateConfidence = "known"
        c.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        let gone = rec("gone.mov", at: dir); gone.purgedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let all = [a, b, c, gone]
        let box = CountBox()
        let donna = CatalogPerson(id: UUID(), name: "Donna", keys: ["donna"])
        let cases: [(Set<CatalogViewFilter>, CatalogPerson?, Int)] = [
            ([], nil, 3), ([.needsDate], nil, 2), ([.audioOnly], nil, 0), ([], donna, 1), ([.needsDate], donna, 1),
        ]
        for (filters, person, expected) in cases {
            let rows = view(all, box: box, filters: filters, person: person).computeFiltered()
            #expect(rows.count == expected)
            #expect(box.value == Count(shown: rows.count, total: 3), "\(filters) \(person?.name ?? "Everyone")")
        }
    }

    @Test("TRUTH: a search, through the mounted view and the real search index — the box's count is the hits on screen")
    func searchThroughTheMountedView() throws {
        VolumeReachability.invalidateCache()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("count_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = ["beach one.mov", "beach two.mov", "lake.mov", "garden.mov"].map { rec($0, at: dir) }
        let model = VideoScanModel()
        model.records = all
        model.searchIndex.rebuild(records: all)
        let box = CountBox()
        let root = view(all, box: box, searchText: "beach")
            .environmentObject(model)
            .environmentObject(CaptionOrchestrator())
            .environmentObject(MediaFileOperationsCenter())
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderOut(nil)
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && box.value == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        _ = window
        #expect(box.value == Count(shown: 2, total: 4), "two beach files of four")
    }
}

// MARK: - SCALE

@Suite("Showing box count — 100k rows inside the filter budget")
struct CatalogShowingCountScaleTests {

    @Test("SCALE: 100k rows, 1k removed — the pass with the count stays inside the plain-pass budget")
    func hundredThousand() {
        let all: [VideoRecord] = (0..<100_000).map { i in
            let r = VideoRecord()
            r.filename = "clip \(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/clip \(i).mov"
            r.streamTypeRaw = (i % 5 == 0 ? StreamType.audioOnly : StreamType.videoAndAudio).rawValue
            if i % 100 == 0 { r.purgedAt = Date(timeIntervalSince1970: 1_700_000_000) }
            return r
        }
        var s = CatalogRows.State()
        s.showDisconnectedMedia = true
        s.filters = [.audioOnly]
        let t0 = Date()
        let out = CatalogRows.rows(all, s)
        let count = out.shownCount
        let elapsed = Date().timeIntervalSince(t0)
        #expect(count.total == 99_000)
        #expect(count.shown == out.rows.count && count.shown == 20_000 - 1_000)
        // The same 1.0 s ceiling CatalogRowsScaleTests gives the plain pass.
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 1.0), "pass + count took \(elapsed)s")
    }
}

// MARK: - SENSOR

@Suite("Showing box count — read, never recounted (sensor)")
struct CatalogShowingCountSensorTests {

    private func slice(_ src: String, from start: String, to end: String) throws -> String {
        let a = try #require(src.range(of: start))
        let b = try #require(src.range(of: end, range: a.upperBound..<src.endIndex))
        return String(src[a.lowerBound..<b.lowerBound])
    }

    @Test("SENSOR: computeFiltered publishes the pass's count; the toolbar and box only read it")
    func noRecountAnywhere() throws {
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        let compute = try slice(helpers, from: "func computeFiltered(", to: "\n    }\n")
        #expect(compute.contains("result.shownCount"), "the count must come from the same CatalogRows pass")
        let rows = try SourceTree.appCode(named: "CatalogRows.swift")
        #expect(rows.contains("ShownCount(shown: rows.count, total: catalogCount)"))
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        let state = try slice(toolbar, from: "private var showingState:", to: "@ViewBuilder let dashboardContent")
        #expect(state.contains("shownCount: shownCount"))
        for walk in ["records", "tableData", ".filter", ".count"] {
            #expect(!state.contains(walk), "showingState must not compute the count: \(walk)")
        }
    }

    @Test("SENSOR: the count is the words' size, full contrast, and the box stays a readout (no click)")
    func countIsReadableAndInert() throws {
        let src = try SourceTree.appCode(named: "CatalogShowingSummary.swift")
        let box = try slice(src, from: "struct CatalogShowingBox: View {", to: "struct CatalogFilterToken")
        #expect(box.contains("static let font = Font.system(size: fontSize"))
        #expect(box.contains("static let countFont = Font.system(size: fontSize"), "never smaller than the words")
        #expect(!box.contains("foregroundStyle(.secondary)") && !box.contains("foregroundColor(.secondary)"),
                "no grey count (Rick 2026-11-18)")
        #expect(box.contains(".monospacedDigit()"))
        for click in ["Button(", "onTapGesture", "simultaneousGesture", ".gesture("] {
            #expect(!box.contains(click), "the Showing box is a readout: \(click)")
        }
        #expect(!box.contains("records"), "the box reads two Ints, never records")
    }
}
