// CatalogTableState.swift
// The Catalog files table's own view state in one place (R1 refactor,
// GH #281): the rows snapshot it draws and the badge revision its cells
// read — plus `CatalogPane`, the name of each keyboard-focus target in
// the Catalog's two panes (Rick 2026-10-06).
//
// ── DEPENDENCY MAP: volume pick → files → selection → focus ─────────────
// (2026-10-06; "W" = who writes, "R" = who reads, "onChange" = who reacts.)
//
//  selectedVolumeIDs   CatalogView @State (ContentView.swift)
//    W  volume Table selection (a click / ⌘-click / click on empty space);
//       navigation verbs clear it (Show Pair, Online copies, Repaired
//       copy, Find A/V Pair, Archive→Catalog, focus restore); the Show
//       menu drops volumes it no longer lists (volumeShowFilterDidChange)
//    R  filterTargetPaths, thumbnail prewarm, ⌘I Catalog Info, volume menus,
//       the Showing box's "All volumes" / "N volumes" pill
//    onChange  CatalogView: clears filterByIDs, starts the thumbnail prewarm
//  filterTargetPaths   derived (computed var) — EMPTY = every volume
//    R  CatalogContent.computeFiltered (prefix filter skipped when empty:
//       no extra pass for the all-files default)
//    onChange  CatalogContent → refreshRows()
//  tableData           CatalogTableState @State (below)
//    W  refreshRows() only (every filter/search/record trigger)
//    R  the files Table
//  selectedIDs         CatalogView @State, @Binding into CatalogContent
//    W  files Table (click / ↑↓ / ⌘A); refreshRows() keeps only rows still
//       visible; navigation verbs; inspector "select record"
//    R  ⌘⌫ / ⌘O focused values, toolbar verbs, inspector, Hallie mirror
//    onChange  CatalogContent: stop player, preview (onSelect /
//              onClearPreview), live-preview follow.
//              CatalogView: hallieCurrentSelectionID, catalogSelectedIDs,
//              highlightedTargetPath (the volume row's "this file lives
//              here" tint — a paint, never a selection or focus change).
//  focusedPane         CatalogView @FocusState (ContentView.swift) — ONE
//    W  AppKit/SwiftUI only: a click in a Table focuses that Table;
//       .defaultFocus(.files) once. NO code assigns it.
//    R  files Table publishes ⌘⌫/⌘O targets only while it has focus
//       (focusedValue); the Space monitor (via paneFocusMirror) fires only
//       for .files.
//
// Edges REMOVED 2026-10-06 (each was a cross-pane side effect):
//   ✗ selectedIDs onChange → filesTableFocused = true   (a volume click
//     re-filtered the files, the selection changed, focus jumped down —
//     ↑/↓ then walked the FILES while the volume row was highlighted)
//   ✗ onAppear → filesTableFocused = true
//   ✗ Space monitor accepting ANY NSTableView (the volumes table counted)
// Edge ADDED: refreshRows() drops selected files the filter hid — a hidden
// selection is a ⌘⌫ trap — without touching focus.
// ──────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The two keyboard-focus targets on the Catalog tab. Bound with
/// `.focused($focusedPane, equals:)` on each Table; the one
/// `@FocusState var focusedPane: CatalogPane?` lives in CatalogView, the
/// common ancestor of both tables. (≈ a C++ enum class used as the key of
/// a "who owns the keyboard" register; nil = neither table.)
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
}

extension CatalogContent {
    // Forwarders: every existing read/write site keeps its spelling. A
    // `nonmutating set` ≈ a C++ setter on a const object that writes
    // through a pointer — @State storage lives outside the view struct,
    // which is why the (immutable) view can assign to it.

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

    /// Recompute the rows, then keep the file selection only for rows the
    /// filter still shows. Never touches keyboard focus: a filter change
    /// (e.g. a volume click above) must not move the user's keyboard.
    func refreshRows() {
        tableData = computeFiltered()
        let kept = CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData)
        if kept != selectedIDs { selectedIDs = kept }
    }
}

/// Pure rule behind refreshRows' selection step — headless-testable.
enum CatalogSelectionPrune {
    /// The subset of `selection` that is still a visible row. O(rows) only
    /// when something is selected; an empty selection costs nothing.
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
