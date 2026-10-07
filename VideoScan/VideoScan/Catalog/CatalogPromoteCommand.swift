// CatalogPromoteCommand.swift
// File ▸ Archive ▸ Promote Selected to Archive — scoped to the files the
// user can SEE highlighted in the Catalog, in the pane that has the
// keyboard (2026-10-06; Fable review §5, safety-critical).
//
// Workflow, in Rick's words: "promote the files I can see highlighted in
// the Catalog to the Master Archive."
//
// The bug this replaces: the menu read `model.catalogSelectedIDs`, a plain
// mirror of the files table's selection written on every change. After a
// volume click narrowed the table, the mirror still held files the filter
// hid, and it did not care which pane had the keyboard — so Promote could
// act on rows Rick could not see (harness case 7 was red on main).
//
// Now the files table publishes a FOCUSED value (same shape as ⌘⌫ and ⌘O,
// CatalogTrashCommand.swift / CatalogOpenCommand.swift): no files-pane
// focus → no value → the item is disabled. At click time the IDs are
// recomputed as visible ∩ selected (CatalogPromoteScope), so even a stale
// selection can never reach `requestPromote`. Everything after that —
// read-only refusal, no-master alert, identity check, the confirmation
// sheet — is the existing path, unchanged.
//
// Outcomes:
//   • enabled + visible rows  → requestPromote(visible IDs) → confirmation sheet
//   • files pane not focused  → item disabled (nothing to act on)
//   • nothing visible at click → refused, one console line, nothing promoted
//   • read-only viewer        → item disabled (and requestPromote refuses too)

import SwiftUI
import VideoScanCore

/// What the focused files table offers the Archive menu.
struct CatalogPromoteSelection {
    /// Highlighted rows (cheap; drives enabled state only).
    let count: Int
    /// visible ∩ selected, computed when the item is clicked.
    let visibleRecordIDs: () -> [UUID]
}

struct CatalogPromoteSelectionKey: FocusedValueKey {
    typealias Value = CatalogPromoteSelection
}

extension FocusedValues {
    var catalogPromoteSelection: CatalogPromoteSelection? {
        get { self[CatalogPromoteSelectionKey.self] }
        set { self[CatalogPromoteSelectionKey.self] = newValue }
    }
}

/// Pure rule — headless-testable.
enum CatalogPromoteScope {
    /// The selected records that are visible rows, in row order.
    /// O(rows), run only when the menu item is clicked.
    static func recordIDs(selection: Set<UUID>, visibleRows: [VideoRecord]) -> [UUID] {
        guard !selection.isEmpty else { return [] }
        return visibleRows.lazy.map(\.id).filter { selection.contains($0) }
    }
}

/// The Archive ▸ Promote Selected item. Its own View so `@FocusedValue`
/// can be read inside the Commands builder.
struct CatalogPromoteMenuItem: View {
    @ObservedObject var model: VideoScanModel
    @FocusedValue(\.catalogPromoteSelection) private var selection

    var body: some View {
        Button("Promote Selected to Archive") { promote() }
            .disabled(model.isReadOnly || (selection?.count ?? 0) == 0)
            .help("Promote the files highlighted in the Catalog's file list to the Master Archive. Files a filter or search hides are never included.")
    }

    private func promote() {
        let ids = selection?.visibleRecordIDs() ?? []
        guard !ids.isEmpty else {
            model.log("Promote refused — no visible files are highlighted in the Catalog.")
            return
        }
        model.requestPromote(recordIDs: ids)
    }
}
