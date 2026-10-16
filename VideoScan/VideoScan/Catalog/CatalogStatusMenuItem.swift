// CatalogStatusMenuItem.swift
// Catalog ▸ "Catalog Status…" (Rick 2026-10-16, Catalog Status freshness
// §2 / §4.2) — opens the Analyze panel (Content Analysis), where the
// summary band sits at the top. The title carries the colour word when
// the summary is not green: "Catalog Status — needs a decision…" /
// "Catalog Status — needs attention…". Observes the one freshness
// snapshot; never the model.

import SwiftUI
import VideoScanCore

struct CatalogStatusMenuItem: View {
    @ObservedObject var freshness: CatalogFreshnessSnapshot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            AnalyzeWindowOpener.open(using: openWindow, source: "catalog-menu")
        }
        .help("Is what the catalog knows current? \(freshness.state.summary.headline). Opens Content Analysis with the summary band at the top — one button per item.")
        .accessibilityIdentifier("catalog.menu.catalogStatus")
    }

    private var title: String {
        let s = freshness.state
        return CatalogStatusWords.menuTitle(s.isComputed ? s.summary.colour : .grey)
    }
}
