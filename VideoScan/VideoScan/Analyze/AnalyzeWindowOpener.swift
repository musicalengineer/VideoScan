// AnalyzeWindowOpener.swift
// Opens the Analyze panel window (Phase A trial, 2026-10-02) — the ONE
// funnel behind ⇧⌘O, the Catalog toolbar's "Analyze Catalog" button and
// the Analyze menu's "Analyze…" item. Reuses DossierWindowOpener's
// create → activate → find → clamp → raise path (punch-list #4) so the
// panel never opens off-screen or behind another app.

import SwiftUI

@MainActor
enum AnalyzeWindowOpener {
    /// Scene id from the `Window(id:)` declaration in VideoScanApp.swift.
    static let sceneID = "analyze"
    /// Scene title — SwiftUI sets NSWindow.title to this.
    static let windowTitle = "Analyze"

    /// - source: "menu" (⇧⌘O), "chip" (toolbar button), "analyze-menu".
    static func open(using openWindow: OpenWindowAction, source: String) {
        DossierWindowOpener.open(sceneID: sceneID, windowTitle: windowTitle,
                                 using: openWindow, source: source)
    }
}
