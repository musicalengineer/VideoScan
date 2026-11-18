// PersonCatalogLink.swift
// "See all N videos of <name> in the Catalog →" under a person's People page
// (Rick 2026-10-24, DECISIONS "People tab vs Catalog"): the page is a short
// curated list; the full machine-assisted set lives in the Catalog, reached
// through its Person ▾ picker (CatalogPersonFilter.swift).
//
// The link sets the picker to this person — nothing else: the search text,
// the Show options and the volume selection are left as they are. (It used to
// turn Show ▸ Folders Only off, which hid a person's loose files; the one
// folder view of 2026-11-17 lists loose files too, so there is nothing to
// turn off.)
//
// (For Rick: a caseless `enum` with a static ≈ a C++ free function in a
// namespace; `@MainActor` because the store is UI state.)

import Foundation
import SwiftUI

enum CatalogPersonLink {
    /// Point the Catalog at `profile` and return the tab to show; the People
    /// view writes the tab. A seam: the test calls it directly, no SwiftUI.
    @MainActor
    static func showAll(of profile: POIProfile, in store: CatalogPersonFilterStore) -> Int {
        let person = CatalogPerson(profile)
        store.select(person)
        appLog.write("People tab: See all in the Catalog \u{2014} Person \u{25BE} \(person.name)")
        return MainTab.catalog.rawValue
    }
}

// MARK: - A reference without a subscription

/// The People page only CALLS the store (on the link's click); it shows
/// none of its state. An environment VALUE holding the class reference gives
/// the reference without re-rendering the page on each publish — the same
/// pattern as MediaFileOperationsCenterReference.swift. (C++: a plain
/// pointer instead of registering as an observer.)
private struct CatalogPersonFilterReferenceKey: EnvironmentKey {
    /// nil outside the app's window (a preview, a test host): the link then
    /// refuses out loud rather than switch tabs with no person set.
    static let defaultValue: CatalogPersonFilterStore? = nil
}

extension EnvironmentValues {
    /// The Catalog's Person ▾ store, NON-observing. ContentView injects it
    /// beside the `.environmentObject` the Catalog view observes.
    var catalogPersonFilterReference: CatalogPersonFilterStore? {
        get { self[CatalogPersonFilterReferenceKey.self] }
        set { self[CatalogPersonFilterReferenceKey.self] = newValue }
    }
}
