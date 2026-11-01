// CatalogStatusMenuItem.swift
// Catalog ▸ "Catalog Status…" — opens the Catalog Status window (Rick
// 2026-11-01: one window, three coloured lines — Database, Files, Content —
// then the band's details and the database facts). The title names the
// worst line: "Catalog Status — Files needs attention…", or "Catalog Status
// — Green…" when all three are green (CatalogStatusLines.menuTitle).
// Observes the one freshness snapshot; never the model.

import SwiftUI
import VideoScanCore

struct CatalogStatusMenuItem: View {
    @ObservedObject var freshness: CatalogFreshnessSnapshot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: CatalogStatusWindow.sceneID)
        }
        .help(CatalogActionBrief.catalogStatus.help)
        .accessibilityIdentifier("catalog.menu.catalogStatus")
    }

    private var title: String { CatalogStatusWords.menuTitle(freshness.state) }
}
