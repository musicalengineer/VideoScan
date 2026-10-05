// CatalogRowMenuPlan.swift
// The DECISIONS behind the Catalog row context menu, as plain data (R1
// refactor, GH #281; the "explicit action plans" direction of the
// 2026-09-13 refactoring assessment §4). No SwiftUI, no model, no disk:
// every type here is unit-testable on its own (CatalogRowMenuPlanTests).
// The menu builders in CatalogRowContextMenu*.swift read these values;
// what they build is unchanged.

import Foundation

/// A right-click selection split by lifecycle state, and which of the
/// four menus it gets. O(selection), computed once per menu open so the
/// Restore / Remove items' labels count exactly the rows their actions
/// operate on. (C++: a small struct of vectors filled in the constructor
/// — Swift's `.filter` ≈ std::copy_if into a new vector.)
struct CatalogRowMenuSelection {

    /// Which right-click menu the selection gets.
    enum Shape: Equatable {
        /// Pure removed selection: Restore + Reveal.
        case purged
        /// Pure set-aside selection: Put Back + Reveal.
        case setAside
        /// Pure superseded selection: Show Repaired Copy + Restore + Reveal (GH #132).
        case superseded
        /// Active or mixed selection: the full menu.
        case full
    }

    /// The selected records, in selection order.
    let selected: [VideoRecord]
    /// Neither removed, set aside nor superseded.
    let active: [VideoRecord]
    let purged: [VideoRecord]
    /// Set aside and NOT removed (a removed row counts as removed only).
    let setAside: [VideoRecord]
    /// Superseded and neither removed nor set aside.
    let superseded: [VideoRecord]

    init(selected: [VideoRecord]) {
        self.selected = selected
        active = selected.filter { !$0.isPurged && !$0.isSetAside && !$0.isSuperseded }
        purged = selected.filter { $0.isPurged }
        setAside = selected.filter { $0.isSetAside && !$0.isPurged }
        superseded = selected.filter { $0.isSuperseded && !$0.isPurged && !$0.isSetAside }
    }

    /// No inert row rode along. Active-only actions (Combine, Rename,
    /// Tag, …) are gated on this so a multi-select that pulled in a
    /// removed / set-aside / superseded row never applies them to it.
    var pureActive: Bool {
        purged.isEmpty && setAside.isEmpty && superseded.isEmpty
    }

    /// The menu for a right-click whose anchor row is `anchor` (the row
    /// the table reports first). nil = no menu items at all.
    func shape(anchor: VideoRecord) -> Shape? {
        guard !active.isEmpty || anchor.isPurged || anchor.isSetAside || anchor.isSuperseded else {
            return nil
        }
        if anchor.isPurged && active.isEmpty { return .purged }
        if anchor.isSetAside && active.isEmpty { return .setAside }
        if anchor.isSuperseded && active.isEmpty { return .superseded }
        return .full
    }
}
