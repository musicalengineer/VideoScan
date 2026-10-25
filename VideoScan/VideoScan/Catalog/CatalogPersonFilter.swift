// CatalogPersonFilter.swift
// The Catalog's "Person ▾" picker (Rick 2026-10-24, DECISIONS "People tab vs
// Catalog"): one person at a time, to the LEFT of the generic search box; the
// search box is unchanged. Choosing a person narrows the table to the records
// associated with them — confirmed tags AND the machine's face matches
// ("machine assisted people association by footage/videos is fine in Cat
// window"); a "<name> Isn't in This Video" rejection always wins over a face
// match. Maybes (suspected) are guesses and stay out.
//
// ONE MATCHER. The association is `PersonVideos.associates` — the People
// tab's own tier rule over the same name keys (name, display name, aliases;
// exact, never substrings). This file never compares a name itself.
//
// STATE. `CatalogPersonFilterStore` is a small feature store (#337 — no new
// VideoScanModel state). ContentView's root owns it as a @StateObject, so it
// lives in memory only: launch always shows Everyone (the same rule as the
// Volumes-pane selection). It does survive a tab switch, which the People
// page's "See all … in the Catalog →" needs: the People tab sets it, then
// switches to the Catalog tab, whose view is rebuilt on every switch.
//
// COST. `apply` is one O(rows) pass inside the event-driven computeFiltered,
// never a view body: per row a few array reads; a lowercased() only for the
// rare row that carries a person name. The store holds one small value per
// person (uuid, name, a handful of keys) — a few KB for a family, the worst
// case; the filtered array is the table's own row snapshot (8 B per row).
//
// (For Rick: an `ObservableObject` with `@Published` ≈ a C++ class whose
// setters notify subscribers; `@MainActor` ≈ "only ever touched on the UI
// thread", checked by the compiler.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore

/// One person the picker offers, as plain values.
struct CatalogPerson: Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    /// What the menu, the pill and the empty note say.
    let name: String
    /// PersonVideos.tagKeys — the lowercased names they are tagged under.
    let keys: Set<String>

    /// A profile with no usable name still gets a menu line.
    static let unnamed = "Unnamed person"

    init(id: UUID, name: String, keys: Set<String>) {
        self.id = id
        self.name = name
        self.keys = keys
    }

    init(_ profile: POIProfile) {
        let display = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: profile.uuid,
                  name: display.isEmpty ? (short.isEmpty ? Self.unnamed : short) : display,
                  keys: PersonVideos.tagKeys(for: profile))
    }
}

/// The picker's state. Session-only by construction: nothing here reads or
/// writes UserDefaults, AppStorage or SceneStorage.
@MainActor
final class CatalogPersonFilterStore: ObservableObject {
    /// Every person on the People tab, in the People tab's order.
    @Published private(set) var people: [CatalogPerson] = []
    /// nil = Everyone (no filter).
    @Published private(set) var selected: CatalogPerson?

    init() {}

    /// The People tab's list (POIProfile.listAll order). A selected person
    /// whose profile is gone falls back to Everyone; a renamed one keeps
    /// the selection under the new name. O(people).
    func reload(_ profiles: [POIProfile]) {
        let labels = PersonPickerNames.labels(profiles)
        let fresh = profiles.map { profile in
            CatalogPerson(id: profile.uuid, name: labels[profile.uuid] ?? profile.displayName,
                          keys: PersonVideos.tagKeys(for: profile))
        }
        if fresh != people { people = fresh }
        guard let chosen = selected else { return }
        let now = fresh.first { $0.id == chosen.id }
        if now != chosen { selected = now }   // nil when the profile is gone
    }

    /// Choose a person (nil = Everyone). Taken as given: the People page
    /// hands its own person over before the Catalog has loaded the list;
    /// the next `reload` confirms or drops them.
    func select(_ person: CatalogPerson?) {
        if person != selected { selected = person }
    }

    /// Choose by id from the loaded list; an unknown id is Everyone.
    func select(id: UUID?) {
        select(id.flatMap { id in people.first { $0.id == id } })
    }
}

/// The filter step computeFiltered runs (pure, no model).
enum CatalogPersonFilter {
    /// Everyone (nil) is the identity; otherwise the rows associated with
    /// `person`, in their order. O(rows).
    nonisolated static func apply(_ input: [VideoRecord], person: CatalogPerson?) -> [VideoRecord] {
        guard let person else { return input }
        let keys = person.keys
        guard !keys.isEmpty else { return [] }
        return input.filter { PersonVideos.associates($0, keys: keys) }
    }
}

// MARK: - The menu

/// The "Person ▾" pull-down left of the Catalog's search box. Value-only:
/// the people and the choice come in, the pick goes out — it observes
/// nothing and reads no records. Everyone first, then the People tab's
/// order; the chosen line carries the checkmark (an inline Picker in a
/// Menu, the same idiom as the Show menu's media kind).
struct CatalogPersonMenu: View {
    let people: [CatalogPerson]
    let selected: CatalogPerson?
    let onSelect: (UUID?) -> Void

    /// What the closed menu says for no filter.
    static let everyone = "Everyone"
    /// Fixed so the search capsule beside it keeps its column
    /// (CatalogToolbar.searchLeftInset accounts for it).
    static let width: CGFloat = 170

    private var choice: Binding<UUID?> {
        Binding(get: { selected?.id }, set: { onSelect($0) })
    }

    var body: some View {
        Menu {
            Picker("Person", selection: choice) {
                Text(Self.everyone).tag(UUID?.none)
                if !people.isEmpty { Divider() }
                ForEach(people) { person in
                    Text(person.name).tag(Optional(person.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                Text(selected?.name ?? Self.everyone)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundColor(selected == nil ? .primary : .accentColor)
        }
        .menuStyle(.button)
        .vsGlassButtonStyle()
        .frame(width: Self.width, alignment: .leading)
        .help("Show one person\u{2019}s videos \u{2014} tagged, or found by face. Everyone shows the whole catalog.")
        .accessibilityLabel("Person: \(selected?.name ?? Self.everyone)")
        .accessibilityIdentifier("catalog.personMenu")
    }
}
