import AppKit
import Foundation
import Testing
@testable import VideoScan

// Rick, 2026-10-25 (rapid dev): "all views that have lists should allow
// up/down arrow … Triage file view, People video list, Storage tab Volume
// list." Two mechanisms make that true on macOS, and this sensor pins both:
//
//  1. A SwiftUI `Table` / `List` gets ↑↓ only while it is the AppKit first
//     responder, and on macOS 26/27 a click does NOT make it one
//     (TableClickFocus.swift). The hook must therefore live at the MAIN
//     WINDOW root — every tab — not on the Catalog view alone, which is
//     exactly why Triage and Storage stayed deaf.
//  2. A hand-rolled `ScrollView { LazyVStack { … } }` is not a list to the
//     keyboard at all. Every clickable row list is a `List(selection:)`.
//
// Source sensor, not a behaviour test: the keyboard harness that measures
// first-responder moves lives in the gauntlet (design doc Q3, 2026-10-06).

private func appSource(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

@Suite("Lists take the arrow keys on every tab")
struct ListKeyboardNavigationSensorTests {

    /// The click-to-focus hook is installed once, at the window root, for
    /// the window's lifetime — never per tab.
    @Test func clickFocusHookLivesAtTheWindowRoot() throws {
        let content = try appSource("App/ContentView.swift")
        // The root body (struct ContentView) installs it; CatalogView must not.
        let rootBody = content.components(separatedBy: "struct CatalogView").first ?? ""
        #expect(rootBody.contains("TableClickFocus()"), "the hook is owned by ContentView's root")
        #expect(rootBody.contains(".onAppear { tableClickFocus.install() }"))
        #expect(rootBody.contains(".onDisappear { tableClickFocus.remove() }"))
        #expect(rootBody.contains("WindowReader { tableClickFocus.window = $0 }"))
        let catalogPart = content.components(separatedBy: "struct CatalogView").dropFirst().joined()
        #expect(!catalogPart.contains("tableClickFocus"), "CatalogView no longer owns the hook")
    }

    /// The People tab's video lists are real lists with a selection.
    @Test func peopleVideoListsAreSelectableLists() throws {
        let source = try appSource("People/PersonVideosSection.swift")
        let listCount = source.components(separatedBy: "List(selection:").count - 1
        #expect(listCount >= 2, "a person's page and a family's page are both List(selection:) — found \(listCount)")
        let squeezed = source.filter { !$0.isWhitespace }
        #expect(!squeezed.contains("ScrollView{LazyVStack"),
                "no hand-rolled scroll stack where a list belongs")
    }

    /// Triage and Storage already bind a selection; keep it that way.
    @Test func triageAndStorageBindASelection() throws {
        #expect(try appSource("Catalog/TriageView.swift").contains("Table(rows, selection: $selectedIDs"))
        #expect(try appSource("Volumes/VolumesWindow.swift").contains("List(selection: $selectedID)"))
    }
}
