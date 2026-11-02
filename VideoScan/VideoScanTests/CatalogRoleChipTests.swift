// CatalogRoleChipTests.swift — the main window's role chip (Rick
// 2026-11-02). TRUTH: the words follow the launch role and name the Macs;
// the viewer says "read-only" in so many words. SENSOR: the chip sits in
// the tab-bar row on every launch, reads CatalogSync, carries its id.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog role chip — master or viewer · read-only, every launch")
struct CatalogRoleChipTests {

    @Test("master: crown, this Mac's name; viewer: eye, read-only, the master's name in the help")
    func words() {
        let master = CatalogRoleChipText.compose(mode: .master, masterHostname: "RicksUltra.local", thisMac: "RicksUltra")
        #expect(master.text == "Master · RicksUltra" && master.symbol == "crown.fill")
        #expect(master.help.contains("writes the catalog") && master.help.contains("Settings ▸ Catalog Master"))
        let viewer = CatalogRoleChipText.compose(mode: .viewer, masterHostname: "RicksUltra.local", thisMac: "RicksM4.local")
        #expect(viewer.text == "Viewer · read-only" && viewer.symbol == "eye")
        #expect(viewer.help.contains("This Mac (RicksM4) is a viewer") && viewer.help.contains("synced from RicksUltra"))
    }

    @Test("the viewer's sync chip says read-only too")
    func syncChipSaysReadOnly() {
        #expect(ViewerStatusChipText.compose(masterDisplayName: "RicksUltra", syncedAt: nil, syncing: false, media: "streaming")
                == "Viewing RicksUltra's catalog · read-only · never synced · media: streaming")
    }
}

@Suite("Catalog role chip — SENSOR: in the tab-bar row, from CatalogSync, with its id")
struct CatalogRoleChipSensorTests {
    static let appRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VideoScan", isDirectory: true)

    @Test func placement() throws {
        let content = try String(contentsOf: Self.appRoot.appendingPathComponent("App/ContentView.swift"), encoding: .utf8)
        #expect(content.contains("CatalogRoleChip(mode: catalogSync.mode, masterHostname: catalogSync.masterHostname)"))
        let chipAt = try #require(content.range(of: "CatalogRoleChip(mode:")).lowerBound
        let tabsAt = try #require(content.range(of: "GlassTabStrip(selection:")).lowerBound
        let contentAt = try #require(content.range(of: "// Tab content")).lowerBound
        #expect(tabsAt < chipAt && chipAt < contentAt, "the chip overlays the tab-bar row, not the content")
        let chip = try String(contentsOf: Self.appRoot.appendingPathComponent("App/CatalogRoleChip.swift"), encoding: .utf8)
        #expect(chip.contains("window.catalogRole"))
        #expect(!chip.contains("UserDefaults"), "the role comes from CatalogSync, decided at launch — never re-read from a key")
    }
}
