// ArchiveEntryController.swift
// The Archive tab's entry seam: consume the model's one-shot hand-off
// requests, THEN resolve (ArchiveHomeState) — never the other way round.
//
// Why this exists (QA + codex #700, 2026-08-26): ArchiveView observed
// `model.pendingArchiveSelection` with `.onChange` and re-ran the whole
// entry on every change. Consuming the request sets it to nil, which is
// itself a change, so the entry ran a second time from a model that no
// longer carried the search — and the second run overwrote the first
// (search "" instead of the catalog's narrowing). Consumption and
// observation were the same code path.
//
// Here they are separate: the caller snapshots the model into an
// ArchiveEntryRequest (plain values), this controller reads its locals,
// clears them, and resolves FROM THE LOCALS. The id→nil transition is a
// no-op by construction. (C++ analogy: a transaction object — copy in,
// decide, and the caller commits the mutated copy back once.)

import Foundation

/// The model's hand-off fields, copied out so the controller can consume
/// them without touching the model. The caller writes the mutated copy
/// back only when `Outcome.consumed` is true.
struct ArchiveEntryRequest: Equatable {
    /// `model.pendingArchiveSelection` — one-shot "Show in Archive".
    var pendingSelection: UUID? = nil
    /// `model.pendingArchiveSearch` — the narrowing that came with it.
    var pendingSearch: String? = nil
    /// `model.focusedMediaIDs` — app-wide focus left by the last navigation.
    var focusedIDs: Set<UUID> = []
}

enum ArchiveEntryController {

    /// What woke the entry. `.appear` is the tab being built; the other is
    /// the model's `pendingArchiveSelection` changing while the tab is up.
    enum Trigger: Equatable {
        case appear
        case pendingSelectionChanged(UUID?)
    }

    struct Outcome: Equatable {
        /// The state to copy into the view's storage.
        let state: ArchiveTabState
        /// True when a pending request was read and cleared — the caller
        /// must write `request` back to the model.
        let consumed: Bool
    }

    /// Nil means "do nothing" — today only for the id→nil transition the
    /// consumer itself causes. A non-nil trigger id is taken from the
    /// request snapshot, not the trigger, so the search travels with it.
    static func handle(_ trigger: Trigger,
                       request: inout ArchiveEntryRequest,
                       persistedViewMode: String?,
                       isArchived: (UUID) -> Bool,
                       category: (UUID) -> ArchiveCategory,
                       focusSet: (UUID) -> Set<UUID>) -> Outcome? {
        if case .pendingSelectionChanged(nil) = trigger { return nil }

        // Read into locals FIRST, then clear — the resolver sees the
        // request exactly as it was made, whatever the model does next.
        let pendingSelection = request.pendingSelection
        let pendingSearch = request.pendingSearch
        let focusedIDs = request.focusedIDs
        if let id = pendingSelection {
            request.pendingSelection = nil
            request.pendingSearch = nil
            // The focus set persists so a round-trip to the Catalog and
            // back lands on the same item (without the search, by design).
            request.focusedIDs = focusSet(id)
        }
        let entry = ArchiveTabEntry(pendingSelection: pendingSelection,
                                    pendingSearch: pendingSearch,
                                    focusedIDs: focusedIDs,
                                    persistedViewMode: persistedViewMode)
        let state = ArchiveHomeState.resolveEntry(entry,
                                                  isArchived: isArchived,
                                                  category: category,
                                                  focusSet: focusSet)
        return Outcome(state: state, consumed: pendingSelection != nil)
    }
}
