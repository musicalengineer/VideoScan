// CatalogOpenShortcutTests.swift
// ⌘O in the Catalog opens the highlighted rows the way a double-click
// does, through ONE function (Rick, 2026-09-26). Three dimensions:
//
//   (a) LOGIC     — `CatalogOpenAction.open` hands exactly the selected
//                   rows to the launcher, in table order, after the
//                   looks-moved check ran once per row; the console line
//                   names the player each file was routed to.
//   (b) ISOLATION — no selection / a stale selection: nothing launched,
//                   nothing noted, a console line says why. The menu title
//                   and disabled rule follow the count alone.
//   (c) SENSOR    — the source: the table's primaryAction and the menu's
//                   `perform` both end in `openRows` → `CatalogOpenAction.
//                   open`; the table no longer calls MediaOpener.open on
//                   its own; the command file owns no launch code; ⇧⌘O
//                   (Analyze Dashboard) is untouched.
//
// The launcher is never the real MediaOpener.open here — that would hand
// a player a file — so (a) and (b) use the closure overload. The one test
// that runs the real `noteMissingFileForUserAction` does so with a spy
// launcher and a path that cannot exist.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog ⌘O — Open through the one path", .serialized)
@MainActor
struct CatalogOpenShortcutTests {

    private func record(_ path: String, video: String = "h264", audio: String = "aac") -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        // The scanner stores the UPPERCASED extension; MediaOpener lowercases.
        r.ext = (path as NSString).pathExtension.uppercased()
        r.videoCodec = video
        r.audioCodec = audio
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    /// Everything the seam overload can touch, recorded.
    @MainActor
    private final class Spy {
        var lines: [String] = []
        var noted: [UUID] = []
        var launches: [[VideoRecord]] = []
        var missing: Set<UUID> = []

        func open(ids: Set<UUID>, rows: [VideoRecord], gesture: String, hasVLC: Bool = true) -> [VideoRecord] {
            CatalogOpenAction.open(
                ids: ids, rows: rows, gesture: gesture, hasVLC: hasVLC,
                log: { self.lines.append($0) },
                noteMissing: { self.noted.append($0.id); return self.missing.contains($0.id) },
                launch: { self.launches.append($0) })
        }
    }

    // MARK: (a) Logic

    @Test("logic: exactly the selected rows, in table order, one looks-moved check each, one launch")
    func opensExactlyTheSelection() {
        let a = record("/Volumes/X9/test_a.mov")
        let b = record("/Volumes/X9/test_b.mxf", video: "dvvideo", audio: "pcm_s16le")
        let c = record("/Volumes/X9/test_c.mp4")
        let d = record("/Volumes/X9/test_d.mov", audio: "ac3")
        let rows = [a, b, c, d]
        let spy = Spy()

        let opened = spy.open(ids: [d.id, a.id, c.id], rows: rows, gesture: "⌘O")

        #expect(opened.map(\.id) == [a.id, c.id, d.id], "table order, not selection-set order")
        #expect(spy.launches.count == 1, "one launch for the whole selection — MediaOpener batches by player")
        #expect(spy.launches.first?.map(\.id) == [a.id, c.id, d.id])
        #expect(spy.noted == [a.id, c.id, d.id], "the looks-moved check ran once per opened row, none for b")
        #expect(spy.lines == ["Open (⌘O): 3 file(s) — by codec: 2 for QuickTime Player, 1 for VLC (offline files are skipped by the opener)"], "\(spy.lines)")
    }

    @Test("logic: a file missing on a mounted volume is still opened with the rest, and the line says so")
    func missingFileIsCountedNotBlocking() {
        let a = record("/Volumes/X9/test_a.mov")
        let gone = record("/Volumes/X9/test_gone.mov")
        let spy = Spy()
        spy.missing = [gone.id]

        let opened = spy.open(ids: [a.id, gone.id], rows: [a, gone], gesture: "double-click")

        #expect(opened.map(\.id) == [a.id, gone.id], "never blocks the open of the files that ARE there")
        #expect(spy.launches.first?.map(\.id) == [a.id, gone.id])
        #expect(spy.lines == ["Open (double-click): 2 file(s) — by codec: 2 for QuickTime Player (offline files are skipped by the opener); 1 missing on a mounted volume (see the Update Catalog banner)"], "\(spy.lines)")
    }

    @Test("logic: the real noteMissingFileForUserAction raises the looks-moved banner for a missing file on a mounted volume")
    func realLooksMovedCheckRuns() throws {
        let model = VideoScanModel()
        // A path under the boot volume (mounted, reachable) that cannot
        // exist — the exact "someone moved it in Finder" signature.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cmdo_\(UUID().uuidString)", isDirectory: true)
        let rec = record(dir.appendingPathComponent("test_moved.mov").path)
        #expect(!FileManager.default.fileExists(atPath: rec.fullPath))
        #expect(model.looksMovedNotice == nil)

        var launched: [VideoRecord] = []
        var lines: [String] = []
        let opened = CatalogOpenAction.open(
            ids: [rec.id], rows: [rec], gesture: "⌘O", hasVLC: true,
            log: { lines.append($0) },
            noteMissing: { model.noteMissingFileForUserAction($0) },
            launch: { launched = $0 })

        #expect(opened.map(\.id) == [rec.id])
        #expect(launched.map(\.id) == [rec.id], "the launcher still gets the row — MediaOpener decides reachability")
        #expect(model.looksMovedNotice?.filename == "test_moved.mov", "the Update Catalog banner is armed")
        #expect(lines.first?.hasSuffix("1 missing on a mounted volume (see the Update Catalog banner)") == true, "\(lines)")
    }

    @Test("logic: the player summary is MediaOpener's decision, counted", arguments: [
        (true,  "2 for QuickTime Player, 1 for VLC"),
        (false, "2 for QuickTime Player, 1 for the default app"),
    ])
    func playerSummaryCountsTheDecision(hasVLC: Bool, expected: String) {
        let qt1 = record("/Volumes/X9/test_1.mov")
        let qt2 = record("/Volumes/X9/test_2.mp4", video: "hevc", audio: "alac")
        let mxf = record("/Volumes/X9/test_3.mxf", video: "dvvideo", audio: "pcm_s16le")
        #expect(CatalogOpenAction.playerSummary([qt1, mxf, qt2], hasVLC: hasVLC) == expected)
        #expect(CatalogOpenAction.playerSummary([], hasVLC: hasVLC).isEmpty)
    }

    // MARK: (b) Isolation

    @Test("isolation: no selection launches nothing, notes nothing, and says so")
    func emptySelectionIsANoOp() {
        let a = record("/Volumes/X9/test_a.mov")
        let spy = Spy()
        let opened = spy.open(ids: [], rows: [a], gesture: "⌘O")
        #expect(opened.isEmpty)
        #expect(spy.launches.isEmpty)
        #expect(spy.noted.isEmpty)
        #expect(spy.lines == ["Open (⌘O): nothing is selected — click a row first."])
    }

    @Test("isolation: a selection that no longer matches any row launches nothing")
    func staleSelectionIsANoOp() {
        let a = record("/Volumes/X9/test_a.mov")
        let spy = Spy()
        let opened = spy.open(ids: [UUID(), UUID()], rows: [a], gesture: "⌘O")
        #expect(opened.isEmpty)
        #expect(spy.launches.isEmpty)
        #expect(spy.noted.isEmpty)
        #expect(spy.lines == ["Open (⌘O): the 2 selected row(s) are no longer in the table — nothing to do."])
    }

    @Test("isolation: the menu title follows the count alone; the item is disabled at zero")
    func menuTitleAndDisabledRule() throws {
        #expect(CatalogOpenMenuItem.title(count: 0) == "Open")
        #expect(CatalogOpenMenuItem.title(count: 1) == "Open")
        #expect(CatalogOpenMenuItem.title(count: 3) == "Open 3 Files")
        let command = try productionSource("CatalogOpenCommand.swift")
        #expect(command.contains(".disabled((selection?.count ?? 0) == 0)"), "no focused catalog selection → disabled")
        #expect(command.contains("static func title(count: Int) -> String"), "the title is the pure rule the test above pins")
    }

    // MARK: (c) Source sensor — one open path

    private func productionSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test("sensor: double-click and ⌘O resolve to the same openRows → CatalogOpenAction.open; the table launches nothing on its own")
    func bothGesturesShareOneFunction() throws {
        let table = try productionSource("CatalogContent+Table.swift")

        // Double-click / Return: the primaryAction body is a call into
        // openRows, nothing else.
        let primaryRange = try #require(table.range(of: "} primaryAction: { ids in"))
        let primaryBody = String(table[primaryRange.upperBound...].prefix(400))
        #expect(primaryBody.contains("openRows(ids: ids, gesture: \"double-click\")"), "double-click → openRows")
        #expect(!primaryBody.contains("MediaOpener"), "no launch of its own in primaryAction")
        #expect(!primaryBody.contains("noteMissingFileForUserAction"), "no looks-moved loop of its own in primaryAction")

        // ⌘O: the table publishes a FOCUSED value (never scene-scoped, or
        // a search field's ⌘O would open rows) whose perform is openSelectedRows.
        #expect(table.contains("focusedValue(\\.catalogOpenSelection"), "the table publishes its selection to the menu while focused")
        #expect(!table.contains("focusedSceneValue(\\.catalogOpenSelection"), "focus-scoped, never scene-scoped")
        #expect(table.contains("perform: openSelectedRows"), "the menu ends in the table's handler")
        let selectedRange = try #require(table.range(of: "private func openSelectedRows()"))
        let selectedBody = String(table[selectedRange.upperBound...].prefix(200))
        #expect(selectedBody.contains("openRows(ids: selectedIDs, gesture: \"\\u{2318}O\")"), "⌘O → the same openRows")

        // The single function: exactly one CatalogOpenAction.open call in
        // the table file, inside openRows, over tableData (one O(n) pass).
        #expect(occurrences(of: "CatalogOpenAction.open(", in: table) == 1, "one call site — both gestures share it")
        let rowsRange = try #require(table.range(of: "private func openRows(ids: Set<UUID>, gesture: String)"))
        let rowsBody = String(table[rowsRange.upperBound...].prefix(200))
        #expect(rowsBody.contains("CatalogOpenAction.open(ids: ids, rows: tableData, gesture: gesture, model: model)"))
        #expect(occurrences(of: "MediaOpener.open(", in: table) == 0, "the table no longer calls the smart launcher directly")

        // The command file: the key equivalent, the focused value, and ONE
        // launch (the MediaOpener hand-off) — no NSWorkspace of its own.
        let command = try productionSource("CatalogOpenCommand.swift")
        #expect(command.contains(".keyboardShortcut(\"o\", modifiers: .command)"), "⌘O as the key equivalent")
        #expect(command.contains("@FocusedValue(\\.catalogOpenSelection)"))
        #expect(occurrences(of: "MediaOpener.open(", in: command) == 1, "the smart chooser is the only launcher")
        #expect(occurrences(of: "noteMissingFileForUserAction(", in: command) == 1, "the model's looks-moved check, once")
        #expect(!command.contains("NSWorkspace"), "no launch code of its own")
        #expect(!command.contains("FileManager"), "no file access of its own")

        // The app: the item is in the File menu; ⇧⌘O (Analyze Dashboard)
        // is still there and the app declares no second plain ⌘O.
        let app = try productionSource("VideoScanApp.swift")
        #expect(app.contains("CatalogOpenMenuItem()"), "the item is in the File menu")
        #expect(app.contains(".keyboardShortcut(\"o\", modifiers: [.command, .shift])"), "⇧⌘O Analyze Dashboard untouched")
        #expect(!app.contains(".keyboardShortcut(\"o\", modifiers: .command)"), "plain ⌘O belongs to the catalog item only")
    }
}
