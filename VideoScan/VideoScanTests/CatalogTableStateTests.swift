import AppKit
import SwiftUI
import Testing
@testable import VideoScan

// R1 refactor (GH #281): the files table's rows snapshot, badge revision
// and keyboard-focus flag moved out of CatalogContent's declaration list
// into CatalogTableState (a DynamicProperty). Two kinds of pin:
//   1. Source sensor — the focus flag has ONE home and the table still
//      binds it (`.focused`) and defaults to it (`.defaultFocus`).
//   2. Mechanism probe — a @FocusState nested in a DynamicProperty drives
//      real AppKit first-responder the same way a direct one does.

@Suite("CatalogTableState — one home for the files table's focus + rows")
struct CatalogTableStateSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.strippingComments(SourceTree.appSource(named: name))
    }

    @Test func focusFlagHasOneHome() throws {
        let state = try code("CatalogTableState.swift")
        #expect(state.components(separatedBy: "@FocusState").count - 1 == 1)
        #expect(state.contains("@FocusState var filesTableFocused: Bool"))
        #expect(state.contains("@State var tableData: [VideoRecord] = []"))
        for name in ["CatalogHelpers.swift", "CatalogContent+Table.swift"] {
            let src = try code(name)
            #expect(!src.contains("@FocusState"), "\(name) declares its own focus state again")
            #expect(!src.contains("@State var tableData"), "\(name) declares its own rows snapshot again")
        }
    }

    @Test func theTableStillBindsAndDefaultsToTheFlag() throws {
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains(".focused(tableState.$filesTableFocused)"), "the Table takes keyboard focus from the flag")
        #expect(!table.contains(".onKeyPress("), "no key handler on the Table — it breaks ↑/↓")
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains(".defaultFocus(tableState.$filesTableFocused, true)"), "files table is the default focus")
        #expect(helpers.components(separatedBy: "filesTableFocused = true").count - 1 == 2,
                "focus follows a file pick + is claimed on appear")
        #expect(helpers.contains("var tableState = CatalogTableState()"))
    }
}

// MARK: - Mechanism probe

/// Same shape as CatalogTableState: a FocusState inside a DynamicProperty.
private struct NestedFocus: DynamicProperty {
    @FocusState var focused: Bool
}

private struct NestedFocusProbe: View {
    var holder = NestedFocus()
    @State private var text = ""
    var body: some View {
        VStack {
            TextField("other", text: .constant(""))
            TextField("target", text: $text).focused(holder.$focused)        }
        .onAppear { holder.focused = true }
    }
}

private struct DirectFocusProbe: View {
    @FocusState private var focused: Bool
    @State private var text = ""
    var body: some View {
        VStack {
            TextField("other", text: .constant(""))
            TextField("target", text: $text).focused($focused)
        }
        .onAppear { focused = true }
    }
}

/// Not on GitHub runners: no session there can make a window key, and a
/// probe whose control cannot take focus proves nothing. (Keyed on
/// GITHUB_ACTIONS like CatalogSearchProfileBench — the CI test plan sets
/// CI=1 on every local run too. `.enabled(if:)` ≈ a gtest filter
/// evaluated at registration time.)
@MainActor
@Suite("CatalogTableState — nested @FocusState drives AppKit focus like a direct one",
       .enabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true",
                "needs a window server that can make a window key"))
struct CatalogTableStateFocusProbeTests {

    /// Hosts `view` in an off-screen key window and reports whether the
    /// focus request reached AppKit: the field editor is editing the
    /// "target" field — NOT the "other" field above it, which is what a
    /// window's initial first responder would pick on its own.
    private func focusLands<V: View>(_ view: V) async -> Bool? {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(25))
            let editing = ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
            if editing == "target" { return true }
        }
        // A test host that cannot make windows key proves nothing either way.
        return window.isKeyWindow ? false : nil
    }

    @Test func nestedFocusStateBehavesLikeDirect() async throws {
        let direct = await focusLands(DirectFocusProbe())
        try #require(direct == true, "control probe could not take focus in this host (\(String(describing: direct))) — mechanism untestable here")
        let nested = await focusLands(NestedFocusProbe())
        #expect(nested == true, "a @FocusState inside a DynamicProperty did not reach AppKit")
    }
}
