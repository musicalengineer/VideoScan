// VerifyCatalogMenuItem.swift
// Catalog ▸ "Verify Catalog…" (Rick 2026-10-16, integrity first §2) — starts
// the catalog integrity check as a Media File Operation (the MFO window
// comes forward via `startedByUser`). Tiers 0–6 over the catalog's own
// stamps and relations; the only file written is the report beside the
// catalog. Nothing on media is opened; no row is changed.

import SwiftUI

struct VerifyCatalogMenuItem: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let isReadOnly: Bool

    var body: some View {
        Button("Verify Catalog…") {
            _ = center.startedByUser { $0.startVerifyCatalog(model: model) }
        }
        .disabled(isReadOnly)
        .help("Check the catalog itself: ids, paths, lineage, fixity digests, the removal markers, the sound prints against each file's header, and the catalog file's own hash. Writes a dated report beside the catalog and feeds Catalog Status. Nothing on media is opened; nothing is changed.")
        .accessibilityIdentifier("catalog.menu.verifyCatalog")
    }
}
