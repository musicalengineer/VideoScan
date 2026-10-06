// CatalogInfoCommand.swift
// ⌘I = Catalog Info, as Finder's ⌘I is Get Info (Rick 2026-10-06).
//
// Until now ⌘I had two owners: a hidden zero-size Button("") in the
// volumes pane and File ▸ Import Catalog…. Views get key equivalents
// before the menu bar, so which one fired depended on which hosting view
// answered first. Now there is ONE owner: this File-menu item, enabled
// only while the volumes table has the keyboard and exactly one volume is
// highlighted. The volumes table publishes the action as a FOCUSED value
// (same shape as ⌘⌫ / ⌘O / Promote). Import Catalog… moved to ⇧⌘I.
//
// (For Rick: `FocusedValueKey` ≈ a typed slot the focused view fills and
// the menu reads; nil when that view does not have the keyboard.)

import SwiftUI

/// What the focused volumes table offers File ▸ Catalog Info.
struct CatalogVolumeInfo {
    /// True when exactly one volume is highlighted.
    let isAvailable: Bool
    let perform: () -> Void
}

struct CatalogVolumeInfoKey: FocusedValueKey {
    typealias Value = CatalogVolumeInfo
}

extension FocusedValues {
    var catalogVolumeInfo: CatalogVolumeInfo? {
        get { self[CatalogVolumeInfoKey.self] }
        set { self[CatalogVolumeInfoKey.self] = newValue }
    }
}

/// File ▸ Catalog Info ⌘I. Its own View so `@FocusedValue` can be read
/// inside the Commands builder.
struct CatalogInfoMenuItem: View {
    @FocusedValue(\.catalogVolumeInfo) private var info

    var body: some View {
        Button("Catalog Info") { info?.perform() }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!(info?.isAvailable ?? false))
            .help("Show where, when and how the highlighted volume was cataloged, and what it holds. Click one volume in the Catalog's volume list first.")
    }
}
