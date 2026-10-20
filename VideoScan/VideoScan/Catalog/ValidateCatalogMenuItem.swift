// ValidateCatalogMenuItem.swift
// Catalog ▸ "Validate Catalog…" — the ONE catalog-checking verb (Rick
// 2026-10-20; it replaces the separate "Audit Catalog…" and "Verify
// Catalog…" items). Starts ValidateCatalogJob as a Media File Operation (the
// MFO window comes forward via `startedByUser`): every file on disk first,
// then — only after a complete file check — the catalog against itself.
// Never starts on its own; the nightly runs the same job through
// `--validate-catalog` (or the older `--audit-catalog`).

import SwiftUI

struct ValidateCatalogMenuItem: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let marker: CatalogAuditRunMarker
    let isReadOnly: Bool

    var body: some View {
        Button("Validate Catalog…") {
            _ = center.startedByUser { $0.startValidateCatalog(model: model, marker: marker) }
        }
        .disabled(isReadOnly)
        .help("Step 1: check that every catalog entry on a connected drive still points at its file (one stat per file, nothing is opened) — a file that is gone is marked Missing, a Missing file that is back is shown again, a changed size is reported. Step 2, only after a complete step 1: check the catalog agrees with itself — ids, paths, lineage, fixity digests, the removal markers, the sound prints — and write a dated report beside the catalog for Catalog Status. Drives that are not connected are left alone.")
        .accessibilityIdentifier("catalog.menu.validateCatalog")
    }
}
