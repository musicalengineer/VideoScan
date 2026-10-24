// CatalogVolumePillTests.swift
// The Showing line tells the truth about an active Volumes-pane selection
// (Rick 2026-10-24: one volume was selected without his noticing, Folders
// Only showed 3 of 17 folders, and the line read "All kinds · Including
// archived · Folders only · Connected drives" — nothing named the filter).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic      — no selection → no pill; one → its pane label first; two+ →
//                "Selected volumes" first, names in the tooltip; the
//                VoiceOver/log sentence carries it; the clear action empties
//                the selection and nothing else does; long names shorten in
//                the middle; the Folders Only empty note names the filter.
//   Regression — Rick's case on synthetic rows: Folders Only over rows
//                narrowed to one volume yields exactly that volume's
//                folders, AND the summary for that state leads with the
//                volume pill.
//   Isolation  — a blank label (a target with no resolvable name) never
//                draws an empty pill.
//   Sensor     — the toolbar draws the pill and wires the clear; the parent
//                feeds pane labels and clears through the one seam; the
//                selection stays session-only (launch = whole catalog).
//   Scale / media matrix — N/A: O(selected volumes) over plain strings; no
//                record is read and no file is opened.
//
// Suites: CatalogVolumePillLogicTests · CatalogVolumePillRegressionTests ·
//         CatalogVolumePillSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Summary = CatalogShowingSummary

private func texts(_ s: Summary.State) -> [String] { Summary.pills(for: s).map(\.text) }

/// Rick's exact view: All kinds, a Master Archive (Including archived),
/// Folders Only, connected drives.
private func ricksState(_ labels: [String]) -> Summary.State {
    Summary.State(kindFacet: .everything, footageFolders: true, foldersOnly: true,
                  hasMasterArchive: true, selectedVolumeLabels: labels)
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

// MARK: - Logic

@Suite("Showing line — the volume pill")
struct CatalogVolumePillLogicTests {

    @Test func noSelectionHasNoVolumePill() {
        let s = ricksState([])
        #expect(texts(s) == ["All kinds", "Including archived", "Folders only", "Connected drives"])
        #expect(!Summary.pills(for: s).contains { $0.emphasis == .volume || $0.action == .clearVolumes })
        #expect(Summary.volumePill(labels: []) == nil)
    }

    @Test func oneVolumeIsTheFirstPillByItsPaneLabel() throws {
        let pills = Summary.pills(for: ricksState(["CrucialX9"]))
        #expect(pills.map(\.text) == ["CrucialX9", "All kinds", "Including archived", "Folders only", "Connected drives"])
        let first = try #require(pills.first)
        #expect(first.emphasis == .volume, "accent-coloured, stands out from the others")
        #expect(first.action == .clearVolumes, "clicking it clears the selection")
        #expect(pills.dropFirst().allSatisfy { $0.emphasis != .volume && $0.action != .clearVolumes }, "only one volume pill")
        #expect(Summary.volumeHelp(labels: ["CrucialX9"]) == "Showing only CrucialX9 — click to show the whole catalog")
    }

    @Test func twoOrMoreReadSelectedVolumesWithTheNamesInTheTooltip() throws {
        let labels = ["CrucialX9", "LaCie", "RicksBackups"]
        let first = try #require(Summary.pills(for: ricksState(labels)).first)
        #expect(first.text == "Selected volumes")
        #expect(first.emphasis == .volume && first.action == .clearVolumes)
        let help = Summary.volumeHelp(labels: labels)
        #expect(help == "Showing only CrucialX9, LaCie, RicksBackups — click to show the whole catalog")
    }

    @Test func theSpokenSentenceCarriesTheVolumePill() {
        #expect(Summary.sentence(for: ricksState(["CrucialX9"]))
                == "Showing CrucialX9, All kinds, Including archived, Folders only, Connected drives")
        #expect(Summary.sentence(for: ricksState(["A", "B"])).hasPrefix("Showing Selected volumes, All kinds"))
        #expect(Summary.sentence(for: ricksState([])) == "Showing All kinds, Including archived, Folders only, Connected drives")
    }

    @Test func theBoxTextLeavesTheVolumeToItsOwnPill() {
        // The volume pill is drawn as its own accent button in front of the
        // box; the box's joined text must not say it a second time.
        #expect(Summary.boxPills(for: ricksState(["CrucialX9"])).map(\.text)
                == ["All kinds", "Including archived", "Folders only", "Connected drives"])
    }

    @Test func clearingViaThePillEmptiesTheSelection() {
        let sel: Set<UUID> = [UUID(), UUID()]
        #expect(Summary.volumeSelection(after: .clearVolumes, sel).isEmpty)
        for other: Summary.Pill.Action in [.none, .toggleArchived, .toggleDrives] {
            #expect(Summary.volumeSelection(after: other, sel) == sel, "\(other) leaves the selection alone")
        }
    }

    @Test func longNamesShortenInTheMiddleAndShortOnesStay() {
        #expect(Summary.shortVolumeLabel("CrucialX9") == "CrucialX9")
        let long = "RicksBackups > RicksHomeBackup 2019 Final Copy"
        let short = Summary.shortVolumeLabel(long)
        #expect(short.count == Summary.volumeLabelLimit)
        #expect(short.hasPrefix("RicksBackups") && short.hasSuffix("Copy") && short.contains("\u{2026}"))
    }

    @Test func emptyFolderNoteNamesTheVolumeWhenTheSelectionIsWhy() {
        let one = FootageFolderWords.foldersOnlyEmpty(volumeLabels: ["CrucialX9"], foldersExist: true)
        #expect(one.hasPrefix("No folders on CrucialX9 match"))
        #expect(one.contains("whole catalog"))
        let many = FootageFolderWords.foldersOnlyEmpty(volumeLabels: ["A", "B"], foldersExist: true)
        #expect(many.hasPrefix("No folders on the selected volumes match"))
        #expect(FootageFolderWords.foldersOnlyEmpty(volumeLabels: [], foldersExist: true) == FootageFolderWords.foldersOnlyEmpty,
                "no selection: today's words")
        #expect(FootageFolderWords.foldersOnlyEmpty(volumeLabels: ["CrucialX9"], foldersExist: false) == FootageFolderWords.foldersOnlyEmpty,
                "no folders at all: the selection is not why")
    }

    @Test func aBlankLabelNeverDrawsAnEmptyPill() throws {
        let pill = try #require(Summary.volumePill(labels: ["  "]))
        #expect(pill.text == "Selected volume")
        #expect(Summary.volumeHelp(labels: [""]).hasPrefix("Showing only one selected volume"))
    }
}

// MARK: - Regression: Rick's case (synthetic rows, no family data)

@Suite("Showing line — Folders Only narrowed to one volume (Rick 2026-10-24)")
struct CatalogVolumePillRegressionTests {

    private struct Fixture {
        var records: [VideoRecord] = []
        var rows: [FootageFolders.Row] = []
        var events: [FootageFolders.Event] = []
        var onX9: Set<UUID> = []          // folder ids whose members sit on the selected volume
        var elsewhere: Set<UUID> = []

        mutating func folder(_ title: String, volume: String, files: Int) {
            var keys: [FootageFolders.Row] = []
            for i in 0..<files {
                let rec = VideoRecord()
                rec.fullPath = "/Volumes/\(volume)/Movies/\(title)_\(i).mov"
                records.append(rec)
                let r = FootageFolders.Row(id: rec.id, digest: "\(title)-\(i)", sizeBytes: 1_000, durationSeconds: 60,
                                           volume: volume,
                                           keys: FootageFolders.SortKeys(filename: "\(title)_\(i).mov", volume: volume,
                                                                        duration: 60, size: 1_000))
                keys.append(r)
            }
            rows += keys
            let ev = FootageFolders.Event(id: UUID(), title: title, contentKeys: keys.map(\.contentKey))
            events.append(ev)
            if volume == "CrucialX9" { onX9.insert(ev.id) } else { elsewhere.insert(ev.id) }
        }
    }

    private func fixture() -> Fixture {
        var f = Fixture()
        f.folder("FolderA", volume: "CrucialX9", files: 2)
        f.folder("FolderB", volume: "CrucialX9", files: 3)
        f.folder("FolderC", volume: "CrucialX9", files: 1)
        f.folder("FolderD", volume: "LaCie", files: 2)
        f.folder("FolderE", volume: "RicksBackups", files: 2)
        f.folder("FolderF", volume: "LaCie", files: 4)
        // Loose files on both volumes — Folders Only drops them either way.
        for v in ["CrucialX9", "LaCie"] {
            let rec = VideoRecord(); rec.fullPath = "/Volumes/\(v)/loose.mov"; f.records.append(rec)
            f.rows.append(FootageFolders.Row(id: rec.id, digest: nil, sizeBytes: 1, durationSeconds: 1, volume: v,
                                             keys: FootageFolders.SortKeys(filename: "loose.mov", volume: v, duration: 1, size: 1)))
        }
        return f
    }

    private func folderIDs(_ d: FootageFolders.Display, _ f: Fixture) -> Set<UUID> {
        Set(d.rows.map(\.id)).intersection(f.onX9.union(f.elsewhere))
    }

    @Test func oneVolumeSelectedShowsExactlyItsFoldersAndTheLineSaysSo() throws {
        let f = fixture()
        // The same predicate computeFiltered uses for the Volumes-pane filter.
        let visible = f.records.filter { pfRecordOnSelectedVolume($0, prefixes: ["/Volumes/CrucialX9"]) }.map(\.id)
        let narrowed = FootageFolders.build(rows: f.rows, events: f.events, visible: visible, foldersOnly: true)
        #expect(folderIDs(narrowed, f) == f.onX9, "exactly the three folders on CrucialX9")

        let whole = FootageFolders.build(rows: f.rows, events: f.events, visible: f.records.map(\.id), foldersOnly: true)
        #expect(folderIDs(whole, f).count == 6, "no selection: every folder")

        // The defect: the line did not say why three of six showed.
        let first = try #require(Summary.pills(for: ricksState(["CrucialX9"])).first)
        #expect(first.text == "CrucialX9" && first.action == .clearVolumes)
        #expect(Summary.sentence(for: ricksState(["CrucialX9"])).hasPrefix("Showing CrucialX9, "))
        #expect(Summary.pills(for: ricksState([])).first?.text == "All kinds", "cleared: back to the whole catalog, no pill")
    }
}

// MARK: - Sensors

@Suite("Showing line — volume pill wiring sensors")
struct CatalogVolumePillSensorTests {

    @Test func toolbarDrawsThePillAndClearsThroughTheParent() throws {
        let toolbar = try code("CatalogToolbar.swift")
        #expect(toolbar.contains("selectedVolumeLabels: selectedVolumeLabels"), "the state carries the labels")
        #expect(toolbar.contains("CatalogVolumePill(labels: selectedVolumeLabels, onClear: onClearVolumeSelection)"), "the pill is drawn")
    }

    @Test func parentFeedsPaneLabelsAndClearsThroughTheOneSeam() throws {
        let content = try code("ContentView.swift")
        #expect(content.contains("selectedVolumeLabels: selectedVolumeLabels,"))
        #expect(content.contains("CatalogShowingSummary.volumeSelection(after: .clearVolumes, selectedVolumeIDs)"))
        #expect(content.contains("VolumeReachability.displayLabel(forPath:"), "the Volumes pane's own label")
        #expect(content.contains("@State var selectedVolumeIDs: Set<UUID> = []"), "session-only: launch shows the whole catalog")
    }

    @Test func emptyNoteGetsTheLabels() throws {
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("case .noFolders: FoldersOnlyEmptyNote(volumeLabels: selectedVolumeLabels"))
    }
}
