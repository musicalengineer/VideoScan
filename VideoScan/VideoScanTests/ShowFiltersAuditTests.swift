// ShowFiltersAuditTests.swift
// The Catalog ▸ Show filters audit of 2026-11-17 (a row vanished under a filter
// Rick had not knowingly set). These are the audit's red tests, adopted: each
// was RED on main @ d30f72373 and names the finding it pins. The store, the
// rows function and the trimmed menu have their own suites
// (CatalogShowFilterStoreTests.swift, CatalogRowsTests.swift).
//
//   F3  a table emptied by filters alone drew a blank pane
//   F5  the Showing box omitted or misstated filters (no Master Archive, focus
//       mode, one truncating Text; the "both archive filters" case left with
//       Has Master Copy on 2026-11-17)
//   F6  filters changed without the Show menu (a tap on the box; the Steward
//       and ContentView writing the defaults key themselves)
//   F1  a single-record edit did not refresh the table

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Show filters — the Showing box names what is in force (audit 2026-11-17)")
struct ShowFiltersShowingBoxAuditTests {

    private func texts(_ s: CatalogShowingSummary.State) -> [String] {
        CatalogShowingSummary.boxPills(for: s).map(\.text)
    }

    // F5 — with no Master Archive designated the archive pill was skipped AND
    // the loop skipped the archive pair, while the filter pass still applied
    // both: an active filter with no name.
    @Test("TRUTH: every active Show filter is named in the Showing box, Master Archive or not",
          arguments: [true, false])
    func everyActiveFilterIsNamed(hasMasterArchive: Bool) {
        for f in CatalogViewFilter.allCases {
            let s = CatalogShowingSummary.State(viewFilters: [f], hasMasterArchive: hasMasterArchive)
            #expect(texts(s).contains(CatalogShowingSummary.words(for: f)),
                    "\(f) is on but the box reads: \(texts(s)) (hasMasterArchive: \(hasMasterArchive))")
        }
    }

    // DECISIONS 2026-11-17 ("final shape for now"): no filter ticked means
    // everything is shown, and the Showing box says so.
    @Test("TRUTH: no filter on — the box says Everything; any filter on — it never does", arguments: [true, false])
    func noFilterMeansEverything(hasMasterArchive: Bool) {
        let none = CatalogShowingSummary.State(hasMasterArchive: hasMasterArchive)
        #expect(texts(none).first == CatalogShowingSummary.everything)
        #expect(CatalogShowingSummary.everything == "Everything")
        for f in CatalogViewFilter.allCases {
            let s = CatalogShowingSummary.State(viewFilters: [f], hasMasterArchive: hasMasterArchive)
            #expect(!texts(s).contains(CatalogShowingSummary.everything), "\(f) is on but the box says Everything")
        }
        // The two view switches that drop rows are not "everything" either.
        var pairs = none
        pairs.showPairsOnly = true
        #expect(!texts(pairs).contains(CatalogShowingSummary.everything))
        var folders = none
        folders.footageFolders = true
        #expect(texts(folders).contains(CatalogShowingSummary.everything), "As folders lists every file, in folders")
        folders.foldersOnly = true
        #expect(!texts(folders).contains(CatalogShowingSummary.everything), "Folders Only leaves the loose files out")
    }
}

@Suite("Show filters — one store, no side doors (audit 2026-11-17 sensor)")
struct ShowFiltersAuditSensorTests {

    /// Every Swift file of the app target, comments stripped: (file name, code).
    private func appFiles() throws -> [(name: String, code: String)] {
        var out: [(String, String)] = []
        for source in SourceTree.appSources {
            let text = try String(contentsOf: source.url, encoding: .utf8)
            out.append((source.url.lastPathComponent, SourceTree.strippingComments(text)))
        }
        #expect(out.count > 200, "the walk found \(out.count) files — it is not reading the app target")
        return out
    }

    // F6 — ContentView (@AppStorage) and the Steward (defaults.set) each wrote
    // the persisted set themselves, unlogged.
    @Test("SENSOR: only the store's file names the persisted Show-filter keys")
    func onlyTheStoreTouchesThePersistedKeys() throws {
        let offenders = try appFiles()
            .filter { $0.code.contains("catalog.viewFilters") || $0.code.contains("catalog.showFilters") }
            .map(\.name)
        #expect(offenders == ["CatalogShowFilterStore.swift"],
                "the Show-filter keys are read or written outside the store: \(offenders)")
    }

    // Owner ruling 2026-11-17: the Show ▸ hidden-records panel is gone. A
    // stored reveal must not survive it, and nothing may read one.
    @Test("SENSOR: no view reads or offers a hidden-records reveal")
    func theHiddenRecordRevealsAreGone() throws {
        for file in try appFiles() where file.name != "CatalogShowFilterStore.swift" {
            #expect(!file.code.contains("catalogShowRemoved") && !file.code.contains("catalogShowSetAside"),
                    "\(file.name) still names a retired reveal setting")
        }
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        for gone in ["hidden records", "showRemoved", "showSetAside", "showSuperseded", "Superseded originals"] {
            #expect(!toolbar.contains(gone), "the Show menu still carries \(gone)")
        }
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        for gone in ["state.showRemoved", "state.showSetAside", "state.showSuperseded"] {
            #expect(!helpers.contains(gone), "computeFiltered can still reveal hidden rows (\(gone))")
        }
        let summary = try SourceTree.appCode(named: "CatalogShowingSummary.swift")
        for gone in ["Plus removed files", "Plus set-aside files", "Plus replaced originals"] {
            #expect(!summary.contains(gone))
        }
    }

    // MARK: The five-tick menu (DECISIONS 2026-11-17, "final shape for now")

    // The media-kind section (Videos / Audio Only / All Kinds) was a second
    // control over what is listed, with its own stored key and no log line.
    @Test("SENSOR: there is no second media-kind control — no facet type, no facet state, no picker section")
    func noSecondKindControl() throws {
        for file in try appFiles() {
            #expect(!file.code.contains("CatalogKindFacet") && !file.code.contains("kindFacet"),
                    "\(file.name) still carries the media-kind facet")
        }
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        #expect(!toolbar.contains("Show files — media kind"), "the Show menu still has a media-kind section")
        #expect(toolbar.contains("ForEach(CatalogViewFilter.allCases"), "the Show menu's ticks come from the one filter list")
    }

    @Test("SENSOR: only the store names the old media-kind key (it migrates it once, logged)")
    func onlyTheStoreNamesTheKindFacetKey() throws {
        let namers = try appFiles().filter { $0.code.contains("\"catalogKindFacet\"") }.map(\.name)
        #expect(namers == ["CatalogShowFilterStore.swift"], "the media-kind key is named in: \(namers)")
    }

    // Unpaired Only, Has Master Copy and the awaiting-confirmation filter left
    // the menu: their words may survive only where the store names what a
    // migration dropped.
    @Test("SENSOR: no surface still offers a removed Show filter")
    func theRemovedFiltersAreOfferedNowhere() throws {
        for file in try appFiles() where file.name != "CatalogShowFilterStore.swift" {
            for gone in ["\"Unpaired Only\"", "\"Has Master Copy\"", "\"Repaired — Awaiting Confirmation\"",
                         ".unpairedOnly", ".hasMasterCopy", "CatalogViewFilter.awaitingConfirmation",
                         "engines.hasMasterCopy"] {
                #expect(!file.code.contains(gone), "\(file.name) still names \(gone)")
            }
        }
    }

    // The awaiting-confirmation list moved to the Media File Operations
    // window; its confirm is the ONE engine, and its body reads a prepared list.
    @Test("SENSOR: the repairs waiting for Sounds Good are listed in Media File Operations, through the one confirm engine")
    func theAwaitingListLivesInMediaFileOperations() throws {
        let window = try SourceTree.appCode(named: "MediaFileOperationsWindow.swift")
        #expect(window.contains("RepairsAwaitingConfirmationSection("), "the MFO window does not show the list")
        let list = SourceTree.strippingComments(try SourceTree.appCode(named: "RepairsAwaitingConfirmation.swift"))
        #expect(list.contains("pfAwaitingConfirmation"), "the list must use the one awaiting rule")
        #expect(list.contains("model.confirmRepairs(repairIDs:"), "the list must confirm through the one engine")
        #expect(list.contains("pendingCatalogSelection"), "the list must reveal a row through Show in Catalog")
        for second in ["repairConfirmedDate =", "supersededByID ="] {
            #expect(!list.contains(second), "the list writes \(second) itself — a second confirm path")
        }
        // Nothing O(records) in the section's body: the view part never walks the catalog.
        let view = try #require(list.range(of: "struct RepairsAwaitingConfirmationSection"))
        let body = String(list[view.lowerBound...])
        for walk in ["model.records.filter", "records.filter", "for rec in", ".records.first("] {
            #expect(!body.contains(walk), "the section walks the catalog in a view: \(walk)")
        }
    }

    // F6 — nothing holds a second copy of the set that could be written behind
    // the store's back.
    @Test("SENSOR: no view owns or binds a filter set of its own")
    func noViewOwnsAFilterSet() throws {
        for file in try appFiles() where file.name != "CatalogShowFilterStore.swift" {
            #expect(!file.code.contains("@Binding var viewFilters"), "\(file.name) binds the filter set")
            #expect(!file.code.contains("@State private var catalogViewFilters"), "\(file.name) owns a filter set")
            #expect(!file.code.contains("viewFilters.insert(") && !file.code.contains("viewFilters.remove(")
                        && !file.code.contains("viewFilters.removeAll("),
                    "\(file.name) mutates a filter set directly")
        }
    }

    // F6 — a click anywhere on the Showing box flipped Not Yet Archived.
    @Test("SENSOR: the Showing box is not a hidden toggle")
    func theShowingBoxHasNoTapGesture() throws {
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        #expect(!toolbar.contains(".onTapGesture"), "CatalogToolbar still flips a filter on a tap")
    }

    // F5 — CatalogToolbar.showingState never passed focusLabel, so the box
    // listed filters a focus set was ignoring.
    @Test("SENSOR: the toolbar tells the Showing box when a focus set overrides the filters")
    func showingBoxIsToldAboutFocusMode() throws {
        let toolbar = try SourceTree.appCode(named: "CatalogToolbar.swift")
        #expect(toolbar.contains("focusLabel: focusLabel"),
                "CatalogToolbar.showingState never passes focusLabel")
        let content = try SourceTree.appCode(named: "ContentView.swift")
        #expect(content.contains("focusLabel: filterByIDs.isEmpty ? nil : focusLabel"),
                "CatalogView does not hand the toolbar its focus label")
    }

    // F5 — one Text with lineLimit(1) cut filters off the end of the line.
    @Test("SENSOR: the Showing box picks a line that fits instead of truncating one")
    func theShowingBoxDoesNotTruncateFilters() throws {
        let summary = try SourceTree.appCode(named: "CatalogShowingSummary.swift")
        #expect(summary.contains("ViewThatFits(in: .horizontal)"))
        #expect(summary.contains("CatalogShowingSummary.boxLines(for: state)"))
    }

    // F3 — CatalogEmptyNote.pick was never told a filter was on.
    @Test("SENSOR: the empty table is told when Show filters are on")
    func theEmptyNoteIsToldAboutFilters() throws {
        let helpers = try SourceTree.appCode(named: "CatalogHelpers.swift")
        #expect(helpers.contains("filtersActive:"), "catalogEmptyNote passes no filter fact to CatalogEmptyNote.pick")
    }

    // F1 — an inspector save posts .videoScanCatalogMutated; the table did not
    // listen, so the edited row left at the next unrelated refresh.
    @Test("SENSOR: the files table follows a single-record edit")
    func theTableFollowsCatalogEdits() throws {
        let gate = try SourceTree.appCode(named: "CatalogRows.swift")
        #expect(gate.contains(".videoScanCatalogMutated"), "nothing in the rows file listens for a record edit")
        let table = try SourceTree.appCode(named: "CatalogContent+Table.swift")
        #expect(table.contains("refreshRows(afterEdit: true)"))
    }
}
