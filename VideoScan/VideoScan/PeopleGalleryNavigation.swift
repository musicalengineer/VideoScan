// PeopleGalleryNavigation.swift
// Pure helpers behind the People-gallery card gestures (Rick, 2026-09-13):
//
//   * Double-click a person card → open that person's editor, exactly
//     the way the card's context-menu "Edit <name>…" does. Both paths
//     build the same `PersonEditRequest`, so a test can prove they
//     resolve to the same person — by uuid, never by name (two Richards).
//
// Nothing here touches views, disk, or the model: the view hands in the
// profile and gets a decision back. (For Rick: a caseless `enum` is
// Swift's idiom for a C++ namespace of free functions — it can't be
// instantiated, which is the point.)

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
