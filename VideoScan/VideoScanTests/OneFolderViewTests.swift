// OneFolderViewTests.swift
// Catalog ▸ Show ▸ Folders — the ONE folder view (DECISIONS 2026-11-17, "The
// Catalog's Show menu is cut to the bare minimum" and "final shape for now"):
// every folder, Rick's (blue) and the machine's (grey), then the media files
// in no folder, in one list, so a file can be moved into a folder. The three
// folder modes (Events & Copies as Folders · Folders Only · Folders by Machine
// Estimate) are gone.
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      Rick's folders before the machine's before loose files, each
//              group by date then name; a file Rick filed is never also in a
//              grey folder, and neither is its version; the Show filters
//              apply inside folders and a folder they empty is hidden; a
//              selected row in a grey folder stays there when the estimate
//              re-files it, until the selection moves; a drag out of a grey
//              folder adds (it never claims to move out of a folder Rick
//              does not have).
//   TRUTH      the Showing box says "Folders" (and still "Everything": the
//              view drops no file); the grey folder's symbol is a real symbol.
//   SCALE      100k rows, 2k of Rick's folders, 50k rows with an era: the
//              join, the compose and the top level inside the existing budgets.
//   ISOLATION  the switch's stored value, poisoned or left by an older build
//              (the three retired keys, poisoned too), migrates once, logged,
//              and never crashes; a hold for a row that left is dropped.
//   SENSOR     one folder control in the Show menu, beside Show disconnected
//              media; only the store names the keys or writes the switch; the
//              grey hold is released by the held-row release.
//   MEDIA      N/A — catalog metadata only; no file is opened.
//   WRITER quartet: N/A — the switch is a preference, not a catalog write.
// Synthetic names and digests only.
//
// Suites (filter by SUITE): OneFolderViewLogicTests · OneFolderViewTruthTests ·
// OneFolderViewScaleTests · OneFolderViewIsolationTests · OneFolderViewSensorTests

import AppKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private func row(_ name: String, _ n: Int, date: Date = .distantPast, from: UUID? = nil, id: UUID = UUID()) -> Row {
    Row(id: id, digest: hex(n), sizeBytes: 1_000, durationSeconds: 60, derivedFrom: from,
        keys: FootageFolders.SortKeys(filename: name, duration: 60, size: 1_000, date: date))
}

private func era(_ lo: Int, _ hi: Int) -> MachineEra {
    MachineEra(lo: lo, hi: hi, by: "machine:test/era-v1", at: 1_762_000_000, seq: 1)
}

private func day(_ year: Int) -> Date {
    DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                   year: year, month: 6, day: 1, hour: 12).date ?? .distantPast
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

/// What the model's refresh does, as one pure call: Rick's folders, then the
/// machine's for every content he has not filed, joined once.
private func join(_ rows: [Row], own: [FootageFolders.Event], eras: [String: [MachineEra]],
                  held: [UUID: MachineEraResolver.EstimateFolder] = [:]) -> FootageFolders.Index {
    FootageFolders.index(rows: rows, events: FootageFolders.oneViewEvents(rows: rows, own: own, eras: eras, held: held))
}

private func top(_ index: FootageFolders.Index, visible: [UUID]) -> FootageFolderLevel.Level {
    let display = FootageFolders.compose(index: index, visible: visible, sort: .byName,
                                         open: Set(index.folders.keys), scope: nil)
    return FootageFolderLevel.top(index: index, display: display)
}

/// Two of Rick's folders (one dated 2005, one undated), two grey folders
/// (the 1980s and 1991), two loose files.
private struct Stage {
    let blueNew = row("party.mov", 1, date: day(2005))
    let blueOld = row("wedding.mov", 2)
    let grey80s = row("beach.mov", 3, date: day(1984))
    let grey91 = row("birthday.mov", 4, date: day(1991))
    let looseA = row("a.mov", 5), looseZ = row("z.mov", 6)
    let party: FootageFolders.Event, wedding: FootageFolders.Event
    var rows: [Row] { [looseA, blueNew, grey80s, blueOld, grey91, looseZ] }
    var eras: [String: [MachineEra]] {
        [hex(3): [era(1980, 1995)], hex(4): [era(1991, 1991)], hex(1): [era(1970, 1979)]]
    }

    init() {
        party = FootageFolders.Event(title: "Party", contentKeys: [blueNew.contentKey])
        wedding = FootageFolders.Event(title: "Wedding", contentKeys: [blueOld.contentKey])
    }

    var index: FootageFolders.Index { join(rows, own: [party, wedding], eras: eras) }
}

// MARK: - Logic

@Suite("One folder view — what it shows and in what order")
struct OneFolderViewLogicTests {

    @Test("LOGIC: Rick's folders, then the machine's, then the files in no folder")
    func blueThenGreyThenLoose() throws {
        let s = Stage()
        let level = top(s.index, visible: s.rows.map(\.id))
        let grey = level.rows.compactMap(\.eventID).filter { MachineEstimateFolders.isEstimateFolder($0) }
        let blue = level.rows.compactMap(\.eventID).filter { !MachineEstimateFolders.isEstimateFolder($0) }
        #expect(blue == [s.wedding.id, s.party.id], "Rick's by date (undated first, as the Finder), then name")
        #expect(grey.map { level.folders[$0]?.name } == ["1980s (estimated)", "1991 (estimated)"])
        #expect(level.rows.map(\.id) == blue + grey + [s.looseA.id, s.looseZ.id],
                "every folder first — Rick's before the machine's even when the machine's is older — then the loose files")
        #expect(level.folders.values.filter(\.byMachine).count == 2 && level.folders.values.filter { !$0.byMachine }.count == 2)
        // Expanding a folder shows its files.
        #expect(level.children[s.party.id]?.compactMap(\.recordID) == [s.blueNew.id])
        #expect(level.children[grey[0]]?.compactMap(\.recordID) == [s.grey80s.id])
    }

    @Test("LOGIC: a file Rick filed is never also in a grey folder, and neither is a version of it")
    func ricksFoldersOutrankTheMachines() throws {
        let s = Stage()
        let index = s.index
        #expect(index.folders(of: s.blueNew.id) == [s.party.id], "it has an era (1970s) but Rick filed it")
        #expect(!index.folders.values.contains { $0.title == "1970s (estimated)" }, "no grey folder for a filed content")
        // A transcode of Rick's filed recording carries its own era: it still follows the recording into Rick's folder.
        let version = row("party.mkv", 9, from: s.blueNew.id)
        let joined = join(s.rows + [version], own: [s.party, s.wedding], eras: s.eras.merging([hex(9): [era(1960, 1969)]]) { a, _ in a })
        #expect(joined.folders(of: version.id) == [s.party.id], "a version follows its recording into Rick's folder")
        #expect(!joined.folders.values.contains { $0.title == "1960s (estimated)" })
        // A version made from a GREY-filed recording, with no era, follows it into the grey folder (unchanged rule).
        let clip = row("beach clip.mov", 10, from: s.grey80s.id)
        let greyJoin = join(s.rows + [clip], own: [s.party, s.wedding], eras: s.eras)
        #expect(greyJoin.folder(containing: clip.id)?.title == "1980s (estimated)")
    }

    @Test("LOGIC: the Show filters apply inside folders; a folder they empty is hidden, blue or grey")
    func filtersApplyInsideFolders() throws {
        let s = Stage()
        let second = row("party2.mov", 7, date: day(2006))
        let party = FootageFolders.Event(id: s.party.id, title: "Party", contentKeys: [s.blueNew.contentKey, second.contentKey])
        let index = join(s.rows + [second], own: [party, s.wedding], eras: s.eras)
        // The filter's survivors: one of Party's two files, the 1991 file, one loose file.
        let level = top(index, visible: [second.id, s.grey91.id, s.looseZ.id])
        let folders = level.rows.compactMap(\.eventID)
        #expect(folders.contains(party.id))
        #expect(level.children[party.id]?.compactMap(\.recordID) == [second.id], "only the matching file shows inside")
        #expect(!folders.contains(s.wedding.id), "Rick's folder with no matching file is hidden")
        #expect(folders.filter { MachineEstimateFolders.isEstimateFolder($0) }.map { level.folders[$0]?.name }
                == ["1991 (estimated)"], "the 1980s grey folder's only file is filtered out: hidden")
        #expect(level.rows.compactMap(\.recordID) == [s.looseZ.id], "the loose file that matches, nothing else")
    }

    @Test("LOGIC: a selected row in a grey folder stays put when the estimate re-files it, until the selection moves")
    @MainActor
    func aSelectedGreyRowDoesNotJump() throws {
        let s = Stage()
        let snapshot = FootageFoldersSnapshot()
        snapshot.publish(index: s.index)
        let eighties = MachineEstimateFolders.folderID(.decade(1980))
        #expect(s.index.folders(of: s.grey80s.id) == [eighties])

        // Rick selects the beach file; the hold is taken from what he sees.
        #expect(snapshot.holdMachinePlacement(selected: [s.grey80s.id]) == false, "taking a hold re-joins nothing")
        #expect(snapshot.machineHolds == [s.grey80s.id: .decade(1980)])

        // The era job re-runs: the beach file is now a 2000s guess. Held: it stays in the 1980s.
        var eras = s.eras
        eras[hex(3)] = [era(2000, 2010)]
        let rerun = join(s.rows, own: [s.party, s.wedding], eras: eras, held: snapshot.machineHolds)
        #expect(rerun.folders(of: s.grey80s.id) == [eighties], "the selected row does not jump")
        let diverged = FootageFolders.divergedHolds(rows: s.rows, own: [s.party, s.wedding], eras: eras, held: snapshot.machineHolds)
        #expect(diverged == [s.grey80s.id])
        snapshot.publish(index: rerun, divergedHolds: diverged)

        // Another click in the same folder keeps the hold; moving off releases it and asks for a re-join.
        #expect(snapshot.holdMachinePlacement(selected: [s.grey80s.id, s.looseA.id]) == false)
        #expect(snapshot.holdMachinePlacement(selected: [s.looseA.id]) == true, "released, and it now differs: re-join")
        #expect(snapshot.machineHolds.isEmpty)
        let after = join(s.rows, own: [s.party, s.wedding], eras: eras, held: snapshot.machineHolds)
        #expect(after.folder(containing: s.grey80s.id)?.title == "2000s (estimated)", "it moves once the selection has moved")
    }

    @Test("LOGIC: a release whose row would not move asks for no re-join")
    @MainActor
    func aReleaseThatChangesNothingIsFree() {
        let s = Stage()
        let snapshot = FootageFoldersSnapshot()
        snapshot.publish(index: s.index)
        _ = snapshot.holdMachinePlacement(selected: [s.grey91.id])
        #expect(snapshot.holdMachinePlacement(selected: []) == false, "the estimate did not change: nothing to redo")
    }

    @Test("LOGIC: only grey placements are held; Rick's folders and loose files are not")
    @MainActor
    func onlyGreyIsHeld() {
        let s = Stage()
        let snapshot = FootageFoldersSnapshot()
        snapshot.publish(index: s.index)
        _ = snapshot.holdMachinePlacement(selected: [s.blueNew.id, s.looseA.id, s.party.id, s.grey91.id])
        #expect(snapshot.machineHolds == [s.grey91.id: .year(1991)])
    }

    @Test("LOGIC: an estimate folder's id names its year or decade back")
    func estimateFolderIDsRoundTrip() {
        for f: MachineEraResolver.EstimateFolder in [.year(1991), .decade(1980), .year(0), .decade(2020)] {
            #expect(MachineEstimateFolders.estimateFolder(fromID: MachineEstimateFolders.folderID(f)) == f, "\(f)")
        }
        #expect(MachineEstimateFolders.estimateFolder(fromID: UUID()) == nil, "one of Rick's ids is no estimate")
        #expect(MachineEstimateFolders.estimateFolder(fromID: MachineEstimateFolders.unknownFolderID) == nil)
    }

    @Test("LOGIC: a drag out of a grey folder ADDS to Rick's folder; out of Rick's folder it MOVES (one engine)")
    @MainActor
    func aDragOutOfAGreyFolderIsAnAdd() {
        let record = UUID(), blue = UUID(), grey = MachineEstimateFolders.folderID(.decade(1980))
        let fromGrey = FootageFolderTableRow(display: .member(record, .recording), record: nil, keys: .init(), inFolder: grey)
        let fromBlue = FootageFolderTableRow(display: .member(record, .recording), record: nil, keys: .init(), inFolder: blue)
        let target = UUID()
        let greyItems = CatalogRecordDrag.items(in: [CatalogContent.dragPayload(fromGrey)])
        #expect(greyItems == [CatalogRecordDrag.Item(record: record, folder: nil)], "the grey folder is not one of Rick's")
        #expect(CatalogRecordDrag.mode(for: greyItems, target: target, optionHeld: false) == .add)
        let blueItems = CatalogRecordDrag.items(in: [CatalogContent.dragPayload(fromBlue)])
        #expect(CatalogRecordDrag.mode(for: blueItems, target: target, optionHeld: false) == .move(from: blue))
    }
}

// MARK: - Truth

@Suite("One folder view — the Showing box and the glyphs tell the truth")
struct OneFolderViewTruthTests {

    @Test("TRUTH: the Showing box names Folders while the view is on, and only then")
    func theBoxSaysFolders() {
        var s = CatalogShowingSummary.State()
        #expect(!CatalogShowingSummary.pills(for: s).map(\.text).contains("Folders"))
        s.footageFolders = true
        let texts = CatalogShowingSummary.pills(for: s).map(\.text)
        #expect(texts.contains("Folders"))
        #expect(texts.first == CatalogShowingSummary.everything, "the folder view lists every file: still Everything")
        for gone in ["As folders", "Folders only", "By machine estimate"] {
            #expect(!texts.contains(gone), "a retired mode's pill: \(gone)")
        }
        #expect(CatalogShowingSummary.sentence(for: s).contains("Folders"))
        #expect(CatalogShowingSummary.help(for: s).contains("Folders"))
    }

    @Test("TRUTH: the switch is named Folders in the menu and in the box — one word")
    func oneWord() {
        #expect(FootageFolderWords.showOptionTitle == "Folders")
        #expect(FootageFolderWords.showingPill == FootageFolderWords.showOptionTitle)
    }

    @Test("TRUTH: Rick's folders and the machine's are drawn apart, with symbols that exist")
    func theGlyphsExist() {
        for name in [FootageFolderWords.folderSymbol, FootageFolderWords.machineFolderSymbol] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol")
        }
        #expect(FootageFolderWords.folderSymbol != FootageFolderWords.machineFolderSymbol)
        #expect(FootageFolderWords.legend.contains("grey"), "the legend says what a grey folder is")
    }
}

// MARK: - Scale

@Suite("One folder view — scale")
struct OneFolderViewScaleTests {

    /// 100k rows; 2k of Rick's folders of 20 recordings (40k rows); 50k of the
    /// rest with an era over 12 decades; 10k loose. Each step inside the
    /// budget it already has: building the grey events 500 ms
    /// (MachineEstimateFoldersScaleTests), the join 1.5 s and the compose
    /// 1.5 s (FootageFoldersScaleTests) — the compose here with the top level.
    @Test func hundredThousandRowsWithBlueAndGreyFolders() {
        var rows: [Row] = []
        rows.reserveCapacity(100_000)
        var own: [FootageFolders.Event] = []
        var eras: [String: [MachineEra]] = [:]
        eras.reserveCapacity(50_000)
        var keys: [[String]] = Array(repeating: [], count: 2_000)
        for i in 0..<100_000 {
            let r = row("clip\(i).mov", i, date: Date(timeIntervalSince1970: Double(i) * 3_600))
            rows.append(r)
            if i < 40_000 { keys[i / 20].append(r.contentKey) }
            else if i < 90_000 {
                let lo = 1900 + i % 120
                eras[hex(i)] = [i % 20 == 0 ? era(lo, lo) : era(lo, lo + 15)]
            }
            if i % 4 == 0, i < 40_000 { eras[hex(i)] = [era(1990, 2000)] }   // filed by Rick: must not go grey
        }
        for (i, k) in keys.enumerated() { own.append(.init(title: "Event \(i)", contentKeys: k)) }

        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let events = FootageFolders.oneViewEvents(rows: rows, own: own, eras: eras, held: [:])
        let built = ContinuousClock.now - start
        let joinStart = ContinuousClock.now
        let index = FootageFolders.index(rows: rows, events: events)
        let joined = ContinuousClock.now - joinStart
        let composeStart = ContinuousClock.now
        let display = FootageFolders.compose(index: index, visible: rows.map(\.id), sort: .byName,
                                             open: Set(index.folders.keys), scope: nil)
        let level = FootageFolderLevel.top(index: index, display: display)
        let composed = ContinuousClock.now - composeStart

        let grey = index.folders.values.filter(\.byMachine)
        #expect(index.folders.count - grey.count == 2_000, "every one of Rick's folders")
        #expect(!grey.isEmpty && grey.count < 200, "a few hundred grey folders at most (decades and exact years)")
        #expect(grey.reduce(0) { $0 + $1.summary.files } == 50_000, "every unfiled row with an era, once")
        #expect(level.rows.count == index.folders.count + 10_000, "every folder, then the 10k loose files")
        let firstGrey = level.rows.firstIndex { $0.eventID.map(MachineEstimateFolders.isEstimateFolder) ?? false }
        let lastBlue = level.rows.lastIndex { $0.eventID.map { !MachineEstimateFolders.isEstimateFolder($0) } ?? false }
        #expect((lastBlue ?? 0) < (firstGrey ?? .max), "every blue folder before every grey one")
        expectWithinTimingBudget("one folder view: Rick's + grey events, 100k rows / 2k blue / 50k eras",
                                 measured: built, budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
        expectWithinTimingBudget("one folder view: the join, 100k rows / 2k blue / grey folders",
                                 measured: joined, budget: PerformanceLane.debugCeiling(.milliseconds(1_500)), loadBefore: load)
        expectWithinTimingBudget("one folder view: compose + top level, 100k visible, every folder open",
                                 measured: composed, budget: PerformanceLane.debugCeiling(.milliseconds(1_500)), loadBefore: load)
    }
}

// MARK: - Isolation

@MainActor
@Suite("One folder view — the stored switch, old or poisoned")
struct OneFolderViewIsolationTests {

    private final class Lines { var all: [String] = [] }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "one-folder-view-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private let retired = ["catalog.footageFolders", "catalog.foldersOnly", "catalog.foldersByMachineEstimate"]

    @Test("ISOLATION: any one of the three old folder settings on → Folders on, logged once, the old keys gone")
    func anyOldSettingOnTurnsFoldersOn() {
        for key in retired {
            withDefaults { defaults in
                defaults.set(true, forKey: key)
                let lines = Lines()
                let store = CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
                #expect(store.foldersOn, "\(key) on → Folders on")
                #expect(lines.all.filter { $0.contains("one Folders switch") }.count == 1, "\(lines.all)")
                #expect(lines.all.last?.hasSuffix("→ Folders on") == true, "\(lines.all)")
                for k in retired { #expect(defaults.object(forKey: k) == nil, "\(k) deleted") }
                #expect(defaults.object(forKey: CatalogShowFilterStore.foldersKey) as? Bool == true)
                // Relaunch: no second migration line, still on.
                let again = Lines()
                let next = CatalogShowFilterStore(defaults: defaults, log: { again.all.append($0) })
                #expect(next.foldersOn)
                #expect(!again.all.contains { $0.contains("one Folders switch") })
            }
        }
    }

    @Test("ISOLATION: the old settings all off, or poisoned (a number, a string, an array) → Folders off, said once")
    func oldSettingsOffOrPoisoned() {
        let poisons: [Any] = [false, 1, 1.0, "true", [true], ["on": true], Data([1])]
        for poison in poisons {
            withDefaults { defaults in
                for key in retired { defaults.set(poison, forKey: key) }
                let lines = Lines()
                let store = CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
                #expect(!store.foldersOn, "\(poison) is never on")
                #expect(lines.all.contains { $0.contains("one Folders switch") && $0.hasSuffix("→ Folders off") }, "\(lines.all)")
                for k in retired { #expect(defaults.object(forKey: k) == nil) }
            }
        }
    }

    @Test("ISOLATION: a poisoned stored switch reads off, is rewritten, and says so")
    func poisonedSwitch() {
        for poison: Any in [1, "yes", [true], Data([0xFF])] {
            withDefaults { defaults in
                defaults.set(poison, forKey: CatalogShowFilterStore.foldersKey)
                let lines = Lines()
                let store = CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
                #expect(!store.foldersOn)
                #expect(defaults.object(forKey: CatalogShowFilterStore.foldersKey) as? Bool == false, "rewritten clean")
                #expect(lines.all.contains { $0.contains("Folders setting was unreadable") }, "\(lines.all)")
            }
        }
    }

    @Test("ISOLATION: the new switch wins over an old key an older build wrote back; that key is cleared silently")
    func newKeyWins() {
        withDefaults { defaults in
            defaults.set(false, forKey: CatalogShowFilterStore.foldersKey)
            defaults.set(true, forKey: "catalog.foldersOnly")
            let lines = Lines()
            let store = CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
            #expect(!store.foldersOn)
            #expect(defaults.object(forKey: "catalog.foldersOnly") == nil)
            #expect(lines.all == ["Catalog Show filters: restored at launch → none"], "nothing more to say: \(lines.all)")
        }
    }

    @Test("LOGGING: a flip is one line naming who; no change, no line; Clear All Filters leaves it")
    func flipsAreLogged() {
        withDefaults { defaults in
            let lines = Lines()
            let store = CatalogShowFilterStore(defaults: defaults, log: { lines.all.append($0) })
            store.setFolders(true, by: .showMenu)
            #expect(lines.all.last == "Catalog Show filters: on: Folders (by Show menu)")
            store.setFolders(true, by: .folderReveal)
            #expect(lines.all.count == 2, "no change, no line")
            store.set(.needsDate, on: true, by: .showMenu)
            store.clearAll(by: .showMenu)
            #expect(store.foldersOn, "a view shape, not a filter")
            store.setFolders(false, by: .folderReveal)
            #expect(lines.all.last == "Catalog Show filters: off: Folders (by \(CatalogShowFilterStore.Writer.folderReveal.rawValue))")
            let relaunch = CatalogShowFilterStore(defaults: defaults, log: { _ in })
            #expect(!relaunch.foldersOn, "persisted")
        }
    }

    @Test("ISOLATION: a hold for a row that has left the view is dropped, never re-filed")
    @MainActor
    func aHoldForAGoneRowIsDropped() {
        let held: [UUID: MachineEraResolver.EstimateFolder] = [UUID(): .decade(1950)]
        let r = row("x.mov", 1)
        let events = FootageFolders.oneViewEvents(rows: [r], own: [], eras: [:], held: held)
        #expect(events.isEmpty, "no row, no folder")
    }
}

// MARK: - Sensors

@Suite("One folder view — one control, one owner")
struct OneFolderViewSensorTests {

    private func appFiles() throws -> [(name: String, code: String)] {
        try SourceTree.appSources.map { s in
            (s.url.lastPathComponent, SourceTree.strippingComments(try String(contentsOf: s.url, encoding: .utf8)))
        }
    }

    @Test("SENSOR: no second folder-mode control anywhere in the app")
    func noSecondFolderControl() throws {
        let gone = ["FoldersOnlyShowToggle", "MachineEstimateFoldersToggle", "FootageFoldersShowToggle", "showFoldersOnly",
                    "CatalogFoldersOnlySetting", "CatalogFoldersOnlyRule", "CatalogFootageFoldersSetting",
                    "setFootageFoldersEstimated", "footageFolderViewChanged", "FoldersOnlyEmptyNote", "foldersOnly"]
        // The store names the retired keys once, to migrate them; nothing else may.
        for file in try appFiles() where file.name != "CatalogShowFilterStore.swift" {
            for word in gone { #expect(!file.code.contains(word), "\(file.name) still names \(word)") }
        }
        let toolbar = try code("CatalogToolbar.swift")
        #expect(!toolbar.contains("Show files — as folders"), "the three-row section is gone")
        #expect(toolbar.components(separatedBy: "showFilters.setFolders(").count == 2, "exactly one folder control")
    }

    @Test("SENSOR: the Folders switch sits beside Show disconnected media")
    func besideDisconnectedMedia() throws {
        let toolbar = try code("CatalogToolbar.swift")
        let disconnected = try #require(toolbar.range(of: "Label(\"Show disconnected media\""))
        let filters = try #require(toolbar.range(of: "Section(\"Show files — filters\")"))
        let folders = try #require(toolbar.range(of: "CatalogFoldersSwitch(showFilters: showFilters)"))
        #expect(disconnected.upperBound < folders.lowerBound && folders.upperBound < filters.lowerBound,
                "in the first section, after Show disconnected media, before the five ticks")
        #expect(toolbar.components(separatedBy: "CatalogFoldersSwitch(").count == 2, "drawn once")
    }

    @Test("SENSOR: only the store names the folder keys, and nothing else writes the switch")
    func onlyTheStoreOwnsTheSwitch() throws {
        let keys = ["\"catalog.footageFolders\"", "\"catalog.foldersOnly\"", "\"catalog.foldersByMachineEstimate\"",
                    "catalog.showFilters.foldersView"]
        for file in try appFiles() where file.name != "CatalogShowFilterStore.swift" {
            for key in keys { #expect(!file.code.contains(key), "\(file.name) names \(key)") }
            #expect(!file.code.contains("foldersOn ="), "\(file.name) assigns the switch itself")
        }
        let store = try code("CatalogShowFilterStore.swift")
        #expect(store.contains("@Published private(set) var foldersOn"))
    }

    @Test("SENSOR: the grey hold rides the held-row release, and the join reads the holds")
    func theHoldIsReleasedWithTheHeldRows() throws {
        let state = try code("CatalogTableState.swift")
        let release = try #require(state.range(of: "func releaseHeldRowsIfSelectionMoved() {"))
        #expect(state[release.upperBound...].prefix(500).contains("holdMachinePlacement(selected:"))
        let snapshot = try code("FootageFoldersSnapshot.swift")
        #expect(snapshot.contains("let held = footageFolders.machineHolds"))
        #expect(snapshot.contains("FootageFolders.oneViewEvents(rows: rows, own: own, eras: eras, held: held)"))
    }
}
