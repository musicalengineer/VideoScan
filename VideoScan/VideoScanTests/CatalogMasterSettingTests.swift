// CatalogMasterSettingTests.swift — Settings ▸ Catalog Master (Rick
// 2026-11-02). LOGIC: the effective master (key, else built-in default),
// save/trim/empty, this Mac's role, the words; TRUTH: the line says
// "takes effect at relaunch" exactly when the saved name or role differs
// from what the launch read; ISOLATION: a poisoned (non-string) key reads
// as the default; SENSOR: the rows sit above Model Configuration and write
// through the one setter and the one key.

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Catalog Master — one key, one Mac, Rick decides")
struct CatalogMasterSettingTests {

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "test.catalog-master.\(UUID().uuidString)")! }

    @Test("no key: the built-in default (the Ultra), marked not explicit")
    func builtInDefault() {
        let d = defaults()
        let e = CatalogMasterSetting.effective(d)
        #expect(e.hostname == defaultMasterHostname && !e.explicit)
        #expect(CatalogMasterSetting.key == "CatalogSyncMasterHostname", "the key the launch reads")
    }

    @Test("save trims; empty removes the key and falls back to the default")
    func saveAndClear() {
        let d = defaults()
        #expect(CatalogMasterSetting.save("  RicksM4.local \n", to: d) == "RicksM4.local")
        #expect(CatalogMasterSetting.effective(d) == ("RicksM4.local", true))
        #expect(CatalogMasterSetting.save("   ", to: d) == defaultMasterHostname)
        #expect(d.string(forKey: CatalogMasterSetting.key) == nil)
    }

    @Test("a poisoned key (a number) reads as the default, never a crash")
    func poisonedKey() {
        let d = defaults()
        d.set(42, forKey: CatalogMasterSetting.key)
        // UserDefaults.string(forKey:) renders a number as its text — not a
        // Mac name, but a string; the launch would do the same. Pin that.
        #expect(CatalogMasterSetting.effective(d).hostname == "42")
        d.set(["a": 1], forKey: CatalogMasterSetting.key)
        #expect(CatalogMasterSetting.effective(d) == (defaultMasterHostname, false))
    }

    @Test("this Mac's role follows the .local-insensitive compare")
    func role() {
        #expect(CatalogMasterSetting.role(thisMac: "RicksUltra", master: "RicksUltra.local") == .master)
        #expect(CatalogMasterSetting.role(thisMac: "RicksM4", master: "RicksUltra.local") == .viewer)
        #expect(CatalogMasterSetting.display("RicksUltra.local") == "RicksUltra")
    }

    @Test("the words: master, viewer, built-in default, and the relaunch clause exactly when something changed")
    func words() {
        let settled = CatalogMasterSetting.words(thisMac: "RicksM4", master: "RicksUltra.local", explicit: true, launchedAs: .viewer, launchedWith: "RicksUltra.local")
        #expect(settled == "This Mac (RicksM4) is a viewer — the catalog is read-only here, synced from RicksUltra.")
        let master = CatalogMasterSetting.words(thisMac: "RicksUltra", master: "RicksUltra.local", explicit: true, launchedAs: .master, launchedWith: "RicksUltra.local")
        #expect(master == "This Mac (RicksUltra) is the catalog master — every other Mac is a viewer.")
        let implicit = CatalogMasterSetting.words(thisMac: "RicksM4", master: "RicksUltra.local", explicit: false, launchedAs: .viewer, launchedWith: "RicksUltra.local")
        #expect(implicit.hasSuffix("Built-in default; not set on this Mac."))
        let changed = CatalogMasterSetting.words(thisMac: "RicksM4", master: "RicksM4.local", explicit: true, launchedAs: .viewer, launchedWith: "RicksUltra.local")
        #expect(changed == "This Mac (RicksM4) is the catalog master — every other Mac is a viewer. Takes effect when VideoScan relaunches — it launched as a viewer of RicksUltra.")
        let sameRoleNewName = CatalogMasterSetting.words(thisMac: "ricksm5", master: "RicksM4.local", explicit: true, launchedAs: .viewer, launchedWith: "RicksUltra.local")
        #expect(sameRoleNewName.contains("Takes effect when VideoScan relaunches"), "a viewer that will sync from a different master must relaunch too")
    }

    private struct Host: HostnameSource {
        let name: String
        func currentHostname() -> String { name }
    }

    /// Regression (codex-1102 review): the pane trimmed the key and read an
    /// empty one as the built-in default; the launch read it raw. A key of ""
    /// launched the Ultra as a viewer while the pane said "catalog master";
    /// " RicksM4.local " launched the M4 as a viewer while the pane said master.
    @Test("the pane and the launch read the key one way: padded, empty, whitespace, case and .local variants agree on every Mac")
    func paneAgreesWithLaunch() {
        let keys: [String?] = [nil, "", "   ", "\n", " RicksUltra.local ", "RICKSULTRA", "ricksultra.local",
                               "RicksM4.local\n", "  RicksM4 ", "RicksM5"]
        for raw in keys {
            let d = defaults()
            if let raw { d.set(raw, forKey: CatalogMasterSetting.key) }
            let pane = CatalogMasterSetting.effective(d).hostname
            #expect(CatalogSync.masterHostname(defaults: d) == pane, "launch and pane name one master for \(String(reflecting: raw))")
            var masters = 0
            for mac in ["RicksUltra", "RicksUltra.local", "RicksM4", "ricksm5", "Ricks-M1"] {
                let launch = CatalogSync.launchMode(hostnameSource: Host(name: mac), defaults: d)
                #expect(launch == CatalogMasterSetting.role(thisMac: mac, master: pane), "\(mac) under \(String(reflecting: raw))")
                if launch == .master, !mac.hasSuffix(".local") { masters += 1 }
            }
            #expect(masters <= 1, "never two masters among distinct Macs under \(String(reflecting: raw))")
        }
    }

    @Test("the store: one setter, one log line per change, Use This Mac names this Mac")
    func store() {
        let d = defaults()
        var lines: [String] = []
        let s = CatalogMasterStore(defaults: d, thisMac: "RicksM4", launchedAs: .viewer, launchedWith: "RicksUltra.local", log: { lines.append($0) })
        #expect(s.master == defaultMasterHostname && !s.explicit && s.role == .viewer)
        s.setMaster(defaultMasterHostname)
        #expect(s.explicit && lines.isEmpty, "same name, now explicit — nothing changed, nothing logged")
        s.useThisMac()
        #expect(s.master == "RicksM4" && s.role == .master)
        #expect(lines.count == 1 && lines[0].contains("set to RicksM4") && lines[0].contains("next launch"), "\(lines)")
        #expect(d.string(forKey: CatalogMasterSetting.key) == "RicksM4")
        s.setMaster("")
        #expect(s.master == defaultMasterHostname && !s.explicit && lines.count == 2)
    }
}

@Suite("Catalog Master — SENSOR: above Model Configuration, one setter, one key")
struct CatalogMasterSettingsSensorTests {
    static let appRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VideoScan", isDirectory: true)

    @Test func placementAndSetter() throws {
        let settings = try String(contentsOf: Self.appRoot.appendingPathComponent("App/SettingsView.swift"), encoding: .utf8)
        let rows = try #require(settings.range(of: "CatalogMasterSettingsRows(")).lowerBound
        let model = try #require(settings.range(of: "ArchivistEndpointSettings()")).lowerBound
        #expect(rows < model, "Catalog Master sits above Model Configuration")
        let view = try String(contentsOf: Self.appRoot.appendingPathComponent("App/CatalogMasterSettingsRows.swift"), encoding: .utf8)
        #expect(view.contains("store.setMaster(draft)") && view.contains("store.useThisMac()"))
        #expect(!view.contains("UserDefaults") && !view.contains("@AppStorage"))
        for id in ["settings.catalogMaster.hostname", "settings.catalogMaster.useThisMac", "settings.catalogMaster.role"] {
            #expect(view.contains(id), Comment(rawValue: id))
        }
        let setting = try String(contentsOf: Self.appRoot.appendingPathComponent("Catalog/CatalogMasterSetting.swift"), encoding: .utf8)
        #expect(setting.contains("static let key = CatalogSyncDefaultsKey.masterHostname"), "the pane writes the key the launch reads")
        let app = try String(contentsOf: Self.appRoot.appendingPathComponent("App/VideoScanApp.swift"), encoding: .utf8)
        #expect(app.components(separatedBy: "CatalogMasterStore.production(").count == 2, "built once")
    }
}
