// CatalogTrashCommand.swift
// ⌘⌫ in the Catalog, done the way macOS actually routes it (Rick
// 2026-09-20: "why can't I hit cmd-delete on a file in the catalog?" —
// the second report; 2026-09-16 was the first).
//
// A Command-key combination is a KEY EQUIVALENT: AppKit offers it to the
// menu bar before any view sees a keyDown, and a SwiftUI `onKeyPress` on
// the Table only fires when nothing in the responder chain claimed it
// first. In practice the gesture never reached the handler — today's log
// has no "Move to Trash (⌘⌫)" line at all. Finder's answer is the right
// one: a real menu item, File-menu style, whose key equivalent is ⌘⌫ and
// whose target is whatever catalog table currently has keyboard focus.
//
// The table publishes a `CatalogTrashSelection` as a FOCUSED value (not a
// scene value): a search field or rename field with focus keeps its own
// ⌘⌫, and the menu item is disabled until a table row is highlighted. The
// item calls the same `trashSelectedRows` the key handler calls, which ends
// in the ONE Trash routine (`VideoScanModel.trashSelectedRecords` →
// `deleteConfirmedJunk(mode: .toTrash)`). The `onKeyPress` handler stays as
// a second path; both write the same begin line, so the log always says
// which one fired.
//
// (For Rick: `FocusedValueKey` ≈ a typed slot the focused view fills and
// the menu reads; nil when no catalog table has focus.)

import SwiftUI

/// What the focused catalog table offers the menu: how many rows are
/// highlighted and the action that trashes them.
struct CatalogTrashSelection {
    let count: Int
    let perform: () -> Void
}

struct CatalogTrashSelectionKey: FocusedValueKey {
    typealias Value = CatalogTrashSelection
}

extension FocusedValues {
    var catalogTrashSelection: CatalogTrashSelection? {
        get { self[CatalogTrashSelectionKey.self] }
        set { self[CatalogTrashSelectionKey.self] = newValue }
    }
}

/// The Catalog ▸ Move to Trash item. Lives in its own View so
/// `@FocusedValue` can be read inside the Commands builder.
struct CatalogTrashMenuItem: View {
    @FocusedValue(\.catalogTrashSelection) private var selection

    var body: some View {
        Button(title) {
            selection?.perform()
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled((selection?.count ?? 0) == 0)
        .help("Move the highlighted catalog rows to the Trash — the Finder gesture. Master Archive files, recovered A/V pair halves and offline copies are refused with a console line.")
    }

    private var title: String {
        let n = selection?.count ?? 0
        return n > 1 ? "Move \(n) to Trash" : "Move to Trash"
    }
}
