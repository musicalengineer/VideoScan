// CatalogTableClickFocus.swift
// "A click in a table gives that table the keyboard" — Finder's rule, done
// explicitly because SwiftUI's Table does not do it on macOS 26/27
// (measured 2026-10-06 by the keyboard harness, design doc Q3):
//
//   mouseDown before: NSTableView(rows=3)              ← volumes have the keyboard
//     hit: TableCellHostingView < … < NSTableView(rows=60 class=SwiftUIOutlineTableView
//          accepts=true refuses=false)                 ← the click lands in the FILES table
//   key ↓ before: NSTableView(rows=3)                  ← …and ↓ still goes to the volumes
//
// The row gets selected but the first responder never moves, in either
// pane. Main hid this with "selection change → focus the files" (edge 4),
// which is exactly what stole the arrows after a volume click.
//
// This hook reacts to the CLICK, never to a selection change, so a volume
// click that re-filters the files cannot move the keyboard. It observes
// mouseDown only, never consumes it, and only while the Catalog tab is on
// screen (CatalogView installs/removes it). SwiftUI's `focusedPane`
// follows the AppKit first responder, as it does for Tab.
//
// C++ analogy: a pre-dispatch event filter (≈ a Qt eventFilter) that sets
// keyboard focus to the widget under the cursor, then lets the event go on.

import AppKit

@MainActor
final class CatalogTableClickFocus {
    /// Opaque token from NSEvent's local monitor (≈ a subscription handle).
    private var monitor: Any?

    /// Idempotent. Worst-case memory: one closure; nothing buffered.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { Self.focusClickedTable(event) }
            return event   // observe only — the table still handles the click
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The table under the click, if any. `hitTest` takes a point in the
    /// receiver's SUPERVIEW coordinates; the frame view (contentView's
    /// superview) is in window coordinates.
    static func clickedTable(_ event: NSEvent) -> NSTableView? {
        guard let frameView = event.window?.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { return nil }
        var node: NSView? = hit
        while let current = node {
            if let table = current as? NSTableView { return table }
            node = current.superview
        }
        return nil
    }

    /// Pure rule: move the keyboard to `table` unless it (or a view inside
    /// it, e.g. an inline editor) already has it, or it refuses.
    static func shouldFocus(_ table: NSTableView, firstResponder: NSResponder?) -> Bool {
        guard table.acceptsFirstResponder, !table.refusesFirstResponder else { return false }
        if let view = firstResponder as? NSView, view === table || view.isDescendant(of: table) {
            return false
        }
        return true
    }

    private static func focusClickedTable(_ event: NSEvent) {
        guard let window = event.window, let table = clickedTable(event),
              shouldFocus(table, firstResponder: window.firstResponder) else { return }
        window.makeFirstResponder(table)
    }
}
