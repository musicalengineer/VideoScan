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

@Suite("Archive search — the same search as the Catalog")
struct ArchiveSearchSharedSensorTests {

    private static var archiveView: String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/Archive/ArchiveView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("the Archive tab filters through the Catalog's search index (transcripts, captions, notes, places)")
    func archiveUsesTheSharedIndex() {
        #expect(Self.archiveView.contains("model.searchIndex.filter(records: byCategory, query: searchText)"))
    }

    @Test("a record found only by its transcript is found by the shared index")
    @MainActor
    func transcriptOnlyRecordIsFound() {
        let rec = VideoRecord()
        rec.filename = "cape-1992-edit.mov"
        rec.fullPath = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/1990-1999/1992/cape-1992-edit.mov"
        rec.audioTranscript = "Here's the kitchen. Give them a ride in the elevator."
        let index = CatalogSearchIndex()
        index.rebuild(records: [rec])
        #expect(index.filter(records: [rec], query: "elevator").count == 1)
    }
}
