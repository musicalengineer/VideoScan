// ArchiveHomeState.swift
// Archive tab — the entry / hand-off state machine (Rick 2026-08-26:
// "the default in the archive view should be the archive, not the list
// of files as if it is the Triage view").
//
// Why a separate, SwiftUI-free type: ContentView renders tabs through
// `switch selectedTab`, so ArchiveView is REBUILT on every tab entry and
// its @State starts over. Whatever decides "what does the tab show when
// it appears" therefore runs every time, and it must be deterministic
// and testable without a view. This is that decision, as a pure
// function: inputs in, an ArchiveTabState out. ArchiveView copies the
// result into its @State / @AppStorage. (C++ analogy: a stateless policy
// object; the view is the caller that owns the storage.)
//
// Rules (docs/archive-view.md, "Home"):
//   1. Nothing pending, nothing focused → HOME: Archived + Timeline.
//      Never Files, never another category — the archive is the story.
//   2. Hand-off to an ARCHIVED item (Catalog "Show in Archive", Hallie,
//      focus restore) → stay HOME, select it on the timeline and scroll
//      to it. The persisted Timeline/Files choice does not override
//      this: a hand-off always shows the story view.
//   3. Hand-off to an item that is NOT archived → that item's category
//      list, with `detour` set so the table shows "Showing <category> —
//      Back to archive". This is the ONLY way the tab opens on a list.
//   4. Back to archive → HOME again (and the caller clears the app-wide
//      focus so the next entry is HOME too).
//
// The selected category is deliberately NOT persisted across launches
// or tab switches: it is view state, and persisting it is exactly what
// would strand a user in a list. Only the Timeline/Files switch persists
// (`archive.viewMode`), and only for in-session use of the Archived
// category — entry always resets it to Timeline (rule 1/2).

import Foundation

/// The Archived category's two readings. Raw values are the persisted
/// `archive.viewMode` strings, unchanged from before this file existed.
enum ArchiveViewMode: String {
    case timeline = "timeline"
    case files    = "files"
}

/// Everything ArchiveView needs to set after an entry or hand-off.
struct ArchiveTabState: Equatable {
    var category: ArchiveCategory = .archived
    var viewMode: ArchiveViewMode = .timeline
    var selectedIDs: Set<UUID> = []
    var searchText: String = ""
    /// Non-nil while the tab is showing a non-archived category because
    /// a hand-off asked for it. Drives the "Showing … — Back to archive"
    /// banner. Nil at HOME and after any sidebar click.
    var detour: ArchiveCategory? = nil
    /// The timeline item to scroll into view (rule 2). Nil otherwise.
    var scrollTarget: UUID? = nil

    static let home = ArchiveTabState()

    var isHome: Bool { category == .archived && viewMode == .timeline && detour == nil }
}

/// What the tab was asked to show, gathered by ArchiveView from the model
/// at entry time. Plain values so tests need no VideoScanModel.
struct ArchiveTabEntry {
    /// `model.pendingArchiveSelection` — a one-shot "Show in Archive".
    var pendingSelection: UUID? = nil
    /// `model.pendingArchiveSearch` — optional search that accompanies
    /// the pending selection (a catalog search with several archived hits).
    var pendingSearch: String? = nil
    /// `model.focusedMediaIDs` — the app-wide focus set left by the last
    /// navigation in any tab. Empty = none.
    var focusedIDs: Set<UUID> = []
    /// `archive.viewMode` as persisted. Consulted only to keep the
    /// mid-session Files choice when the tab is NOT re-entering (unused
    /// by entry today; here so the isolation test can prove it is ignored).
    var persistedViewMode: String? = nil
}

enum ArchiveHomeState {

    /// Rule 1–3. `isArchived` answers "does this id have a Master Archive
    /// copy?"; `category` maps an id to its sidebar row; `focusSet` widens
    /// an id to its A/V pair set (VideoScanModel.focusSet(for:)).
    static func resolveEntry(_ entry: ArchiveTabEntry,
                             isArchived: (UUID) -> Bool,
                             category: (UUID) -> ArchiveCategory,
                             focusSet: (UUID) -> Set<UUID>) -> ArchiveTabState {
        // A pending selection wins over a lingering focus set — it is the
        // more recent, more deliberate request.
        if let id = entry.pendingSelection {
            return handOff(to: id,
                           selection: focusSet(id),
                           search: entry.pendingSearch ?? "",
                           isArchived: isArchived(id),
                           category: category(id))
        }
        if let first = entry.focusedIDs.first {
            // Focus restore: same rules, but the focus set is already
            // the selection and there is no accompanying search.
            let target = entry.focusedIDs.first(where: isArchived) ?? first
            return handOff(to: target,
                           selection: entry.focusedIDs,
                           search: "",
                           isArchived: isArchived(target),
                           category: category(target))
        }
        return .home
    }

    /// Rule 4 — also what a sidebar click on Archived produces.
    static func backToArchive() -> ArchiveTabState { .home }

    /// A sidebar click on any category: plain list/timeline for that
    /// row, no detour banner (the user chose it), selection cleared.
    /// `viewMode` is the current in-session choice, honored only for the
    /// Archived row (other rows are table-only).
    static func sidebarPick(_ category: ArchiveCategory, viewMode: ArchiveViewMode) -> ArchiveTabState {
        ArchiveTabState(category: category,
                        viewMode: category == .archived ? viewMode : .files,
                        selectedIDs: [],
                        searchText: "",
                        detour: nil,
                        scrollTarget: nil)
    }

    private static func handOff(to id: UUID,
                                selection: Set<UUID>,
                                search: String,
                                isArchived: Bool,
                                category: ArchiveCategory) -> ArchiveTabState {
        if isArchived {
            return ArchiveTabState(category: .archived,
                                   viewMode: .timeline,
                                   selectedIDs: selection,
                                   searchText: search,
                                   detour: nil,
                                   scrollTarget: id)
        }
        // Not archived: the timeline cannot show it. Detour to its list
        // and say so, so the way back is one click.
        let list = category == .archived ? .notYetArchived : category
        return ArchiveTabState(category: list,
                               viewMode: .files,
                               selectedIDs: selection,
                               searchText: search,
                               detour: list,
                               scrollTarget: nil)
    }
}
