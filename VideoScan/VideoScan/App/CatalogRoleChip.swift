// CatalogRoleChip.swift — the main window says what this Mac is (Rick
// 2026-11-02: "we need a UI indication that we're READ ONLY on the catalog
// … let users see master versus client view only"). One small chip at the
// trailing edge of the tab bar, on every Mac, every launch:
//   crown  "Master · RicksUltra"        — this Mac writes the catalog
//   eye    "Viewer · read-only"         — a synced copy of the master's
// The help text says the rest. The viewer's sync banner (CatalogSyncBanner)
// keeps its job — sync state and Refresh — this chip is the role alone.
// Words are pure (CatalogRoleChipText) so a test pins them; the role comes
// from CatalogSync, decided at launch.

import SwiftUI

enum CatalogRoleChipText {
    struct Words: Equatable {
        var text: String
        var help: String
        var symbol: String
    }

    static func compose(mode: CatalogSyncMode, masterHostname: String, thisMac: String) -> Words {
        let master = ViewerModeCenter.shortName(masterHostname)
        let me = ViewerModeCenter.shortName(thisMac)
        switch mode {
        case .master:
            return Words(text: "Master · \(me)",
                         help: "This Mac (\(me)) is the catalog master: it writes the catalog; every other Mac views a synced, read-only copy. Change it in Settings ▸ Catalog Master.",
                         symbol: "crown.fill")
        case .viewer:
            return Words(text: "Viewer · read-only",
                         help: "This Mac (\(me)) is a viewer: the catalog on screen is a read-only copy synced from \(master), the master. Nothing here changes the catalog. Change it in Settings ▸ Catalog Master.",
                         symbol: "eye")
        }
    }
}

struct CatalogRoleChip: View {
    let mode: CatalogSyncMode
    let masterHostname: String
    var thisMac: String = SystemHostnameSource().currentHostname()

    var body: some View {
        let words = CatalogRoleChipText.compose(mode: mode, masterHostname: masterHostname, thisMac: thisMac)
        HStack(spacing: 5) {
            Image(systemName: words.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(words.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(mode == .master ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(mode == .master ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.12)))
        .help(words.help)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("window.catalogRole")
    }
}
