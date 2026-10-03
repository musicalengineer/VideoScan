// DeleteDuplicatesVolumePicker.swift
// The sheet that CHOOSES the volume for Delete Duplicates (Rick
// 2026-09-22). It replaced a nested submenu that closed itself whenever
// the Catalog window updated — see CatalogDuplicatesMenu.swift.
//
// 2026-10-02 (Analyze redesign, Phase A): the entry point moved from the
// Catalog toolbar to the Storage tab's Reclaimable card, where the drive
// is already chosen — so the picker takes an optional `preselectedPath`.
// When set and present in the list, that drive is shown first, marked
// "this drive", as the obvious button; the other drives follow under a
// small heading. The choice is still handed back through `onPick` and the
// caller shows the existing confirmation (forecast + destructive button)
// from the sheet's onDismiss — never two modals racing each other.

import SwiftUI

/// Drives `.sheet(item:)` for the picker. One fixed id: there is only
/// ever one picker, and a constant id keeps SwiftUI from treating a
/// re-request as a different sheet.
struct DeleteDuplicatesVolumePickerRequest: Identifiable, Equatable {
    let id = "deleteDuplicatesVolumePicker"
}

struct DeleteDuplicatesVolumePicker: View {
    let volumes: [CatalogDuplicatesMenu.Volume]
    let onPick: (CatalogDuplicatesMenu.Volume) -> Void
    let onCancel: () -> Void
    /// The drive the caller already has in hand (Storage tab); nil from
    /// a catalog-wide entry point.
    var preselectedPath: String? = nil
    /// Drives marked Read only (and the Master Archive's): listed, never
    /// choosable, with the reason (2026-10-03).
    var readOnlyVolumeNames: [String] = []

    /// The preselected drive when it is in the list (a drive with no
    /// deletable duplicates is not offered, preselected or not).
    static func preselected(in volumes: [CatalogDuplicatesMenu.Volume], path: String?) -> CatalogDuplicatesMenu.Volume? {
        guard let path else { return nil }
        return volumes.first { $0.path == path }
    }

    /// The rest, in the original order.
    static func others(in volumes: [CatalogDuplicatesMenu.Volume], path: String?) -> [CatalogDuplicatesMenu.Volume] {
        guard let path else { return volumes }
        return volumes.filter { $0.path != path }
    }

    var body: some View {
        let first = Self.preselected(in: volumes, path: preselectedPath)
        let rest = Self.others(in: volumes, path: preselectedPath)
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Duplicates on Volume")
                .font(.headline)
            Text("Choose the drive to delete duplicates from. Nothing is deleted yet — the next step shows what would happen and asks again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if volumes.isEmpty {
                // The list can empty while the sheet is open (e.g. a
                // re-analysis finished). Say so rather than show nothing.
                Text("No volume has duplicates that can be deleted right now.")
                    .foregroundStyle(.secondary)
            } else {
                if let first {
                    Button {
                        onPick(first)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CatalogDuplicatesMenu.title(for: first) + "  —  this drive")
                            Text(first.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("catalog.duplicates.pickVolume.\(first.path)")
                    if !rest.isEmpty {
                        Text("Other drives")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if !rest.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            // ForEach over Identifiable ≈ a keyed loop: rows are
                            // matched across updates by volume path.
                            ForEach(rest) { vol in
                                Button {
                                    onPick(vol)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(CatalogDuplicatesMenu.title(for: vol))
                                        Text(vol.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .accessibilityIdentifier("catalog.duplicates.pickVolume.\(vol.path)")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }

            ForEach(readOnlyVolumeNames, id: \.self) { name in
                Label(VolumeReadOnlyText.pickerRow(name), systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("catalog.duplicates.readOnlyVolume.\(name)")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}
