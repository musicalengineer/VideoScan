// PeopleEntry.swift
// ONE selection value for the People gallery (Rick 2026-10-07: "the Family
// entries … should act the same as People in arrow keys and such … this
// might be necessary underneath but in the UI can we treat them the same?").
//
// In the UI a family is a PEER of a person: one card strip, one selection,
// ← / → walk both in one order, the same double-click (open its editor) and
// the same detail pane below (Videos of <person> / Videos of <family>).
//
// UNDERNEATH they stay apart, on purpose. A person is a POIProfile (face
// matching, Hallie's alias joins, tree identity); a family is a FamilyGroup
// in POI/Families/ (FamilyGroup.swift). This file only ever carries the two
// kinds of uuid side by side — it never builds, reads or writes a profile
// for a family (sensor: PeopleEntryTests.aFamilyIsNeverResolvedToAProfile
// and FamilyGroupTests.familiesAreNotPeople).
//
// Storage is the two keys the tab already had, unchanged:
//   * `people.selectedFamilyUUID` (AppStorage) — non-empty and naming a
//     live family ⇒ the family is selected;
//   * `settings.activeProfileUUID` — otherwise the selected person (it also
//     drives the reference-faces strip, so a family selection leaves it
//     alone rather than clearing a person's loaded faces).
//
// Order: families first (oldest first, FamilyGroupStore.listAll), then
// people in the gallery's own order (Rick's drag order, after the "Show
// Missing GEDCOM" filter). That is the order the cards were already drawn
// in on 10/4; the arrows now simply stop skipping the family cards.
//
// Pure: no views, disk or model. (A caseless `enum` ≈ a C++ namespace of
// free functions; an enum with associated values ≈ a tagged union whose
// tag the compiler forces every `switch` to handle.)

import Foundation

/// One card in the People gallery: a person or a family, by uuid.
enum PeopleEntry: Hashable, Sendable {
    case person(UUID)
    case family(UUID)

    var isFamily: Bool {
        if case .family = self { return true }
        return false
    }
}

enum PeopleEntryList {

    /// The gallery's displayed order: families first, then people.
    static func ordered(families: [FamilyGroup], people: [POIProfile]) -> [PeopleEntry] {
        families.map { .family($0.uuid) } + people.map { .person($0.uuid) }
    }

    /// The selected entry, read from the two stored keys. A stored family
    /// that no longer exists (trashed) falls through to the person.
    static func selection(familyUUID: String,
                          familyIDs: [UUID],
                          activeProfileUUID: UUID?) -> PeopleEntry? {
        if let id = UUID(uuidString: familyUUID), familyIDs.contains(id) {
            return .family(id)
        }
        return activeProfileUUID.map { .person($0) }
    }

    /// What selecting `entry` writes back. A family writes ONLY the family
    /// key — `profileUUID` is nil, meaning "leave the person's settings
    /// alone"; a person clears the family key so its page wins.
    static func storage(for entry: PeopleEntry) -> (familyUUID: String, profileUUID: UUID?) {
        switch entry {
        case .family(let id): return (id.uuidString, nil)
        case .person(let id): return ("", id)
        }
    }

    /// The neighbouring entry for ← / →, or nil for "no change". Same
    /// rules as the person-only gallery had (PeopleGalleryNavigation):
    /// stop at the ends, no wrap; no / stale selection → the first entry.
    static func neighbor(of selected: PeopleEntry?,
                         in displayed: [PeopleEntry],
                         step: PeopleGalleryNavigation.Step) -> PeopleEntry? {
        let current = selected.flatMap { displayed.firstIndex(of: $0) }
        guard let target = PeopleGalleryNavigation.targetIndex(
            current: current, count: displayed.count, step: step) else { return nil }
        return displayed[target]
    }

    /// The person profile an entry names — nil for every family, even if
    /// some profile happened to share its uuid. The ONLY bridge from an
    /// entry to a POIProfile, so a family can never reach person code.
    static func profile(for entry: PeopleEntry?, in profiles: [POIProfile]) -> POIProfile? {
        guard case .person(let id)? = entry else { return nil }
        return profiles.first { $0.uuid == id }
    }

    /// The family an entry names — nil for every person.
    static func family(for entry: PeopleEntry?, in families: [FamilyGroup]) -> FamilyGroup? {
        guard case .family(let id)? = entry else { return nil }
        return families.first { $0.uuid == id }
    }
}
