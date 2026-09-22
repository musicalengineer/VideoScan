// CatalogDuplicatesMenu.swift
// The Catalog toolbar's "Duplicates" menu (Find Duplicates, Find
// Duplicates of Selected, Delete Duplicates on Volume ▸, the working-copy
// toggle and the re-analyze hint), extracted from CatalogToolbar.swift.
//
// WHY THIS IS ITS OWN EQUATABLE VIEW (Rick 2026-09-22, Release b334247b):
// "when I try to delete dups from the Duplicates menu, it flashes over
// 'Delete Duplicates on Volume…' and does not allow me to select a volume."
//
// Root cause, reproduced in CatalogDuplicatesMenuSubmenuSensorTests: on
// macOS a SwiftUI `Menu` is an NSPopUpButton whose NSMenu SwiftUI keeps in
// sync with the view. When the view that CONTAINS the menu re-evaluates its
// body while the menu is open, SwiftUI re-syncs the NSMenu and the open
// submenu collapses — even if nothing in the menu changed. The menu used to
// sit inline in CatalogToolbar's body, and CatalogToolbar re-evaluates on
// every VideoScanModel publish (it observes the model) and on every
// CatalogView re-render (CatalogView hands it ~15 fresh closures each time,
// and CatalogView was subscribed to MediaFileOperationsCenter, which
// re-broadcasts running jobs' progress at 4 Hz). While any job was
// progressing, the submenu could not stay open long enough to click.
//
// The fix here: this view takes PLAIN VALUES, does not observe the model,
// and is wrapped in `.equatable()` by the toolbar. `.equatable()` ≈ giving
// SwiftUI an operator== to consult before re-running `body`; when it says
// "equal", the body — and therefore the NSMenu — is left alone. The menu
// is only rebuilt when something the menu SHOWS changes (a volume's count,
// the hint, a flag), which is correct.
//
// Closures are deliberately NOT compared (Swift closures have no
// equality). That is safe because every closure the toolbar passes reads
// live state when it RUNS — the model is a class reference, and the
// catalog's @State values are read through SwiftUI's storage box, not a
// copied value — so a closure kept from an earlier render still acts on
// current state. If you add an action that captures a plain value at
// construction time, add that value to `==` as well.

import SwiftUI

struct CatalogDuplicatesMenu: View, Equatable {
    /// One "Delete Duplicates on Volume" entry. Mirrors the model's
    /// `deletableDupVolumes` tuples, which cannot be Equatable.
    struct Volume: Equatable {
        let path: String
        let count: Int
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
    let onDeleteDuplicates: (String, Int) -> Void
    let onSetAlsoCleanUpWorkingCopies: (Bool) -> Void

    /// Values only — see the file header for why closures are excluded.
    static func == (lhs: CatalogDuplicatesMenu, rhs: CatalogDuplicatesMenu) -> Bool {
        lhs.isReadOnly == rhs.isReadOnly
            && lhs.isAnalyzing == rhs.isAnalyzing
            && lhs.isDeleting == rhs.isDeleting
            && lhs.isDisabled == rhs.isDisabled
            && lhs.hasSelection == rhs.hasSelection
            && lhs.volumes == rhs.volumes
            && lhs.alsoCleanUpWorkingCopies == rhs.alsoCleanUpWorkingCopies
            && lhs.reanalyzeHint == rhs.reanalyzeHint
    }

    /// Menu item title for one volume, e.g. "SanDisk — 12 files".
    static func title(for volume: Volume) -> String {
        "\(URL(fileURLWithPath: volume.path).lastPathComponent) — \(volume.count) file\(volume.count == 1 ? "" : "s")"
    }

    var body: some View {
        Menu {
            Button("Find Duplicates", action: onFindDuplicates)
            Button("Find Duplicates of Selected", action: onFindDuplicatesOfSelected)
                .disabled(!hasSelection)

            if !isReadOnly && !volumes.isEmpty {
                Divider()
                Menu("Delete Duplicates on Volume…") {
                    // ForEach(id: \.path) ≈ a keyed loop: SwiftUI matches
                    // rows across renders by path, not by position.
                    ForEach(volumes, id: \.path) { vol in
                        Button(Self.title(for: vol)) {
                            onDeleteDuplicates(vol.path, vol.count)
                        }
                    }
                }
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
