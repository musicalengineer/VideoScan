import Foundation
import SwiftUI
import Testing
@testable import VideoScan

// Catalog two-pane focus + volume filter (Rick 2026-10-06; supersedes the
// R1 `filesTableFocused` pins). Design under test — Apple's focus model:
//   • ONE `@FocusState var focusedPane: CatalogPane?`, in CatalogView (the
//     common ancestor of the volumes table and the files table);
//   • each Table bound with `.focused($focusedPane, equals:)`;
//   • `.defaultFocus($focusedPane, .files)` once; NOTHING assigns focus;
//   • ⌘⌫ / ⌘O targets published only by the files table;
//   • the Space monitor fires only for the files pane;
//   • a filter change keeps the visible part of the file selection and
//     never touches focus; an empty volume pick = every volume.
// Kinds of pin: source sensors (this suite), logic + scale for the
// selection rule, and the AppKit mechanism probe in
// CatalogPaneFocusProbeTests.swift.

@Suite("Catalog panes — one focus state, no programmatic focus")
struct CatalogPaneFocusSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.strippingComments(SourceTree.appSource(named: name))
    }

    /// Every app source, comments stripped, by relative path.
    private func allAppCode() throws -> [(name: String, code: String)] {
        try SourceTree.appSources.map { entry in
            (entry.relative, SourceTree.strippingComments(try String(contentsOf: entry.url, encoding: .utf8)))
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func exactlyOneFocusStateOwnsBothPanes() throws {
        let all = try allAppCode()
        let owners = all.filter { $0.code.contains("@FocusState var focusedPane: CatalogPane?") }
        #expect(owners.map(\.name) == ["App/ContentView.swift"], "the ONE pane focus state lives in CatalogView")
        #expect(owners.map { occurrences(of: "@FocusState var focusedPane", in: $0.code) } == [1])
        let anyOtherPaneState = all.filter {
            $0.code.range(of: #"@FocusState\s+(private\s+)?var\s+\w+\s*:\s*CatalogPane"#, options: .regularExpression) != nil
        }
        #expect(anyOtherPaneState.count == 1, "a second CatalogPane focus state: \(anyOtherPaneState.map(\.name))")
        #expect(all.allSatisfy { !$0.code.contains("filesTableFocused") }, "the old per-table flag is back")
        let content = try code("CatalogHelpers.swift")
        #expect(content.contains("@FocusState.Binding var focusedPane: CatalogPane?"), "CatalogContent takes the parent's binding")
        #expect(!content.contains("@FocusState var"), "CatalogContent declares its own focus state again")
        #expect(!(try code("CatalogTableState.swift")).contains("@FocusState"))
        #expect(try code("ContentView.swift").contains("focusedPane: $focusedPane"), "CatalogView hands the binding down")
    }

    @Test func bothTablesAreBoundWithEquals() throws {
        #expect(try code("CatalogView+VolumeTable.swift").contains(".focused($focusedPane, equals: .volumes)"))
        #expect(try code("CatalogContent+Table.swift").contains(".focused($focusedPane, equals: .files)"))
    }

    /// The bug: `.onChange(of: selectedIDs) { filesTableFocused = true }`
    /// (and the same on appear). Nothing in the app may assign the pane
    /// focus — clicks move it natively.
    @Test func nothingAssignsPaneFocus() throws {
        for file in try allAppCode() {
            let hit = file.code.range(of: #"focusedPane\s*=(?!=)"#, options: .regularExpression)
            #expect(hit == nil, "\(file.name) assigns focusedPane")
        }
        let helpers = try code("CatalogHelpers.swift")
        let block = try #require(helpers.range(of: ".onChange(of: selectedIDs) {"))
        let rest = helpers[block.upperBound...]
        let end = try #require(rest.range(of: "applyLivePreview(action)"), "selection onChange block end moved")
        let tail = rest[..<end.lowerBound]
        #expect(!tail.contains("= true"), "a focus grab came back inside the selection onChange")
        #expect(!tail.lowercased().contains("focus"), "focus handling inside the selection onChange")
    }

    @Test func defaultFocusIsDeclaredOnceForTheFiles() throws {
        let total = try allAppCode().map { occurrences(of: ".defaultFocus($focusedPane", in: $0.code) }.reduce(0, +)
        #expect(total == 1)
        #expect(try code("CatalogHelpers.swift").contains(".defaultFocus($focusedPane, .files)"))
    }

    @Test func onlyTheFilesTablePublishesTrashAndOpen() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains("focusedValue(\\.catalogTrashSelection"))
        #expect(table.contains("focusedValue(\\.catalogOpenSelection"))
        let volumes = try code("CatalogView+VolumeTable.swift")
        #expect(!volumes.contains("focusedValue("), "volumes are never trashed or opened — no menu target there")
        #expect(!volumes.contains(".onKeyPress("), "no key handler on the volumes Table")
        #expect(!table.contains(".onKeyPress("), "no key handler on the files Table — it breaks ↑/↓")
    }

    @Test func spaceToggleRequiresTheFilesPane() throws {
        let helpers = try code("CatalogHelpers.swift")
        let fn = try #require(helpers.range(of: "func spaceShouldToggleLivePreview() -> Bool {"))
        #expect(helpers[fn.upperBound...].prefix(200).contains("paneFocusMirror.pane == .files"),
                "Space must not toggle live preview while the volumes table has the keyboard")
        #expect(try code("CatalogContent+Table.swift").contains("tableState.paneFocusMirror.pane = focusedPane"))
    }

    /// Every filter trigger goes through refreshRows (rows + selection
    /// prune); only onAppear and rename recompute rows alone.
    @Test func filterTriggersPruneTheSelection() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(occurrences(of: "refreshRows()", in: table) == 16)
        #expect(occurrences(of: "tableData = computeFiltered()", in: table) == 1, "only onAppear")
        #expect(try code("CatalogTableState.swift").contains("CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData)"))
    }
}

// MARK: - Selection prune: logic + scale

@Suite("Catalog filter change keeps the visible file selection")
struct CatalogSelectionPruneTests {

    private func rows(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "v\(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/v\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
    }

    @Test func keepsVisibleDropsHidden() {
        let all = rows(10)
        let picked: Set<UUID> = [all[1].id, all[5].id, all[8].id]
        let visible = [all[0], all[1], all[2], all[8]]
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: visible) == [all[1].id, all[8].id])
    }

    @Test func emptySelectionAndFullyVisibleSelectionAreUnchanged() {
        let all = rows(5)
        #expect(CatalogSelectionPrune.visibleSelection([], rows: all).isEmpty)
        let picked: Set<UUID> = [all[0].id, all[4].id]
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: all) == picked)
        #expect(CatalogSelectionPrune.visibleSelection(picked, rows: []).isEmpty, "a filter that hides everything drops the selection")
    }

    /// Scale (checklist dimension 2): runs on every filter trigger.
    @Test func prune100kRowsStaysUnderBudget() {
        let all = rows(100_000)
        let picked = Set(all.prefix(1_000).map(\.id)).union([UUID()])
        let t0 = Date()
        let kept = CatalogSelectionPrune.visibleSelection(picked, rows: all)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(kept.count == 1_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 0.25), "prune took \(elapsed)s for 100k rows")
    }
}

// MARK: - Empty volume pick = all files (scale)

@MainActor
@Suite("Catalog empty volume pick shows every file without an extra pass")
struct CatalogAllVolumesDefaultTests {

    private func rows(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "v\(i).mov"
            r.fullPath = "/Volumes/V\(i % 4)/v\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            return r
        }
    }

    private func filtered(_ records: [VideoRecord], volumes: Set<String>) -> [VideoRecord] {
        CatalogContent(
            records: records,
            selectedIDs: .constant([]),
            focusedPane: FocusState<CatalogPane?>().projectedValue,
            sortOrder: .constant([]),
            searchText: "",
            searchHitCount: .constant(0),
            filterTargetPaths: volumes,
            showPairsOnly: false,
            viewFilters: [],
            showDisconnectedMedia: true,   // no reachability probes in a unit test
            showRemoved: false,
            previewImage: nil,
            previewFilename: "",
            previewOfflineVolumeName: nil,
            showInspector: .constant(false),
            onSort: { _ in },
            onSelect: { _ in },
            onClearPreview: {}
        ).computeFiltered()
    }

    @Test func emptyPickIsEveryVolumeAndAPickNarrows() {
        let all = rows(8)
        #expect(filtered(all, volumes: []).count == 8)
        #expect(filtered(all, volumes: ["/Volumes/V1"]).map(\.filename) == ["v1.mov", "v5.mov"])
    }

    @Test func allVolumes100kStaysUnderBudget() {
        let all = rows(100_000)
        let t0 = Date()
        let out = filtered(all, volumes: [])
        let elapsed = Date().timeIntervalSince(t0)
        #expect(out.count == 100_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 1.0), "all-volumes filter took \(elapsed)s for 100k records")
    }
}
