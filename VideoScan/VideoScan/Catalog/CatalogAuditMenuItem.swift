// CatalogAuditMenuItem.swift
// Catalog ▸ "Audit Catalog…" (Rick 2026-10-15, tier 0) — starts the
// whole-catalog presence audit as a Media File Operation (the MFO window
// comes forward via `startedByUser`). One stat per live row on a connected
// drive; a file that is gone is marked Missing, a Missing file that is back
// goes live again. Nothing on media is opened. Never starts on its own —
// the nightly calls the same job through `--audit-catalog`.

import SwiftUI

struct CatalogAuditMenuItem: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let marker: CatalogAuditRunMarker
    let isReadOnly: Bool

    var body: some View {
        Button("Audit Catalog…") {
            _ = center.startedByUser { $0.startCatalogAudit(model: model, marker: marker) }
        }
        .disabled(isReadOnly)
        .help("Check that every catalog entry on a connected drive still points at its file (one stat per file, nothing is opened). A file that is gone is marked Missing; a Missing file that is back is shown again. A changed size is reported, not marked. Drives that are not connected are left alone.")
        .accessibilityIdentifier("catalog.menu.auditCatalog")
    }
}
