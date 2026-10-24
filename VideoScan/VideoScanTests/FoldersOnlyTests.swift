// FoldersOnlyTests.swift
// Show ▸ Folders Only (Rick 2026-10-19): the folder view with the loose
// files left out — only folders and, when open, what is in them.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — loose rows and loose copy families dropped; folders and
//               open members kept; filters and search still apply inside
//               folders; nothing matching → an empty display flagged
//               foldersOnly; scopes untouched; off = today's display; the
//               implication rule both ways; the pill; an honest
//               derivative reveal.
//   Scale     — N/A beyond the existing 100k compose budget
//               (FootageFoldersScaleTests): Folders Only only skips work.
//   Isolation — the setting's strict read (poisoned value → off) and the
//               launch rule, on a private defaults suite.
//   Sensor    — the toggle is in the Show menu, Clear All Filters leaves
//               it alone, the compose reads the key-monitor mirror, and
//               the option adds no `refreshRows()` trigger.
// Media matrix: N/A — catalog metadata only; no file is opened.
//
// Suites (filter by SUITE — method-level -only-testing runs zero tests):
//   FoldersOnlyLogicTests · FoldersOnlyIsolationTests · FoldersOnlySensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row

private func row(_ name: String, digest: String? = nil, volume: String = "LaCie", id: UUID = UUID()) -> Row {
    Row(id: id, digest: digest, sizeBytes: 1_000, durationSeconds: 60, volume: volume,
        keys: FootageFolders.SortKeys(filename: name, volume: volume, duration: 60, size: 1_000))
}

private func event(_ title: String, _ rows: [Row]) -> FootageFolders.Event {
    FootageFolders.Event(id: UUID(), title: title, contentKeys: rows.map(\.contentKey))
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

/// One folder of two recordings, a loose file, and a loose copy family
/// (the same digest on two volumes).
private struct Stage {
    let a = row("a.mov", digest: "aaaa"), b = row("b.mov", digest: "bbbb")
    let loose = row("z.mov")
    let copy1 = row("c.mov", digest: "cccc"), copy2 = row("c.mov", digest: "cccc", volume: "Backup")
    let folder: FootageFolders.Event
    var rows: [Row] { [a, b, loose, copy1, copy2] }

    init() { folder = event("Thanksgiving 2009", [a, b]) }
}

// MARK: - Logic

@Suite("Folders Only — what the folder view shows")
struct FoldersOnlyLogicTests {

    @Test func looseRowsAndLooseFamiliesAreDropped() {
        let s = Stage()
        let all = FootageFolders.build(rows: s.rows, events: [s.folder])
        #expect(all.rows.contains { $0.id == s.loose.id }, "off: the loose file shows")
        let only = FootageFolders.build(rows: s.rows, events: [s.folder], foldersOnly: true)
        #expect(only.rows.map(\.id) == [s.folder.id, s.a.id, s.b.id], "folder (open) and its two recordings, nothing loose")
        #expect(only.foldersOnly)
        #expect(only.summaries[s.folder.id]?.files == 2)
    }

    @Test func aClosedFolderIsItsOneRow() {
        let s = Stage()
        let only = FootageFolders.build(rows: s.rows, events: [s.folder], open: [], foldersOnly: true)
        #expect(only.rows.map(\.id) == [s.folder.id])
    }

    @Test func filtersAndSearchStillApplyInsideFolders() {
        let s = Stage()
        let narrowed = FootageFolders.build(rows: s.rows, events: [s.folder],
                                            visible: [s.b.id, s.loose.id], foldersOnly: true)
        #expect(narrowed.rows.map(\.id) == [s.folder.id, s.b.id], "a folder shows when any visible member matches, with only those members")
    }

    @Test func nothingMatchingIsAnEmptyFlaggedDisplay() {
        let s = Stage()
        let onlyLoose = FootageFolders.build(rows: s.rows, events: [s.folder],
                                             visible: [s.loose.id, s.copy1.id], foldersOnly: true)
        #expect(onlyLoose.rows.isEmpty)
        #expect(onlyLoose.foldersOnly, "flagged, so the table can say \"No folders match\"")
        let noFolders = FootageFolders.build(rows: s.rows, events: [], foldersOnly: true)
        #expect(noFolders.rows.isEmpty && noFolders.foldersOnly)
        #expect(noFolders != .empty, "differs from the stop() display, so it is published")
    }

    @Test func offIsTodaysDisplayExactly() {
        let s = Stage()
        let before = FootageFolders.build(rows: s.rows, events: [s.folder])
        let off = FootageFolders.build(rows: s.rows, events: [s.folder], foldersOnly: false)
        #expect(before == off)
        #expect(!off.foldersOnly)
    }

    @Test func scopesAreShownAsTheyAre() {
        let s = Stage()
        let family = FootageFolders.build(rows: s.rows, events: [s.folder], scope: .family(s.copy1.id), foldersOnly: true)
        #expect(Set(family.rows.map(\.id)) == [s.copy1.id, s.copy2.id], "Show Copies & Related… is an explicit narrowing")
        let inside = FootageFolders.build(rows: s.rows, events: [s.folder], scope: .event(s.folder.id), foldersOnly: true)
        #expect(inside.rows.map(\.id) == [s.folder.id, s.a.id, s.b.id])
    }

    @MainActor
    @Test func snapshotCarriesTheFlagThroughTheRequest() {
        let s = Stage()
        let snap = FootageFoldersSnapshot()
        snap.publish(index: FootageFolders.index(rows: s.rows, events: [s.folder]))
        snap.composeNow(visible: s.rows.map(\.id), sort: .byName, open: [s.folder.id], scope: nil, foldersOnly: true)
        #expect(snap.request?.foldersOnly == true)
        #expect(snap.display.rows.map(\.id) == [s.folder.id, s.a.id, s.b.id])
        snap.composeNow(visible: s.rows.map(\.id), sort: .byName, open: [s.folder.id], scope: nil)
        #expect(snap.display.rows.contains { $0.id == s.loose.id }, "default off brings the loose rows back")
    }

    @Test func foldersOnlyImpliesTheFolderViewBothWays() {
        // Folders Only flipped.
        #expect(CatalogFoldersOnlyRule.folders(afterFoldersOnly: true, folders: false) == true, "on → the folder view turns on")
        #expect(CatalogFoldersOnlyRule.folders(afterFoldersOnly: true, folders: true) == true)
        #expect(CatalogFoldersOnlyRule.folders(afterFoldersOnly: false, folders: true) == true, "off leaves the folder view on")
        #expect(CatalogFoldersOnlyRule.folders(afterFoldersOnly: false, folders: false) == false)
        // The folder view flipped.
        #expect(CatalogFoldersOnlyRule.foldersOnly(afterFolders: false, foldersOnly: true) == false, "folder view off → Folders Only off")
        #expect(CatalogFoldersOnlyRule.foldersOnly(afterFolders: true, foldersOnly: false) == false, "on does not turn Folders Only on")
        #expect(CatalogFoldersOnlyRule.foldersOnly(afterFolders: true, foldersOnly: true) == true)
    }

    @Test func pillSaysFoldersOnlyInsteadOfAsFolders() {
        var st = CatalogShowingSummary.State()
        st.foldersOnly = true
        #expect(!CatalogShowingSummary.pills(for: st).map(\.text).contains(FootageFolderWords.foldersOnlyPill),
                "never without the folder view")
        st.footageFolders = true
        let texts = CatalogShowingSummary.pills(for: st).map(\.text)
        #expect(texts.contains("Folders only"))
        #expect(!texts.contains(FootageFolderWords.showingPill), "one pill, not two")
        st.foldersOnly = false
        #expect(CatalogShowingSummary.pills(for: st).map(\.text).contains(FootageFolderWords.showingPill))
    }

    @Test func aLooseDerivativeIsNotClaimedSelectedUnderFoldersOnly() {
        let s = Stage()
        let index = FootageFolders.index(rows: s.rows, events: [s.folder])
        let fromLoose = DerivativeLanding(id: UUID(), sourceID: s.loose.id, kind: "transcode", at: Date())
        #expect(DerivativeReveal.plan(landing: fromLoose, inTable: true, foldersOn: true, scope: nil,
                                      index: index, foldersOnly: true) == .hiddenByFilter)
        #expect(DerivativeReveal.plan(landing: fromLoose, inTable: true, foldersOn: true, scope: nil,
                                      index: index) == .select, "without Folders Only it shows loose")
        let fromFolder = DerivativeLanding(id: UUID(), sourceID: s.a.id, kind: "transcode", at: Date())
        #expect(DerivativeReveal.plan(landing: fromFolder, inTable: true, foldersOn: true, scope: nil,
                                      index: index, foldersOnly: true) == .select, "its source's folder is entered")
    }
}

// MARK: - Isolation

@Suite("Folders Only — the remembered setting")
struct FoldersOnlyIsolationTests {

    @Test func onlyAPlistBooleanReadsAsOn() throws {
        let suite = "FoldersOnlyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CatalogFoldersOnlySetting.key == "catalog.foldersOnly")
        #expect(CatalogFoldersOnlySetting.key != CatalogFootageFoldersSetting.key, "its own key")
        #expect(CatalogFoldersOnlySetting.isOn(defaults) == false, "absent → off")
        for poison: Any in [1, 1.0, "true", "yes", [true], ["on": true]] {
            defaults.set(poison, forKey: CatalogFoldersOnlySetting.key)
            #expect(CatalogFoldersOnlySetting.isOn(defaults) == false, "\(poison) → off, never on")
        }
        CatalogFoldersOnlySetting.set(true, defaults)
        #expect(CatalogFoldersOnlySetting.isOn(defaults) == true, "a real Bool round-trips")
        CatalogFoldersOnlySetting.set(false, defaults)
        #expect(CatalogFoldersOnlySetting.isOn(defaults) == false)
    }

    @Test func launchNeedsTheFolderViewToo() throws {
        let suite = "FoldersOnlyTests-launch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CatalogFoldersOnlySetting.set(true, defaults)
        #expect(CatalogFoldersOnlyRule.launchFoldersOnly(defaults) == false, "folder view absent → off")
        defaults.set(1, forKey: CatalogFootageFoldersSetting.key)
        #expect(CatalogFoldersOnlyRule.launchFoldersOnly(defaults) == false, "folder view poisoned → off")
        // CFPreferences skips writing `true` over an integer 1 (NSNumber
        // calls them equal), so clear the poison before the real write.
        defaults.removeObject(forKey: CatalogFootageFoldersSetting.key)
        CatalogFootageFoldersSetting.set(true, defaults)
        #expect(CatalogFoldersOnlyRule.launchFoldersOnly(defaults) == true)
    }
}

// MARK: - Sensors

@Suite("Folders Only — wiring sensors")
struct FoldersOnlySensorTests {

    @Test func toggleSitsInTheFoldersSectionAndClearAllLeavesIt() throws {
        let toolbar = try code("CatalogToolbar.swift")
        let section = try #require(toolbar.range(of: "Section(\"Show files — as folders\") {"))
        #expect(toolbar[section.upperBound...].prefix(160).contains("FoldersOnlyShowToggle(isOn: $showFoldersOnly)"))
        let clear = try #require(toolbar.range(of: "Button(\"Clear All Filters\")"))
        #expect(!toolbar[clear.upperBound...].prefix(80).contains("showFoldersOnly"), "a view shape, not a filter")
        #expect(FootageFolderWords.foldersOnlyHelp
                == "Show only your folders and what's in them — files in no folder are hidden. Click again to show everything.")
    }

    @Test func rememberedAndImpliedInTheParent() throws {
        let content = try code("ContentView.swift")
        #expect(content.contains("@State private var showFoldersOnly: Bool = CatalogFoldersOnlyRule.launchFoldersOnly()"))
        #expect(content.contains("CatalogFoldersOnlySetting.set(showFoldersOnly)"))
        #expect(content.contains("CatalogFoldersOnlyRule.folders(afterFoldersOnly: showFoldersOnly"))
        #expect(content.contains("CatalogFoldersOnlyRule.foldersOnly(afterFolders: showFootageFolders"))
    }

    /// The compose reads the key-monitor mirror (a level change from the
    /// monitor must not bring loose rows back), and the option recomposes
    /// without a `refreshRows()` — the CatalogFocusPlanSensorTests pin is
    /// unchanged.
    @Test func composeReadsTheMirrorAndAddsNoRefreshRows() throws {
        let folder = try code("CatalogContent+FolderTable.swift")
        #expect(folder.contains("foldersOnly: tableState.folderKeyMirror.foldersOnly"))
        let table = try code("CatalogContent+Table.swift")
        #expect(table.contains(".onChange(of: showFoldersOnly) { foldersOnlyOptionChanged() }"))
        let fn = try #require(folder.range(of: "func foldersOnlyOptionChanged() {"))
        #expect(!folder[fn.upperBound...].prefix(200).contains("refreshRows()"))
    }

    @Test func emptyNoteShowsOnlyAtTheTopWithTheFolderView() throws {
        let helpers = try code("CatalogHelpers.swift")
        #expect(helpers.contains("foldersOnlyFindsNothing: showFootageFolders && tableState.folderScope == nil"))
        #expect(helpers.contains("case .noFolders: FoldersOnlyEmptyNote(volumeLabels: selectedVolumeLabels"))
        #expect(FootageFolderWords.foldersOnlyEmpty.hasPrefix("No folders match"))
    }

    @Test func theSearchsNoMatchesWinsOverNoFolders() {
        #expect(CatalogEmptyNote.pick(rowsEmpty: true, searching: true, foldersOnlyFindsNothing: true) == .noMatches)
        #expect(CatalogEmptyNote.pick(rowsEmpty: false, searching: true, foldersOnlyFindsNothing: true) == .noFolders,
                "rows survive the search but none is in a folder")
        #expect(CatalogEmptyNote.pick(rowsEmpty: true, searching: false, foldersOnlyFindsNothing: false) == .none)
        #expect(CatalogEmptyNote.pick(rowsEmpty: false, searching: false, foldersOnlyFindsNothing: false) == .none)
    }
}
