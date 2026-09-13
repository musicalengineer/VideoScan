// PeopleGalleryNavigation.swift
// Pure helpers behind the People-gallery card gestures (Rick, 2026-09-13):
//
//   * Double-click a person card → open that person's editor, exactly
//     the way the card's context-menu "Edit <name>…" does. Both paths
//     build the same `PersonEditRequest`, so a test can prove they
//     resolve to the same person — by uuid, never by name (two Richards).
//   * ← / → move the gallery selection between cards in the DISPLAYED
//     order (sorted + filtered), stopping at the ends — no wrap. No
//     selection → either arrow lands on the first card.
//
// Nothing here touches views, disk, or the model: the view hands in the
// displayed profiles and the current selection and gets a decision back.
// (For Rick: a caseless `enum` is Swift's idiom for a C++ namespace of
// free functions — it can't be instantiated, which is the point.)

import Foundation

/// What the People gallery needs to open the editor for one person.
/// Carries the profile's uuid (the durable identity) plus the name the
/// editor's rename logic compares against afterwards. Equatable so the
/// double-click and menu paths can be compared in a test.
struct PersonEditRequest: Equatable {
    let profileUUID: UUID
    /// `POIProfile.name` at the moment the editor opened — the same
    /// value the context menu stored in `editingOriginalName`.
    let originalName: String

    init(_ profile: POIProfile) {
        profileUUID = profile.uuid
        originalName = profile.name
    }
}

/// Where a click on a person card leads.
enum PeopleCardAction: Equatable {
    /// Load this person as the active profile (the single-click behaviour).
    case select
    /// Open the editor for this person (double-click / menu Edit).
    case edit(PersonEditRequest)
    /// The person is being scanned right now — editing is refused until
    /// the scan finishes (same rule as the single click).
    case refuseWhileScanning

    enum Click: Equatable { case single, double }

    /// Resolve a click on `profile`. A double-click on a card that is
    /// being scanned is refused just like a single click is — the reference
    /// strip must not change under a running job.
    static func resolve(_ click: Click, on profile: POIProfile, isBeingScanned: Bool) -> PeopleCardAction {
        if isBeingScanned { return .refuseWhileScanning }
        switch click {
        case .single: return .select
        case .double: return .edit(PersonEditRequest(profile))
        }
    }
}

enum PeopleGalleryNavigation {

    enum Step: Equatable { case previous, next }

    /// The index the arrow key lands on, or nil for "no change".
    ///
    ///   - empty list → nil
    ///   - no current selection (or one not in the list) → 0, either key
    ///   - `.next` on the last card / `.previous` on the first → nil
    ///     (stop, no wrap)
    static func targetIndex(current: Int?, count: Int, step: Step) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return 0 }
        switch step {
        case .next:     return current + 1 < count ? current + 1 : nil
        case .previous: return current > 0 ? current - 1 : nil
        }
    }

    /// The profile the arrow key should select, in `displayed` order, or
    /// nil for "no change". The current selection is matched by uuid only.
    static func neighbor(of selectedUUID: UUID?, in displayed: [POIProfile], step: Step) -> POIProfile? {
        let current = selectedUUID.flatMap { id in displayed.firstIndex { $0.uuid == id } }
        guard let target = targetIndex(current: current, count: displayed.count, step: step) else { return nil }
        return displayed[target]
    }
}
