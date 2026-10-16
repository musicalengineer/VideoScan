// CatalogTableState.swift
// The Catalog files table's own view state in one place (R1 refactor,
// GH #281): the rows snapshot it draws, the badge revision its cells
// read — plus `CatalogPane`, the name of each keyboard-focus target in
// the Catalog's two panes (2026-10-06) — and, since the Footage folders
// view (2026-10-16), the open folders, the scope and the folder rows.
// The keyboard focus itself is ONE FocusState (`focusedPane`) in
// CatalogView; the table's selection and sort order are @Bindings owned
// there too.

import SwiftUI

/// The two keyboard-focus targets on the Catalog tab. Bound with
/// `.focused($focusedPane, equals:)` on each Table. (≈ a C++ enum class
/// used as the key of a "who owns the keyboard" register; nil = neither.)
enum CatalogPane: Hashable {
    case volumes, files
}

/// Reference box the Space-key NSEvent monitor reads. The monitor closure
/// outlives any one body evaluation, so it cannot read the FocusState
/// itself; CatalogContent mirrors `focusedPane` into this on change.
/// (≈ a C++ shared_ptr<State> a callback holds.)
@MainActor
final class CatalogPaneFocusMirror {
    var pane: CatalogPane?
}

/// Reference box the same NSEvent monitor reads for the folder keys
/// (→ / ← / Esc): whether Show ▸ Events & Copies as Folders is on. The
/// option is a plain `let` on CatalogContent, which the monitor's captured
/// copy would read stale; this box is mirrored on every change.
@MainActor
final class FootageFolderKeyMirror {
    var isOn = false
}

/// The files table's view-owned state. A custom `DynamicProperty` ≈ a C++
/// member struct whose fields the framework re-binds before every body
/// evaluation: SwiftUI finds the `@State` inside it exactly as if they
/// were declared directly on CatalogContent.
struct CatalogTableState: DynamicProperty {
    /// Stable snapshot the Table reads from. Decoupled from `records` so the
    /// Table never sees the data array mutate mid-gesture (which races with
    /// AppKit's canDragRows / mouseDown handling and crashes inside
    /// ForEach.IDGenerator with an out-of-bounds subscript).
    @State var tableData: [VideoRecord] = []

    /// Archive Angel evidence revision the rows last drew against (codex
    /// #1345). Bumped from the store's `revision` publisher so a sweep
    /// that changes a grade/summary WITHOUT changing the A+B set still
    /// re-renders the "Promote me" badge and its tooltip. Read by the Tag
    /// column cell; never recomputes `tableData` (≈ a dirty counter the
    /// cell painter compares, not a data reload).
    @State var angelBadgeRevision: Int = 0

    /// Which pane has the keyboard, for the Space monitor (see
    /// CatalogPaneFocusMirror). Written only by `.onChange(of: focusedPane)`.
    @State var paneFocusMirror = CatalogPaneFocusMirror()

    // MARK: Footage folders (Show ▸ Events & Copies as Folders, 2026-10-16)

    /// The folders twisted open (event ids). Session state, like the
    /// Finder's.
    @State var openFolderIDs: Set<UUID> = []
    /// The list narrowed to one event (double-click) or one file's
    /// family (Show Copies & Related…); nil = everything. Esc / the crumb
    /// clears it.
    @State var folderScope: FootageFolders.Scope?
    /// The folder Table's rows — the published display turned into rows
    /// in an event handler (CatalogContent.rebuildFolderRows), never in a body.
    @State var folderRows: [FootageFolderTableRow] = []
    /// The event ids among `folderRows` (O(1) "is this id a folder?").
    @State var folderIDs: Set<UUID> = []
    /// Whether the option is on, for the key monitor (see FootageFolderKeyMirror).
    @State var folderKeyMirror = FootageFolderKeyMirror()
}

extension CatalogContent {
    // Forwarders: every existing read/write site keeps its spelling. A
    // `nonmutating set` ≈ a C++ setter on a const object that writes
    // through a pointer — @State storage lives outside the
    // view struct, which is why the (immutable) view can assign to it.

    /// See `CatalogTableState.tableData`.
    var tableData: [VideoRecord] {
        get { tableState.tableData }
        nonmutating set { tableState.tableData = newValue }
    }

    /// See `CatalogTableState.angelBadgeRevision`.
    var angelBadgeRevision: Int {
        get { tableState.angelBadgeRevision }
        nonmutating set { tableState.angelBadgeRevision = newValue }
    }

    /// See `CatalogTableState.folderRows`.
    var folderRows: [FootageFolderTableRow] { tableState.folderRows }

    /// Recompute the rows, then keep the file selection only for rows the
    /// filter still shows (Rick 2026-10-06: "drop highlighted files that a
    /// filter or search hides" — Finder's rule; a hidden selection was a
    /// ⌘⌫ / Promote trap). Never touches keyboard focus. With the folder
    /// view on, the folder display follows the new rows (a no-op otherwise).
    func refreshRows() {
        tableData = computeFiltered()
        // A selected folder row is not a record: it stays selected.
        let kept = CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData)
            .union(selectedIDs.intersection(tableState.folderIDs))
        if kept != selectedIDs { selectedIDs = kept }
        refreshFolderDisplay()
    }
}

/// Pure rule behind refreshRows' selection step — headless-testable.
enum CatalogSelectionPrune {
    /// The subset of `selection` that is still a visible row. O(rows) only
    /// when something is selected; an empty selection costs nothing.
    /// Worst-case memory: one Set the size of the selection.
    static func visibleSelection(_ selection: Set<UUID>, rows: [VideoRecord]) -> Set<UUID> {
        guard !selection.isEmpty else { return selection }
        var kept = Set<UUID>()
        kept.reserveCapacity(selection.count)
        for row in rows where selection.contains(row.id) {
            kept.insert(row.id)
            if kept.count == selection.count { break }
        }
        return kept
    }
}
