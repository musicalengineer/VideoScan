// CatalogShowingSummaryTests.swift
// LOGIC + TRUTH + ISOLATION + SCALE for the "Showing: …" row (2026-08-22;
// reworked 2026-11-17 after the Show-filters audit): the one vocabulary the
// menu and the box share, pill order, the lines the box may draw (none of
// them hides a filter), the tooltip, the empty-table note, and the
// archived-hits split behind "Show in Archive".
// Pure functions over constructed values — no UserDefaults, no model. (The
// filter set's persistence is the store's: CatalogShowFilterStoreTests.)

import Foundation
import Testing
@testable import VideoScan

@Suite("Showing row — vocabulary and pills")
struct CatalogShowingSummaryTests {

    private func texts(_ s: CatalogShowingSummary.State) -> [String] {
        CatalogShowingSummary.pills(for: s).map(\.text)
    }

    /// Every subset of the Show filters (2^6 = 64).
    private var everyFilterSet: [Set<CatalogViewFilter>] {
        let all = CatalogViewFilter.allCases
        return (0..<(1 << all.count)).map { mask in
            Set(all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
        }
    }

    @Test func defaultWithoutMasterArchiveSaysVideosOnConnectedDrives() {
        let s = CatalogShowingSummary.State()
        #expect(texts(s) == ["Videos", "Connected drives"])
        #expect(CatalogShowingSummary.sentence(for: s) == "Showing Videos, Connected drives")
    }

    @Test func masterArchiveAddsTheArchivePillInTheSecondSlot() {
        var s = CatalogShowingSummary.State(hasMasterArchive: true)
        #expect(texts(s) == ["Videos", "Including archived", "Connected drives"])
        s.viewFilters = [.notYetArchived]
        #expect(texts(s) == ["Videos", "Not Yet Archived", "Connected drives"])
        s.viewFilters = [.hasMasterCopy]
        #expect(texts(s) == ["Videos", "Has Master Copy", "Connected drives"])
    }

    @Test func theToDoPillIsTheOnlyGreenOneAndNoBoxPillIsAButton() {
        let s = CatalogShowingSummary.State(viewFilters: [.notYetArchived, .needsDate],
                                            hasMasterArchive: true)
        let pills = CatalogShowingSummary.pills(for: s)
        #expect(pills.filter { $0.emphasis == .archiveToDo }.map(\.text) == ["Not Yet Archived"])
        // The box is a readout (2026-11-17): a click on it used to flip a filter.
        for filters in everyFilterSet {
            for pill in CatalogShowingSummary.boxPills(for: .init(viewFilters: filters, hasMasterArchive: true)) {
                #expect(pill.action == CatalogShowingSummary.Pill.Action.none, "\(pill.text) acts on a click")
            }
        }
    }

    @Test("TRUTH: the box and the menu use the same words for every filter")
    func oneVocabulary() {
        for f in CatalogViewFilter.allCases {
            #expect(CatalogShowingSummary.words(for: f) == f.title)
            #expect(!f.title.isEmpty)
            let s = CatalogShowingSummary.State(viewFilters: [f])
            #expect(CatalogShowingSummary.boxPills(for: s).map(\.text).contains(f.title))
        }
        for k in CatalogKindFacet.allCases {
            #expect(!CatalogShowingSummary.words(for: k).isEmpty)
        }
    }

    @Test("TRUTH: the box names exactly the filters that are on — every subset, Master Archive or not",
          arguments: [true, false])
    func theBoxNamesExactlyTheActiveSet(hasMasterArchive: Bool) {
        let every = Set(CatalogViewFilter.allCases.map(\.title))
        for filters in everyFilterSet {
            let s = CatalogShowingSummary.State(viewFilters: filters, hasMasterArchive: hasMasterArchive)
            let named = Set(CatalogShowingSummary.boxPills(for: s).map(\.text)).intersection(every)
            #expect(named == Set(filters.map(\.title)), "on: \(filters) — the box names \(named)")
            #expect(Set(CatalogShowingSummary.filterPills(for: filters).map(\.text)) == Set(filters.map(\.title)))
            // "Including archived" is said only when it is true: a Master
            // Archive exists and neither archive filter is on.
            let saysIncluding = CatalogShowingSummary.boxPills(for: s).contains { $0.text == CatalogShowingSummary.includingArchived }
            #expect(saysIncluding == (hasMasterArchive && !filters.contains(.notYetArchived) && !filters.contains(.hasMasterCopy)))
            // The tooltip carries every name, whatever line is drawn.
            let help = CatalogShowingSummary.help(for: s)
            for f in filters { #expect(help.contains(f.title)) }
            #expect(help.contains("No Show filter is on.") == filters.isEmpty)
        }
    }

    @Test("TRUTH: no line the box may draw hides a filter — it names each one or counts them")
    func noLineHidesAFilter() {
        for filters in everyFilterSet {
            var s = CatalogShowingSummary.State(viewFilters: filters, hasMasterArchive: true)
            s.showPairsOnly = true
            let lines = CatalogShowingSummary.boxLines(for: s)
            let names = CatalogShowingSummary.filterPills(for: filters).map(\.text)
            #expect(!lines.isEmpty && Set(lines).count == lines.count)
            #expect(lines.first == CatalogShowingSummary.boxPills(for: s).map(\.text).joined(separator: " · "))
            for line in lines {
                let namesAll = names.allSatisfy(line.contains)
                let countsRest = names.count > 1
                    && (line.contains("+\(names.count - 1) more") && line.contains(names[0]) || line == "\(names.count) filters on")
                let countsOne = names.count == 1 && line == "1 filter on"
                #expect(namesAll || countsRest || countsOne, "\(line) hides a filter of \(names)")
            }
            // Longest first, so the first that fits says the most.
            #expect(lines == lines.sorted { $0.count > $1.count })
        }
        let none = CatalogShowingSummary.boxLines(for: .init())
        #expect(none == ["Videos · Connected drives", "Videos"])
        let three = CatalogShowingSummary.boxLines(for: .init(viewFilters: [.notYetArchived, .needsDate, .unpairedOnly]))
        #expect(three == ["Videos · Not Yet Archived · Unpaired Only · Needs a Date · Connected drives",
                          "Videos · Not Yet Archived +2 more", "3 filters on"])
    }

    @Test func kitchenSinkReadsInFixedOrder() {
        let s = CatalogShowingSummary.State(
            kindFacet: .everything,
            viewFilters: [.notYetArchived, .needsDate, .unpairedOnly],
            showPairsOnly: true, showDisconnectedMedia: true,
            hasMasterArchive: true)
        #expect(texts(s) == [
            "All kinds", "Not Yet Archived", "Unpaired Only", "Needs a Date", "Pairs only", "All drives",
        ])
    }

    @Test("TRUTH: a focus set replaces every pill — the filters are not in force and are not listed")
    func focusModeReplacesEveryPill() {
        let s = CatalogShowingSummary.State(viewFilters: [.notYetArchived, .needsDate],
                                            hasMasterArchive: true,
                                            focusLabel: "A/V Pair focus")
        #expect(texts(s) == ["A/V Pair focus"])
        #expect(CatalogShowingSummary.boxLines(for: s) == ["A/V Pair focus"])
        let help = CatalogShowingSummary.help(for: s)
        #expect(help.contains("A/V Pair focus") && help.contains("The Show filters are not applied"))
        #expect(!help.contains("Needs a Date"), "a filter that is not in force is not listed as on")
    }

    // MARK: The empty table

    @Test("LOGIC: a table emptied by Show filters alone says so (it used to be a blank pane)")
    func emptyTableFromFiltersAloneIsNotBlank() {
        typealias Note = CatalogEmptyNote
        #expect(Note.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false,
                          personChosen: false, filtersActive: true) == .filtered)
        #expect(Note.pick(rowsEmpty: false, searching: false, foldersOnlyFindsNothing: false,
                          personChosen: false, filtersActive: true) == Note.none, "rows are listed — no note")
        #expect(Note.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false) == Note.none,
                "nothing narrows the table: an empty catalog draws no filter note")
        // The search's own "No matches" and Folders Only's line still win; the person line follows the filters.
        #expect(Note.pick(rowsEmpty: true, searching: true, foldersOnlyFindsNothing: false, filtersActive: true) == .noMatches)
        #expect(Note.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: true, filtersActive: true) == .noFolders)
        #expect(Note.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false,
                          personChosen: true, filtersActive: true) == .filtered)
        #expect(Note.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false, personChosen: true) == .noPerson)
        // The words name the filters, in the menu's words, and the action has one title.
        #expect(CatalogShowingSummary.filteredEmptyNote(filters: [.needsDate])
                    == "No files match the Show filter that is on: Needs a Date.")
        #expect(CatalogShowingSummary.filteredEmptyNote(filters: [.needsDate, .notYetArchived])
                    == "No files match the Show filters that are on: Not Yet Archived, Needs a Date.")
        #expect(CatalogShowingSummary.clearAllFiltersTitle == "Clear All Filters")
    }

    // MARK: Archived-hits split

    private func rec(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    @Test func splitKeepsOrderAndCountsBothSides() {
        let recs = (0..<10).map { rec("v\($0).mov") }
        let archivedNames: Set<String> = ["v1.mov", "v4.mov", "v9.mov"]
        let split = CatalogShowingSummary.splitArchivedHits(recs) { archivedNames.contains($0.filename) }
        #expect(split.shown.map(\.filename) == ["v0.mov", "v2.mov", "v3.mov", "v5.mov", "v6.mov", "v7.mov", "v8.mov"])
        #expect(split.archived.map(\.filename) == ["v1.mov", "v4.mov", "v9.mov"])
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 1) == "1 match is already in the Archive.")
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 3) == "3 matches are already in the Archive.")
    }

    /// Scale (checklist dimension 2): the split runs inside the
    /// catalog's search pass, so 100k records must stay well under the
    /// per-keystroke budget.
    @Test func splitOf100kStaysUnderBudget() {
        let recs = (0..<100_000).map { rec("v\($0).mov") }
        let t0 = Date()
        let split = CatalogShowingSummary.splitArchivedHits(recs) { $0.filename.hasSuffix("7.mov") }
        let elapsed = Date().timeIntervalSince(t0)
        #expect(split.archived.count == 10_000)
        #expect(split.shown.count == 90_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 0.5), "split took \(elapsed)s for 100k records")
    }
}
