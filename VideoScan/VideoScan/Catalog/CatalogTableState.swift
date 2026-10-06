// CatalogTableState.swift
// The Catalog files table's own view state in one place (R1 refactor,
// GH #281): the rows snapshot it draws, the badge revision its cells
// read, and its keyboard-focus flag. Moved out of CatalogContent's
// declaration list in CatalogHelpers.swift; behaviour unchanged.
//
// Next step it is shaped for (NOT done here — no focus change in R1):
// the volume-pane focus owner (`enum Pane`) replaces `filesTableFocused`
// in this one type. The table's selection and sort order are NOT here:
// they are @Bindings owned by ContentView and passed in.

import SwiftUI

/// The files table's view-owned state. A custom `DynamicProperty` ≈ a C++
/// member struct whose fields the framework re-binds before every body
/// evaluation: SwiftUI finds the `@State` / `@FocusState` inside it
/// exactly as if they were declared directly on CatalogContent, so their
/// storage (and the focus wiring) is the same as before the move.
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

    /// The files table claims keyboard focus when a file is picked
    /// (Rick 2026-10-05: ↑/↓ moved the VOLUMES table — the window's first
    /// key view kept focus because clicking a file row never moved it).
    /// Bind with `tableState.$filesTableFocused`.
    @FocusState var filesTableFocused: Bool
}

extension CatalogContent {
    // Forwarders: every existing read/write site keeps its spelling. A
    // `nonmutating set` ≈ a C++ setter on a const object that writes
    // through a pointer — @State / @FocusState storage lives outside the
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

    /// See `CatalogTableState.filesTableFocused`.
    var filesTableFocused: Bool {
        get { tableState.filesTableFocused }
        nonmutating set { tableState.filesTableFocused = newValue }
    }
}
