// CatalogInfoCommand.swift
// ⌘I = Get Info on whatever is highlighted, as in Finder (Rick 2026-10-06,
// widened 2026-10-07):
//   - the volumes table has the keyboard, one volume highlighted
//       → "Catalog Info" (where, when and how it was cataloged);
//   - the files table has the keyboard, one file highlighted
//       → "Get Media Info…" (container, streams, last Check Media verdict).
//
// Until 2026-10-06 ⌘I had two owners: a hidden zero-size Button("") in the
// volumes pane and File ▸ Import Catalog…. Views get key equivalents
// before the menu bar, so which one fired depended on which hosting view
// answered first. Now there is ONE owner: this File-menu item. Each table
// publishes its action as a FOCUSED value (same shape as ⌘⌫ / ⌘O /
// Promote); only the table with the keyboard has one, so the two can never
// both be live. Import Catalog… moved to ⇧⌘I.
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

/// What the focused files table offers File ▸ Get Media Info (2026-10-07).
struct CatalogFileInfo {
    /// True when exactly one file is highlighted.
    let isAvailable: Bool
    let perform: () -> Void
}

struct CatalogFileInfoKey: FocusedValueKey {
    typealias Value = CatalogFileInfo
}

extension FocusedValues {
    var catalogVolumeInfo: CatalogVolumeInfo? {
        get { self[CatalogVolumeInfoKey.self] }
        set { self[CatalogVolumeInfoKey.self] = newValue }
    }
    var catalogFileInfo: CatalogFileInfo? {
        get { self[CatalogFileInfoKey.self] }
        set { self[CatalogFileInfoKey.self] = newValue }
    }
}

/// Which ⌘I the File menu offers — pure, so the rule is testable.
enum CatalogInfoTarget: Equatable {
    case volume, file, none

    /// The files table wins when it has a value (it has the keyboard);
    /// otherwise the volumes table; otherwise the item reads as Catalog
    /// Info, greyed.
    static func resolve(volumeAvailable: Bool?, fileAvailable: Bool?) -> CatalogInfoTarget {
        if fileAvailable != nil { return fileAvailable == true ? .file : .none }
        if volumeAvailable == true { return .volume }
        return .none
    }
}

/// File ▸ Catalog Info / Get Media Info ⌘I. Its own View so
/// `@FocusedValue` can be read inside the Commands builder.
struct CatalogInfoMenuItem: View {
    @FocusedValue(\.catalogVolumeInfo) private var volumeInfo
    @FocusedValue(\.catalogFileInfo) private var fileInfo

    private var target: CatalogInfoTarget {
        .resolve(volumeAvailable: volumeInfo?.isAvailable, fileAvailable: fileInfo?.isAvailable)
    }

    var body: some View {
        if fileInfo != nil {
            Button("Get Media Info\u{2026}") { fileInfo?.perform() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(target != .file)
                .help("Show what the highlighted file is made of and its last Check Media verdict. Click one file in the Catalog first.")
        } else {
            Button("Catalog Info") { volumeInfo?.perform() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(target != .volume)
                .help("Show where, when and how the highlighted volume was cataloged, and what it holds. Click one volume in the Catalog's volume list first.")
        }
    }
}
