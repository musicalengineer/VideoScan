import AppKit
import SwiftUI
import Testing
@testable import VideoScan

// Mechanism probe for the Catalog's two-pane focus (Rick 2026-10-06):
// the volumes Table and the files Table live in TWO NSHostingControllers
// (VerticalSplitView wraps NSSplitViewController), so a single
// `@FocusState var focusedPane: CatalogPane?` owned by their common
// SwiftUI ancestor must drive focus across that AppKit boundary. This
// probe builds the same shape with the app's real VerticalSplitView and
// checks, in an off-screen key window:
//   1. a native focus move to the volumes table is reported as .volumes
//      and a files-selection change does NOT pull focus back (symptom 1);
//   2. focus in the files table publishes catalogTrashSelection to a
//      reader in the ROOT host — the route ⌘⌫ takes (symptom 2);
//   3. the OLD design (grab focus on every selection change) is what
//      stole the arrows — kept as a control so the probe proves it can
//      see the bug it guards.

/// Shared box the probe views write into (≈ a C++ out-parameter struct).
@MainActor
final class PaneProbeLog {
    var pane: CatalogPane?
    var trashCount: Int?
}

private struct PaneProbeTrashReader: View {
    let log: PaneProbeLog
    @FocusedValue(\.catalogTrashSelection) private var trash
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onChange(of: trash?.count, initial: true) { log.trashCount = trash?.count }
    }
}

private struct PaneProbe: View {
    let log: PaneProbeLog
    /// true = the pre-fix design: claim the files pane on every selection change.
    let grabOnSelection: Bool
    @Binding var fileSelection: Set<Int>
    @FocusState private var focusedPane: CatalogPane?
    @State private var volumeSelection: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            PaneProbeTrashReader(log: log)
            VerticalSplitView(topMinHeight: 60, topIdealHeight: 120, topMaxHeight: 200,
                              top: { volumes }, bottom: { files })
        }
        .onChange(of: focusedPane, initial: true) { log.pane = focusedPane }
    }

    private var volumes: some View {
        Table(Array(0..<5).map(ProbeRow.init), selection: $volumeSelection) {
            TableColumn("Volume") { Text("vol \($0.id)") }
        }
        .focused($focusedPane, equals: .volumes)
    }

    private var files: some View {
        Table(Array(0..<20).map(ProbeRow.init), selection: $fileSelection) {
            TableColumn("File") { Text("file \($0.id)") }
        }
        .focused($focusedPane, equals: .files)
        .focusedValue(\.catalogTrashSelection,
                      CatalogTrashSelection(count: fileSelection.count, perform: {}))
        .defaultFocus($focusedPane, .files)
        .onChange(of: fileSelection) {
            if grabOnSelection { focusedPane = .files }
        }
    }
}

private struct ProbeRow: Identifiable {
    let id: Int
}

/// OPT-IN (VS_FOCUS_PROBE=1): the probe window must become KEY, which
/// means activating the test host app — that steals the keyboard from
/// whatever Rick is doing, so it never runs by default on the M4 during
/// the day. Run it on the M1/M5, or at night:
///   TEST_RUNNER_VS_FOCUS_PROBE=1 xcodebuild test … -only-testing:VideoScanTests/CatalogPaneFocusProbeTests
/// (`.enabled(if:)` ≈ a gtest filter evaluated at registration time.)
@MainActor
@Suite("Catalog panes — one FocusState drives both tables across the split",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VS_FOCUS_PROBE"] == "1",
                "opt-in: activates the app to make a key window (VS_FOCUS_PROBE=1)"))
struct CatalogPaneFocusProbeTests {

    /// Holds the probe's file selection outside SwiftUI so the test can
    /// change it the way a volume click's re-filter does.
    @MainActor
    final class SelectionBox {
        var value: Set<Int> = [3]
        var binding: Binding<Set<Int>> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    @MainActor
    private struct Harness {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let log: PaneProbeLog
        let box: SelectionBox
        let grab: Bool

        func setSelection(_ ids: Set<Int>) {
            box.value = ids
            host.rootView = AnyView(PaneProbe(log: log, grabOnSelection: grab, fileSelection: box.binding))
        }

        /// The NSTableView inside split pane `index` (0 = volumes, 1 = files).
        func table(_ index: Int) -> NSTableView? {
            let split = Self.find(NSSplitView.self, in: host)
            guard let pane = split?.arrangedSubviews[safe: index] else { return nil }
            return Self.find(NSTableView.self, in: pane)
        }

        func responderIsInside(_ view: NSView?) -> Bool {
            guard let view, let responder = window.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }

        static func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
            if let hit = root as? T { return hit }
            for sub in root.subviews {
                if let hit = find(type, in: sub) { return hit }
            }
            return nil
        }
    }

    private func makeHarness(grab: Bool) -> Harness {
        let log = PaneProbeLog()
        let box = SelectionBox()
        let host = NSHostingView(rootView: AnyView(PaneProbe(log: log, grabOnSelection: grab, fileSelection: box.binding)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return Harness(window: window, host: host, log: log, box: box, grab: grab)
    }

    private func settle(_ ms: Int = 300) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Volumes focused natively (what a click does) → reported .volumes,
    /// no trash selection offered, and a files-selection change leaves
    /// focus where the user put it.
    @Test func volumesKeepFocusWhenTheFileSelectionChanges() async throws {
        let h = makeHarness(grab: false)
        defer { h.window.orderOut(nil) }
        await settle()
        try #require(h.window.isKeyWindow, "host cannot make a window key — mechanism untestable here")
        let volumes = try #require(h.table(0))
        let files = try #require(h.table(1))

        h.window.makeFirstResponder(volumes)
        await settle()
        #expect(h.log.pane == .volumes, "native focus in the volumes table reads back as .volumes")
        #expect(h.log.trashCount == nil, "no Move to Trash target while the volumes pane has focus")

        h.setSelection([7])   // a volume click re-filters the files → selection changes
        await settle()
        #expect(h.responderIsInside(volumes), "a file-selection change must not pull focus out of the volumes table")
        #expect(!h.responderIsInside(files))
    }

    /// Files focused natively → .files and the trash selection reaches a
    /// reader in the root host (the Commands route for ⌘⌫).
    @Test func filesFocusPublishesTheTrashSelection() async throws {
        let h = makeHarness(grab: false)
        defer { h.window.orderOut(nil) }
        await settle()
        try #require(h.window.isKeyWindow, "host cannot make a window key — mechanism untestable here")
        let volumes = try #require(h.table(0))
        let files = try #require(h.table(1))

        h.window.makeFirstResponder(volumes)
        await settle()
        h.window.makeFirstResponder(files)
        await settle()
        #expect(h.log.pane == .files)
        #expect(h.log.trashCount == 1, "focused files table must offer its selection to Catalog ▸ Move to Trash")
    }

    /// Control: the pre-fix grab-on-selection design really does steal
    /// focus from the volumes table (symptom 1). If this ever stops
    /// failing-as-expected, the probe above is no longer seeing focus.
    @Test func controlTheOldGrabStealsFromVolumes() async throws {
        let h = makeHarness(grab: true)
        defer { h.window.orderOut(nil) }
        await settle()
        try #require(h.window.isKeyWindow, "host cannot make a window key — mechanism untestable here")
        let volumes = try #require(h.table(0))

        h.window.makeFirstResponder(volumes)
        await settle()
        h.setSelection([7])
        await settle()
        #expect(!h.responderIsInside(volumes),
                "control: the old grab-on-selection design should steal focus — if it does not, this probe cannot see focus moves")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
