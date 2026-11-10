// BackgroundSettingsSensorTests.swift — Settings ▸ Background (Rick
// 2026-11-02): the Content Analysis rows are first in ONE "Background"
// section, the checkbox writes only through the store's setter, the
// Archivist pane carries its new title. Reads source (SENSOR lane).

import Foundation
import Testing
@testable import VideoScan

@Suite("Settings ▸ Background — SENSOR: one section, one setter, one key")
struct BackgroundSettingsSensorTests {

    static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // VideoScanTests/
        .deletingLastPathComponent()        // VideoScan/ (project dir)
        .appendingPathComponent("VideoScan", isDirectory: true)

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("SettingsView has a Background section holding Content Analysis first, then the sweep and Find People toggles; no Previews header")
    func oneBackgroundSection() throws {
        let s = try Self.source("App/SettingsView.swift")
        #expect(s.contains("Label(\"Background\""))
        #expect(!s.contains("Label(\"Previews\""), "the two helper toggles moved under Background")
        let section = try #require(s.range(of: "Label(\"Background\"")).lowerBound
        let rows = try #require(s.range(of: "ContentAnalysisSettingsRows(")).lowerBound
        let sweep = try #require(s.range(of: "settings.previewSweep.enabled")).lowerBound
        let people = try #require(s.range(of: "settings.findTagHelper.enabled")).lowerBound
        #expect(section < rows && rows < sweep && sweep < people, "order: Content Analysis, Previews, Find People")
    }

    @Test("the button writes through BackgroundServiceStore.perform, never a defaults key or @AppStorage")
    func theOneSetter() throws {
        let rows = try Self.source("App/ContentAnalysisSettingsRows.swift")
        let store0 = try Self.source("App/BackgroundServiceStore.swift")
        #expect(rows.contains("await store.perform(control.action)"))
        #expect(!rows.contains("Toggle(") && !rows.contains("setEnabled"), "Rick 2026-11-09: a state and a button, no checkbox")
        #expect(!rows.contains("UserDefaults") && !rows.contains("@AppStorage"))
        #expect(rows.contains("settings.backgroundService.heading") && rows.contains("settings.backgroundService.action"))
        #expect(rows.contains("settings.backgroundService.status"))
        #expect(rows.contains("settings.backgroundService.job"))
        #expect(store0.contains("static let name = \"Background Content Analysis\""), "Rick's wording")
        #expect(rows.contains("Login Items") && rows.contains("Full Disk Access"), "the footnote names both one-time prompts")
        let store = try Self.source("App/BackgroundServiceStore.swift")
        #expect(store.contains("registerIfEnabled(") && store.contains("unregister("),
                "the store drives ServiceManagement through the registrar — one code path with the launch")
    }

    @Test("the app owns one store, starts it at launch under the test-host guard, and hands it to Settings")
    func wiredOnce() throws {
        let app = try Self.source("App/VideoScanApp.swift")
        #expect(app.components(separatedBy: "BackgroundServiceStore.production(").count == 2, "built once")
        #expect(app.contains("if !TestEnvironment.isTestHost { backgroundService.start() }"))
        #expect(app.contains("wireBackgroundService()"), "the launch calls the one wiring function")
        #expect(app.contains("backgroundService: backgroundService,"))
    }

    @Test("RED→GREEN SENSOR (Rick 2026-11-04, the helper owns its schedule): no app code path enqueues a background job or counts its work")
    func noAppCodeEnqueues() throws {
        let fm = FileManager.default
        let files = try #require(fm.enumerator(at: Self.appRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "scanned the app target")
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["proxy.enqueue(", ".enqueue(request", "enqueueRequest", "EraJob.request(", "shouldEnqueue", "EraPlanner.plan("]
            where text.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        #expect(offenders.isEmpty, "the app schedules nothing; the helper plans its own work: \(offenders)")
    }

    @Test("the Archivist pane is titled Model Configuration (Rick 11/02)")
    func archivistTitle() throws {
        let s = try Self.source("Hallie/LLM/ArchivistEndpointSettings.swift")
        #expect(s.contains("Text(\"Model Configuration\")"))
        #expect(!s.contains("Text(\"Archivist Brain\")"))
    }
}
