import AppKit
import Foundation
import Testing
@testable import VideoScan

// Source sensors for the Catalog window focus plan
// (docs/design/catalog_window_architecture_2026_10_06.md, branch
// fix/catalog-focus-vsplit). Text-only on purpose: they compile against
// the code BEFORE each step, so each one was shown red first. The real
// behaviour is pinned by the keyboard harness
// (VideoScanUITests/Gauntlet/CatalogKeyboardUITests.swift); these stop a
// later edit from quietly bringing a removed edge back.
//
// For a C++ reader: `#expect` ≈ EXPECT_TRUE (records and continues);
// `try #require` ≈ ASSERT_TRUE (stops the test).

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

private func allAppCode() throws -> [(name: String, code: String)] {
    try SourceTree.appSources.map { entry in
        (entry.relative, SourceTree.strippingComments(try String(contentsOf: entry.url, encoding: .utf8)))
    }
}

private func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

// MARK: - Step 1: one SwiftUI hierarchy

@Suite("Catalog focus plan — both tables in ONE SwiftUI hierarchy")
struct CatalogOneHierarchySensorTests {

    /// Rule 3: no NSHostingController between the focus owner and the
    /// tables. VerticalSplitView put each pane in its own hosting root.
    @Test func catalogDoesNotUseVerticalSplitView() throws {
        let catalogFiles = try allAppCode().filter {
            $0.name == "App/ContentView.swift" || $0.name.hasPrefix("Catalog/")
        }
        #expect(catalogFiles.count > 10, "sensor read too few files: \(catalogFiles.count)")
        for file in catalogFiles {
            #expect(!file.code.contains("VerticalSplitView("), "\(file.name) builds a VerticalSplitView again")
        }
        #expect(try code("ContentView.swift").contains("VSplitView {"), "rootSplit is a SwiftUI VSplitView")
    }

    /// Fable correction 3: no new height cap on the volumes pane.
    @Test func volumesPaneHasNoMaxHeightCap() throws {
        let content = try code("ContentView.swift")
        let start = try #require(content.range(of: "private var rootSplit: some View {"))
        let body = content[start.upperBound...].prefix(600)
        #expect(!body.contains("maxHeight"), "the volumes pane must not gain a max-height cap")
    }
}

// MARK: - Step 2/3/4: one focus owner (074bacb6's sensors, reused)

@Suite("Catalog panes — one focus state, no programmatic focus")
struct CatalogPaneFocusSensorTests {

    @Test func exactlyOneFocusStateOwnsBothPanes() throws {
        let all = try allAppCode()
        let owners = all.filter { $0.code.contains("@FocusState var focusedPane: CatalogPane?") }
        #expect(owners.map(\.name) == ["App/ContentView.swift"], "the ONE pane focus state lives in CatalogView")
        let anyPaneState = all.filter {
            $0.code.range(of: #"@FocusState\s+(private\s+)?var\s+\w+\s*:\s*CatalogPane"#, options: .regularExpression) != nil
        }
        #expect(anyPaneState.count == 1, "pane focus states: \(anyPaneState.map(\.name))")
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
    /// (and the same on appear). Nothing may assign the pane focus.
    @Test func nothingAssignsPaneFocus() throws {
        for file in try allAppCode() {
            let hit = file.code.range(of: #"focusedPane\s*=(?!=)"#, options: .regularExpression)
            #expect(hit == nil, "\(file.name) assigns focusedPane")
            // The ONE exception: a click moves the keyboard to the clicked
            // table (CatalogTableClickFocus — SwiftUI's Table won't).
            if file.name.hasPrefix("Catalog/") && file.name != "Catalog/CatalogTableClickFocus.swift" {
                #expect(!file.code.contains("makeFirstResponder"), "\(file.name) moves the first responder in code")
            }
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
        #expect(try code("ContentView.swift").contains(".defaultFocus($focusedPane, .files)"),
                "declared on the common ancestor of both panes")
    }

    @Test func onlyTheFilesTablePublishesFileVerbs() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains("focusedValue(\\.catalogTrashSelection"))
        #expect(table.contains("focusedValue(\\.catalogOpenSelection"))
        let volumes = try code("CatalogView+VolumeTable.swift")
        for key in ["catalogTrashSelection", "catalogOpenSelection", "catalogPromoteSelection"] {
            #expect(!volumes.contains("focusedValue(\\.\(key)"), "volumes pane publishes \(key)")
        }
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

    /// Rick 10/6: drop highlighted files a filter or search hides. Every
    /// row trigger goes through refreshRows; only onAppear recomputes alone.
    @Test func filterTriggersPruneTheSelection() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(occurrences(of: "refreshRows()", in: table) == 16)
        #expect(occurrences(of: "tableData = computeFiltered()", in: table) == 1, "only onAppear")
        #expect(try code("CatalogTableState.swift").contains("CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData)"))
    }
}

// MARK: - Promote Selected (data risk)

@Suite("Archive ▸ Promote Selected acts on the visible, focused file selection")
struct CatalogPromoteScopeSensorTests {

    /// The bug: the menu read the `catalogSelectedIDs` mirror, which still
    /// held files a volume filter had hidden and did not care which pane
    /// had the keyboard.
    @Test func menuNoLongerReadsTheSelectionMirror() throws {
        for file in try allAppCode() {
            #expect(!file.code.contains("catalogSelectedIDs"), "\(file.name) still uses the catalogSelectedIDs mirror")
        }
    }

    @Test func menuReadsTheFilesTablesFocusedValue() throws {
        let all = try allAppCode()
        let readers = all.filter { $0.code.contains("@FocusedValue(\\.catalogPromoteSelection)") }
        #expect(readers.count == 1, "one Promote menu item reads the focused value: \(readers.map(\.name))")
        let publishers = all.filter { $0.code.contains("focusedValue(\\.catalogPromoteSelection") }
        #expect(publishers.map(\.name) == ["Catalog/CatalogContent+Table.swift"], "only the files table publishes it")
        #expect(try code("VideoScanApp.swift").contains("CatalogPromoteMenuItem("))
    }
}

// MARK: - ⌘I (Rick 10/6: Catalog Info, as in Finder)

@Suite("⌘I has one owner: Catalog Info")
struct CatalogInfoShortcutSensorTests {

    @Test func noHiddenCommandIButton() throws {
        let pane = try code("CatalogView+ScanTargetsPane.swift")
        #expect(!pane.contains(".keyboardShortcut(\"i\""), "the hidden ⌘I Button is back")
    }

    @Test func importCatalogMovedOffCommandI() throws {
        let app = try code("VideoScanApp.swift")
        let start = try #require(app.range(of: "Button(\"Import Catalog…\")"))
        let next = app[start.upperBound...].prefix(160)
        #expect(next.contains(".keyboardShortcut(\"i\", modifiers: [.command, .shift])"), "Import Catalog… is ⇧⌘I")
        #expect(!next.contains(".keyboardShortcut(\"i\", modifiers: [.command])"))
    }

    @Test func catalogInfoIsAFocusScopedMenuItem() throws {
        let all = try allAppCode()
        #expect(all.filter { $0.code.contains("@FocusedValue(\\.catalogVolumeInfo)") }.count == 1)
        let publishers = all.filter { $0.code.contains("focusedValue(\\.catalogVolumeInfo") }
        #expect(publishers.map(\.name) == ["Catalog/CatalogView+VolumeTable.swift"])
    }
}

// MARK: - Click → keyboard (CatalogTableClickFocus)

@MainActor
@Suite("A click gives the clicked Catalog table the keyboard — and nothing else does")
struct CatalogTableClickFocusTests {

    @Test func focusesAnUnfocusedTable() {
        let table = NSTableView()
        #expect(CatalogTableClickFocus.shouldFocus(table, firstResponder: nil))
        #expect(CatalogTableClickFocus.shouldFocus(table, firstResponder: NSTableView()),
                "a click in one table takes the keyboard from the other")
    }

    @Test func leavesItAloneWhenItOrAChildAlreadyHasIt() {
        let table = NSTableView()
        let editor = NSTextView()
        table.addSubview(editor)
        #expect(!CatalogTableClickFocus.shouldFocus(table, firstResponder: table))
        #expect(!CatalogTableClickFocus.shouldFocus(table, firstResponder: editor), "inline edit keeps its field")
    }

    @Test func respectsARefusingTable() {
        let table = NSTableView()
        table.refusesFirstResponder = true
        #expect(!CatalogTableClickFocus.shouldFocus(table, firstResponder: nil))
    }

    /// The hook reacts to the CLICK only — installed by CatalogView for the
    /// tab's lifetime, never from a selection or filter change.
    @Test func installedOnlyByCatalogViewLifetime() throws {
        let content = try code("ContentView.swift")
        #expect(content.contains(".onAppear { tableClickFocus.install() }"))
        #expect(content.contains(".onDisappear { tableClickFocus.remove() }"))
        let users = try allAppCode().filter { $0.code.contains("CatalogTableClickFocus") }.map(\.name)
        #expect(Set(users) == ["App/ContentView.swift", "Catalog/CatalogTableClickFocus.swift"])
    }
}
