// DeleteDuplicatesVolumePicker.swift
// The sheet behind Catalog → Duplicates → "Delete Duplicates on Volume…"
// (Rick 2026-09-22). It replaces a nested submenu that closed itself
// whenever the Catalog window updated — see CatalogDuplicatesMenu.swift.
//
// It only CHOOSES the volume. The choice is handed back through `onPick`;
// CatalogView then shows the existing Delete Duplicates confirmation
// (forecast + destructive button) from the sheet's onDismiss, i.e. after
// the sheet is fully gone — never two modals racing each other.

import SwiftUI

struct DeleteDuplicatesVolumePicker: View {
    let volumes: [CatalogDuplicatesMenu.Volume]
    let onPick: (CatalogDuplicatesMenu.Volume) -> Void
    let onCancel: () -> Void

    var body: some View {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // ForEach over Identifiable ≈ a keyed loop: rows are
                        // matched across updates by volume path.
                        ForEach(volumes) { vol in
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
