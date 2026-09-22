// CatalogDuplicatesMenu.swift
// The Catalog toolbar's "Duplicates" menu (Find Duplicates, Find
// Duplicates of Selected, Delete Duplicates on Volume…, the working-copy
// toggle and the re-analyze hint), extracted from CatalogToolbar.swift.
//
// WHY "Delete Duplicates on Volume…" IS A BUTTON, NOT A SUBMENU
// (Rick 2026-09-22, Release b334247b): "when I try to delete dups from the
// Duplicates menu, it flashes over 'Delete Duplicates on Volume…' and does
// not allow me to select a volume."
//
// On macOS a SwiftUI `Menu` is an NSPopUpButton + NSMenu that SwiftUI keeps
// in sync with the view graph. Measured in the test host 2026-09-22: with a
// nested submenu open, ANY SwiftUI update in the same window — even a
// sibling Text the menu does not depend on — closed the submenu and cleared
// the top menu's highlight; with no updates it stayed open. Isolating the
// menu (plain-value inputs, `.equatable()`) did NOT help: the equatable
// shape collapsed exactly like the inline one. The Catalog window updates
// many times a second while anything runs (console, progress, the MFO
// center's 4 Hz job publish), so the submenu could not be used.
//
// Top-level items are clicked the same way "Find Duplicates" always has
// been, so the volume choice moved to a sheet opened by a plain Button
// (DeleteDuplicatesVolumePicker.swift). Do NOT put a nested `Menu` back in
// this menu — CatalogDuplicatesMenuStructureTests guards it.

import SwiftUI

struct CatalogDuplicatesMenu: View {
    /// One "Delete Duplicates on Volume" entry. Mirrors the model's
    /// `deletableDupVolumes` tuples (tuples can't be Equatable/Identifiable).
    struct Volume: Equatable, Identifiable {
        let path: String
        let count: Int
        var id: String { path }
    }

    let isReadOnly: Bool
    let isAnalyzing: Bool
    let isDeleting: Bool
    /// Parent's combined disable rule (scanning / analyzing / deleting /
    /// no records) — computed by the toolbar so this view stays dumb.
    let isDisabled: Bool
    let hasSelection: Bool
    let volumes: [Volume]
    let alsoCleanUpWorkingCopies: Bool
    let reanalyzeHint: String?

    let onFindDuplicates: () -> Void
    let onFindDuplicatesOfSelected: () -> Void
    /// Opens the volume picker sheet (the choice is made there).
    let onChooseVolumeToDelete: () -> Void
    let onSetAlsoCleanUpWorkingCopies: (Bool) -> Void

    /// Title of the menu item that opens the picker.
    static let deleteOnVolumeTitle = "Delete Duplicates on Volume…"

    /// Menu item / picker row title for one volume, e.g. "SanDisk — 12 files".
    static func title(for volume: Volume) -> String {
        "\(URL(fileURLWithPath: volume.path).lastPathComponent) — \(volume.count) file\(volume.count == 1 ? "" : "s")"
    }

    /// Whether the menu offers "Delete Duplicates on Volume…" at all.
    static func offersDelete(isReadOnly: Bool, volumes: [Volume]) -> Bool {
        !isReadOnly && !volumes.isEmpty
    }

    var body: some View {
        Menu {
            Button("Find Duplicates", action: onFindDuplicates)
            Button("Find Duplicates of Selected", action: onFindDuplicatesOfSelected)
                .disabled(!hasSelection)

            if Self.offersDelete(isReadOnly: isReadOnly, volumes: volumes) {
                Divider()
                // A plain item that opens a sheet — see the file header for
                // why this must not be a nested Menu.
                Button(Self.deleteOnVolumeTitle, action: onChooseVolumeToDelete)
                    .accessibilityIdentifier("catalog.duplicates.deleteOnVolume")
            }
            if !isReadOnly {
                Divider()
                // "Also clean up working copies" (2026-08-18) — same
                // persisted setting as the Volumes sheet; the caption lives
                // there. Default OFF.
                Toggle(WorkingCopyCleanupText.toggleLabel, isOn: Binding(
                    get: { alsoCleanUpWorkingCopies },
                    set: { onSetAlsoCleanUpWorkingCopies($0) }))
                if let hint = reanalyzeHint {
                    Text(hint)
                }
            }
        } label: {
            if isAnalyzing || isDeleting {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(isAnalyzing ? "Analyzing…" : "Deleting…")
                }
            } else {
                Label("Duplicates", systemImage: "doc.on.doc")
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(isDisabled)
        .accessibilityIdentifier("catalog.duplicates.menu")
        .help("Find duplicate files by comparing hash, duration, filename, resolution, and other signals")
    }
}
