// CatalogMenuTests.swift
// The Catalog menu of Rick's 2026-11-01 ruling ("The Catalog menu is three
// groups and Catalog Status answers three questions"):
//
//   (a) LOGIC  — the item list and order as a pure value: three groups,
//                dividers between them, Tidy hidden at 0 and titled with
//                its total; every ellipsis item has a brief (what · never ·
//                how long) and its help is the brief's first line;
//   (b) SENSOR — the menu renders exactly that value; the retired items are
//                gone from the menu; every moved verb still calls its ONE
//                engine (rule 4) — the call targets are asserted; no new
//                `extension VideoScanModel` in the new files (rule 12);
//   (c) TRUTH  — Delete Selected Files…'s confirmation says the files move
//                to the Finder Trash and keeps the only-copy warning.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog menu — the item list and order (Rick 2026-11-01)")
struct CatalogMenuTests {

    @Test("three groups in order, Tidy hidden when there is nothing to tidy")
    func theListAndOrderWithNothingToTidy() {
        let entries = CatalogMenuLayout.entries(tidyTotal: 0)
        #expect(entries == [.catalogStatus, .validateCatalog, .updateCatalog,
                            .divider, .deleteSelectedFiles, .divider, .contentAnalysis])
        #expect(CatalogMenuLayout.titles(entries, statusTitle: "Catalog Status — Green…")
                == ["Catalog Status — Green…", "Validate Catalog…", "Update Catalog…",
                    "—", "Delete Selected Files…", "—", "Content Analysis…"])
    }

    @Test("Tidy Catalog… (N) sits fourth in the catalog group when N > 0")
    func tidyShowsItsTotal() {
        let entries = CatalogMenuLayout.entries(tidyTotal: 1_204)
        #expect(entries == [.catalogStatus, .validateCatalog, .updateCatalog, .tidyCatalog(total: 1_204),
                            .divider, .deleteSelectedFiles, .divider, .contentAnalysis])
        #expect(CatalogMenuLayout.titles(entries, statusTitle: "S")[3] == "Tidy Catalog… (\(1_204.formatted()))")
        #expect(!CatalogMenuLayout.entries(tidyTotal: -1).contains { if case .tidyCatalog = $0 { return true }; return false })
    }

    @Test("every ellipsis item has a brief — what it touches, what it never touches, how long — and its help is the first line")
    func everyEllipsisItemSaysWhatAndHowLong() {
        let entries = CatalogMenuLayout.entries(tidyTotal: 3)
        let titles = CatalogMenuLayout.titles(entries, statusTitle: "Catalog Status…")
        for (entry, title) in zip(entries, titles) where entry != .divider {
            #expect(title.contains("…"), "\(title): every Catalog item opens a sheet or window, so it carries an ellipsis")
            guard let brief = CatalogActionBrief.brief(for: entry) else {
                Issue.record("\(title) has no brief")
                continue
            }
            #expect(brief.lines.count == 3 && brief.lines.allSatisfy { !$0.isEmpty })
            #expect(brief.help == brief.lines[0], "the help repeats the first line")
            #expect(brief.neverTouches.hasPrefix("Never") || brief.neverTouches.hasPrefix("Changes nothing"))
        }
        #expect(CatalogActionBrief.brief(for: .divider) == nil)
        #expect(CatalogTimeClass.instant.words == "Instant.")
        #expect(CatalogTimeClass.minutes.words == "Minutes.")
        #expect(CatalogTimeClass.hoursResumable.words.hasPrefix("Hours — resumable"))
        #expect(CatalogActionBrief.contentAnalysis.time == .hoursResumable)
        #expect(CatalogActionBrief.validateCatalog.time == .minutes)
        #expect(CatalogActionBrief.deleteSelectedFiles.touches.contains("Finder Trash"))
    }

    @Test("TRUTH: the delete confirmation says the files move to the Finder Trash and keeps the only-copy warning")
    func deleteConfirmationSaysFinderTrash() {
        let a = VideoRecord(); a.fullPath = "/Volumes/X9/test_a.mov"; a.filename = "test_a.mov"
        let b = VideoRecord(); b.fullPath = "/Volumes/X9/test_b.mov"; b.filename = "test_b.mov"
        var plan = VideoScanModel.catalogTrashPlan(for: [a, b], isMasterArchive: { _ in false }, isOffline: { _ in false })
        plan.onlyCopy = [a.id]
        let c = CatalogTrashConfirmation(plan: plan, sizes: [a.id: 10, b.id: 10])
        #expect(c.detail.hasPrefix("They move to the Finder Trash; you can put them back until you empty it."))
        #expect(c.detail.contains("⚠︎ 1 of these is the only copy we know of."))
        #expect(!c.moveIsDefault, "the only copy keeps Move to Trash a deliberate click")
    }
}

@Suite("Catalog menu — sensors: the value is the menu, one engine per verb")
@MainActor
struct CatalogMenuSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    /// The `CommandMenu("Catalog") { … }` block of the App.
    static func catalogMenuBlock() throws -> String {
        let app = try code("VideoScanApp.swift")
        let start = try #require(app.range(of: "CommandMenu(\"Catalog\")")).lowerBound
        let tail = app[start...]
        let end = try #require(tail.range(of: "Window(\"About VideoScan\"")).lowerBound
        return String(tail[..<end])
    }

    @Test("SENSOR: the Catalog menu renders CatalogMenuContent and nothing else; the retired items are gone from it")
    func theMenuIsTheValue() throws {
        let block = try Self.catalogMenuBlock()
        #expect(block.contains("CatalogMenuContent(model: catalogModel, store: catalogMenu,"))
        #expect(block.components(separatedBy: "Button(").count == 1, "no hand-written item beside the value")
        for retired in ["Purge Non-Video Media", "Refresh Embedded Dates", "FullHashBackfillMenuItem(",
                        "AudioFingerprintBackfillMenuItem(", "duplicateDigestSplitTitle", "CatalogReopenMenuItems(",
                        "CatalogDatabaseInfoMenuItem(", "ValidateCatalogMenuItem(", "CatalogTrashMenuItem("] {
            #expect(!block.contains(retired), "the Catalog menu still names \(retired)")
        }
        let content = try Self.code("CatalogMenu.swift")
        #expect(content.contains("ForEach(Array(CatalogMenuLayout.entries(tidyTotal: tidyTotal).enumerated())"),
                "the menu renders the layout value")
    }

    @Test("SENSOR: each moved verb calls the SAME engine the retired item called (rule 4)")
    func oneEnginePerVerb() throws {
        let content = try Self.code("CatalogMenu.swift")
        #expect(content.contains("_ = center.startedByUser { $0.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker) }"))
        #expect(content.contains("Button(CatalogMenuLayout.updateTitle) { model.openUpdateCatalog() }"))
        #expect(content.contains("case .deleteSelectedFiles:") && content.contains("CatalogTrashMenuItem()"))
        #expect(content.contains("AnalyzeWindowOpener.open(using: openWindow, source: \"catalog-menu\")"))
        #expect(!content.contains("ValidateCatalogJob(") && !content.contains("deleteConfirmedJunk(") && !content.contains("FileManager"),
                "no engine of its own")
        let validate = try Self.code("ValidateCatalogMenuItem.swift")
        #expect(validate.contains("Button(\"Validate Catalog…\")"))
        #expect(validate.contains("CatalogMenuActions.startValidate(model: model, center: center)"), "the sheet's Start is the one engine")
        #expect(!validate.contains("ValidateCatalogJob("))
        let trash = try Self.code("CatalogTrashCommand.swift")
        #expect(trash.contains("Button(CatalogMenuLayout.deleteTitle)"))
        #expect(trash.contains("selection?.perform()"), "the same handler the table's ⌘⌫ calls")
        #expect(trash.contains(".keyboardShortcut(.delete, modifiers: .command)"))
    }

    @Test("SENSOR: every Catalog item's help is its brief's first line")
    func helpIsTheBrief() throws {
        let content = try Self.code("CatalogMenu.swift")
        #expect(content.contains(".help(CatalogActionBrief.updateCatalog.help)"))
        #expect(content.contains(".help(CatalogActionBrief.tidyCatalog.help)"))
        #expect(content.contains(".help(CatalogActionBrief.contentAnalysis.help)"))
        #expect(try Self.code("ValidateCatalogMenuItem.swift").contains(".help(CatalogActionBrief.validateCatalog.help)"))
        #expect(try Self.code("CatalogTrashCommand.swift").contains(".help(CatalogActionBrief.deleteSelectedFiles.help)"))
        #expect(try Self.code("CatalogStatusMenuItem.swift").contains(".help(CatalogActionBrief.catalogStatus.help)"))
        #expect(try Self.code("UpdateCatalogSheet.swift").contains("CatalogActionBriefHeader(brief: .updateCatalog)"))
        #expect(try Self.code("ValidateCatalogMenuItem.swift").contains("CatalogActionBriefHeader(brief: .validateCatalog)"))
        #expect(try Self.code("AnalyzePanelView.swift").contains("CatalogActionBriefHeader(brief: .contentAnalysis)"))
    }

    @Test("SENSOR: the new Catalog menu files add no `extension VideoScanModel` (rule 12)")
    func noNewModelExtension() throws {
        for file in ["CatalogMenu.swift", "ValidateCatalogMenuItem.swift", "CatalogTrashCommand.swift"] {
            #expect(!(try Self.code(file)).contains("extension VideoScanModel"), "\(file) extends the model")
        }
    }
}
