// MainTabTagSensorTests.swift
// Rick 2026-10-18: searching "elevator" found the archived Cape 1992
// videos, but "Show in Archive" opened Triage — ContentView switched to the
// bare tag `2`, which has been Triage since the 2026-08-19 renumbering
// (Archive is 4). `MainTab` names the tags; this sensor keeps the names and
// the tab strip's numbers in step, and keeps the archive door on the name.

import Foundation
import Testing
@testable import VideoScan

@Suite("Main window tabs — named tags match the tab strip")
struct MainTabTagSensorTests {

    private static var contentView: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/App/ContentView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func stripTag(_ label: String) -> Int? {
        let pattern = "\\(\"\(label)\", \"[^\"]+\", (\\d+)\\)"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = contentView
        guard let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    @Test("Archive's tag in the strip is MainTab.archive")
    func archiveTag() { #expect(Self.stripTag("Archive") == MainTab.archive.rawValue) }

    @Test("Triage's tag in the strip is MainTab.triage")
    func triageTag() { #expect(Self.stripTag("Triage") == MainTab.triage.rawValue) }

    @Test("Catalog's tag in the strip is MainTab.catalog")
    func catalogTag() { #expect(Self.stripTag("Catalog") == MainTab.catalog.rawValue) }

    @Test("Family Tree's tag in the strip is MainTab.familyTree")
    func familyTreeTag() { #expect(Self.stripTag("Family Tree") == MainTab.familyTree.rawValue) }

    @Test("Show in Archive switches by name, never by a bare number")
    func showInArchiveUsesTheName() {
        #expect(Self.contentView.contains("selectedTab = MainTab.archive.rawValue"))
    }
}
