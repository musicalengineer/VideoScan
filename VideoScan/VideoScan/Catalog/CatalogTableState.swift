// CatalogTableState.swift
// The Catalog files table's own view state in one place (R1 refactor,
// GH #281): the rows snapshot it draws, the badge revision its cells
// read — plus `CatalogPane`, the name of each keyboard-focus target in
// the Catalog's two panes (2026-10-06) — and, since the Footage folders
// view (2026-10-16; a two-level Finder since 2026-10-17, with Finder
// list-view triangles since 2026-10-18), the folder the table is inside,
// the folder rows, the folders twisted open and a derivative waiting to
// be shown.
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
/// (→ / ← / Esc / ⌘↓ / ⌘↑): whether Show ▸ Events & Copies as Folders is
/// on. The option is a plain `let` on CatalogContent, which the monitor's
/// captured copy would read stale; this box is mirrored on every change.
@MainActor
final class FootageFolderKeyMirror {
    var isOn = false
    /// Show ▸ Folders Only, for the same reason: a compose started from
    /// the monitor (a level change) must not bring the loose rows back.
    var foldersOnly = false
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

    /// Where the Finder is: nil = the top level (folders and loose files);
    /// `.event` = inside that folder (double-click / Return / ⌘↓);
    /// `.family` = one file's copies and versions (Show Copies & Related…).
    /// Back, ⌘↑, ← and Esc clear it; so does turning the option off, and
    /// a rebuilt join in which the event no longer exists.
    @State var folderScope: FootageFolders.Scope?
    /// The folder Table's rows — the published display turned into the
    /// current level's rows in an event handler
    /// (CatalogContent.rebuildFolderRows), never in a body.
    @State var folderRows: [FootageFolderTableRow] = []
    /// The event ids among `folderRows` (O(1) "is this id a folder?").
    @State var folderIDs: Set<UUID> = []
    /// The level `folderRows` was built from — kept so a twist of a
    /// disclosure triangle can recompute the displayed set without a
    /// compose round trip.
    @State var folderLevel = FootageFolderLevel.Level.empty
    /// The folders twisted open in place (Finder list view, Rick
    /// 2026-10-18). View state only: it survives refreshes and drilling in
    /// and out; a folder that has gone simply matches nothing. Cleared when
    /// the option goes off.
    @State var expandedFolderIDs: Set<UUID> = []
    /// The record ids on screen — loose files, plus the members of the
    /// EXPANDED folders at the top; the members inside a scope — under the
    /// filter, sort AND scope. With the option on this is THE displayed
    /// set every row action and prune reads (codex 2026-10-16 P1); off,
    /// the linear rows are. A folder row is never in it; neither is a
    /// collapsed folder's member.
    @State var folderRecordIDs: Set<UUID> = []
    /// A derivative that just landed and is to be selected as soon as the
    /// level shows it (its folder was entered; the join may still be
    /// placing the row). Cleared when it is selected, when Rick moves
    /// between levels, or when the option goes off.
    @State var pendingReveal: DerivativeLanding?
    /// A folder just made (Make Folder… / New Folder with Selection) that
    /// is to be selected and twisted open as soon as the level shows it
    /// (the join is asynchronous). Cleared when it is revealed or the
    /// option goes off.
    @State var pendingFolderReveal: UUID?
    /// Files just dropped on a folder, to be selected inside it as soon as
    /// the join shows them (CatalogContent+FolderDrop.swift). Cleared when
    /// selected, when Rick moves between levels, or when the option goes off.
    @State var pendingDropSelection: FolderDropLanding?
    /// Whether the option is on, for the key monitor (see FootageFolderKeyMirror).
    @State var folderKeyMirror = FootageFolderKeyMirror()
    /// Folders Only is on and its composed top level holds no folder: the
    /// table shows "No folders match" instead of a blank area. Set in the
    /// display / index handlers, never in a body.
    @State var foldersOnlyFindsNothing = false

    // MARK: Folders as labels (2026-10-19: a file in many folders)

    /// Every folder-table row id → its record and the folder it is shown
    /// under (a file in two open folders has two rows). Built with
    /// `folderRows`, in the event handler.
    @State var folderRowRefs: [UUID: FolderRowRef] = [:]
    /// The rows Rick clicked, so the highlight stays on the row he chose
    /// when the same file is shown twice (FolderRowSelection).
    @State var folderRowSelection: Set<UUID> = []
    /// Rename… on a folder (the sheet's payload).
    @State var folderRenameRequest: FolderRenameRequest?
    /// Delete Folder… on a folder (the confirmation's payload).
    @State var folderDeleteRequest: FolderDeleteRequest?
    /// The selected folder's inspector facts — computed once per selection
    /// and per folder or catalog revision, never in a body.
    @State var folderInspector: FolderInspectorFacts?
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
    /// view on, the folder display follows the new rows (a no-op otherwise)
    /// and prunes again against what it shows when it lands
    /// (`rebuildFolderRows` → `pruneSelectionToDisplay`).
    func refreshRows() {
        tableData = computeFiltered()
        // A selected folder row is not a record: it stays selected.
        let kept = CatalogSelectionPrune.visibleSelection(selectedIDs, rows: tableData)
            .union(selectedIDs.intersection(tableState.folderIDs))
        if kept != selectedIDs { selectedIDs = kept }
        refreshFolderDisplay()
    }

    // MARK: The displayed selection — ONE source of truth for every row action

    /// `ids` ∩ what the table shows right now: the folder display's record
    /// ids while Show ▸ Events & Copies as Folders is on (members and loose
    /// files under the filter, sort AND scope — never a folder row), the
    /// linear rows otherwise. Every row action — ⌘⌫, Promote, ⌘O, ⌘I,
    /// Return, the row menu — goes through this, never the raw selection
    /// (codex 2026-10-16 P1: a derivative selected while a scope hid it
    /// reached ⌘⌫). O(rows) only when `ids` is non-empty; event handlers
    /// only, never a body.
    func displayedIDs(among ids: Set<UUID>) -> Set<UUID> {
        CatalogSelectionPrune.displayed(ids, foldersOn: tableState.folderKeyMirror.isOn,
                                        folderRecordIDs: tableState.folderRecordIDs, rows: tableData)
    }

    /// The selection ∩ displayed.
    var displayedSelection: Set<UUID> { displayedIDs(among: selectedIDs) }

    /// The selected rows on screen, in table order.
    var displayedSelectedRecords: [VideoRecord] {
        let shown = displayedSelection
        return shown.isEmpty ? [] : tableData.filter { shown.contains($0.id) }
    }

    /// The folder display changed: keep only what it shows (a selected
    /// folder row stays). Called when the display lands, so a level change
    /// drops the ids it hid.
    func pruneSelectionToDisplay() {
        let kept = displayedSelection.union(selectedIDs.intersection(tableState.folderIDs))
        if kept != selectedIDs { selectedIDs = kept }
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

    /// THE displayed rule (codex 2026-10-16 P1): with the folder view on,
    /// only ids the folder display shows; either way only ids that are
    /// linear rows — the intersection, so a display that lags the rows
    /// (the compose is asynchronous) can never widen the set.
    static func displayed(_ ids: Set<UUID>, foldersOn: Bool, folderRecordIDs: Set<UUID>, rows: [VideoRecord]) -> Set<UUID> {
        guard !ids.isEmpty else { return ids }
        let shown = foldersOn ? ids.intersection(folderRecordIDs) : ids
        return visibleSelection(shown, rows: rows)
    }
}
