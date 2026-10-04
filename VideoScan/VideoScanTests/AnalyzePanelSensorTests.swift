// AnalyzePanelSensorTests.swift
// Source-level sensors for the Analyze redesign's Phase A trial UI
// (2026-10-02): the panel, the Catalog Analyze menu and the Storage
// Reclaimable card.
//
// What they pin:
//   * NO O(records) work in any of the three view bodies — the views read
//     the model's cached AnalyzeCoverageSnapshot / the pane's cached
//     ReclaimableEstimate, never `model.records` (the 2026-07-02 storm
//     rule, VolumeDashboard pattern).
//   * The Analyze menu has exactly ONE `Menu` constructor — a nested
//     submenu closes on every window update (Rick 2026-09-22, measured),
//     so "Analyze Selected ▸" is flattened.
//   * The toolbar builds the Analyze menu and no longer the Duplicates
//     menu; Delete Duplicates is not offered from the toolbar.
//   * ⇧⌘O is declared ONCE (the Window menu) and opens the Analyze panel;
//     the legacy dashboard keeps its own, shortcut-less item; both Window
//     scenes exist.
//   * Every Run now goes through AnalyzeRunner, which writes a START line
//     through the existing sinks (model.log + appLog) — no new log file.
//   * New controls carry `analyze.` / `storage.reclaimable.` identifiers.
//
// Deliberately NON-INTERACTIVE (no windows, no events) — see
// CatalogDuplicatesMenuTests.swift for why.

import Foundation
import Testing
@testable import VideoScan

@Suite("Analyze Phase A — source sensors")
struct AnalyzePanelSensorTests {

    private func source(_ file: String) throws -> String {
        try SourceTree.appSource(named: file)
    }

    /// Code only — comment lines stripped so headers that EXPLAIN the
    /// rule don't trip the check.
    private func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The forbidden shapes: a records walk in a view file.
    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records",
                                "for rec in records", "records.reduce", "records.first", "records.count"]

    @Test func panelBodyDoesNoRecordsWork() throws {
        let src = code(try source("AnalyzePanelView.swift"))
        for walk in recordsWalks {
            #expect(!src.contains(walk), "AnalyzePanelView walks records: `\(walk)`")
        }
        #expect(src.contains("@ObservedObject private var coverage: AnalyzeCoverageSnapshot"),
                "the panel reads the model's cached coverage snapshot")
        #expect(src.contains("@ObservedObject private var dossier: DossierDashboardSnapshot"),
                "the panel observes the ≤2 Hz dossier snapshot, not the orchestrator")
        #expect(!src.contains("@EnvironmentObject"), "the panel must not observe the model wholesale")
        #expect(!src.contains("@ObservedObject var model"), "the panel must not observe the model wholesale")
    }

    @Test func menuBodyDoesNoRecordsWorkAndHasNoNestedSubmenu() throws {
        let src = code(try source("CatalogAnalyzeMenu.swift"))
        for walk in recordsWalks {
            #expect(!src.contains(walk), "CatalogAnalyzeMenu walks records: `\(walk)`")
        }
        let menus = occurrences(of: "Menu {", in: src) + occurrences(of: "Menu(", in: src)
        #expect(menus == 1, "CatalogAnalyzeMenu has \(menus) Menu constructors — a nested submenu closes on every window update")
        #expect(!src.contains(".keyboardShortcut("), "⇧⌘O belongs to the Window menu item only")
        #expect(src.contains("accessibilityIdentifier(\"catalog.analyze.menu\")"))
        #expect(!src.contains("Delete Duplicates"), "Delete moved to the Storage tab")
        #expect(!src.contains("WorkingCopyCleanupText"), "the working-copies toggle moved to the Storage tab")
    }

    @Test func storageCardDoesNoRecordsWorkOutsideClickTime() throws {
        let src = code(try source("StorageReclaimableCard.swift"))
        // The ONE allowed records pass is the click-time forecast helper
        // (`prepareConfirmation`) — the same one CatalogView had — which
        // calls model methods; the view itself never touches `model.records`.
        for walk in recordsWalks {
            #expect(!src.contains(walk), "StorageReclaimableCard walks records: `\(walk)`")
        }
        #expect(src.contains("let estimate: ReclaimableEstimate?"), "numbers come from the pane's cached estimate")
        #expect(src.contains("ReclaimableEstimate.survivalRule"), "the rule is quoted from the tier decision")
        #expect(src.contains("accessibilityIdentifier(\"storage.reclaimable.delete\")"))
        #expect(src.contains("accessibilityIdentifier(\"storage.reclaimable.update\")"))
        // 2026-10-03: the picker → forecast → job front door moved, text
        // for text, into the shared DeleteDuplicatesFlow modifier (the
        // Triage tab's steward pane opens the same door). The card asks it
        // to open with this drive preselected; the flow starts the job.
        #expect(src.contains(".deleteDuplicatesFlow(picker: $picker, preselectedPath: deletableHere?.path, source: \"Storage tab\")"),
                "the Storage button opens the shared Delete front door, this drive preselected")
        let flow = code(try source("DeleteDuplicatesFlow.swift"))
        for walk in recordsWalks {
            #expect(!flow.contains(walk), "DeleteDuplicatesFlow walks records: `\(walk)`")
        }
        #expect(flow.contains("startDeleteDuplicates(onVolume: confirmVolume, model: model)"),
                "the front door runs TODAY's DeleteDuplicatesJob, unchanged")
        #expect(flow.contains("preselectedPath: preselectedPath"), "the host's drive is preselected in the picker")
        #expect(!flow.contains("DeleteDuplicatesJob("), "the front door never builds a job itself")
    }

    @Test func detailPaneComputesTheEstimateOffMain() throws {
        let src = code(try source("VolumeDetailPane.swift"))
        #expect(src.contains("ReclaimableCalculator.project(model.records, leftAlone: { hold($0) != nil })"),
                "projection on the main actor, once — minus the copies the Delete run leaves alone (GH #258)")
        #expect(src.contains("let hold = model.duplicateDeletionHoldRule()"), "…by the Delete planner's own rule, built once")
        #expect(src.contains("ReclaimableCalculator.compute("), "aggregation in the detached task")
        #expect(src.contains("StorageReclaimableCard(volumePath: target.searchPath"))
        // The projection must be inside recompute(), not in `body`.
        let bodyRange = try #require(src.range(of: "var body: some View {"))
        let recomputeRange = try #require(src.range(of: "private func recompute()"))
        let body = String(src[bodyRange.upperBound..<recomputeRange.lowerBound])
        #expect(!body.contains("model.records"), "no records walk in the pane's body")
    }

    @Test func toolbarBuildsTheAnalyzeMenuAndNoLongerTheDuplicatesMenu() throws {
        let src = code(try source("CatalogToolbar.swift"))
        #expect(src.contains("CatalogAnalyzeMenu("))
        #expect(!src.contains("CatalogDuplicatesMenu("), "the old Duplicates menu is retired from the toolbar")
        #expect(!src.contains("Label(\"Correlate A/V Pairs\""), "the old Correlate menu is retired from the toolbar")
        #expect(!src.contains("onChooseVolumeToDeleteDuplicates"), "Delete is not offered from the toolbar")
        #expect(src.contains("onUpdateNow: onUpdateNow"))
        #expect(!src.contains(".disabled(isScanning || isCorrelating || !hasRecords)"),
                "the knowledge menu is never disabled as a whole")
    }

    @Test func contentViewRoutesUpdateNowThroughTheRunner() throws {
        let src = code(try source("ContentView.swift"))
        #expect(src.contains("AnalyzeRunner(model: model, orchestrator: captionOrchestrator, center: fileOpsCenterReference)"))
        #expect(src.contains(".runNow(cycler, source: \"catalog menu\")"))
        #expect(src.contains("AnalyzeWindowOpener.open(using: openWindow, source: \"analyze-menu\")"))
    }

    @Test func runnerWritesStartLinesThroughTheExistingSinks() throws {
        let src = code(try source("AnalyzeRunner.swift"))
        #expect(src.contains("model.log(line)"))
        #expect(src.contains("appLog.write(line)"))
        #expect(!src.contains("FileHandle"), "no log file of its own")
        #expect(!src.contains("LogSink("), "no new sink")
        // Every cycler has a Run now arm (the three dossier stages share one
        // `case .sceneCaptions, .ocr, .transcribe:` line).
        let runNowRange = try #require(src.range(of: "func runNow("))
        let runNowBody = String(src[runNowRange.upperBound...].prefix(4_000))
        for c in AnalyzeCycler.allCases {
            #expect(runNowBody.contains(".\(c.rawValue)"), "no Run now arm for \(c.rawValue)")
        }
        // The entry points are the existing ones.
        for entry in ["analyzeDuplicates(selectedIDs:", "startFindSimilarFootage(scope:", "enqueueAnalyze(volumePrefix:",
                      "enqueueAnalyzeAll(volumePrefixes:", "model.correlate()", "correlateAcrossVolumes()",
                      "clearAndRecorrelateAll()", "runContentHashBackfill(pathPrefix:", "runEmbeddedDateBackfill(pathPrefix:",
                      "catchUpInferredDates(trigger:"] {
            #expect(src.contains(entry), "runner no longer calls \(entry)")
        }
    }

    @Test func appDeclaresBothWindowsAndOneShiftCommandO() throws {
        let app = code(try source("VideoScanApp.swift"))
        #expect(app.contains("Window(AnalyzeWindowOpener.windowTitle, id: AnalyzeWindowOpener.sceneID)"))
        #expect(app.contains("Window(DossierWindowOpener.windowTitle, id: DossierWindowOpener.sceneID)"),
                "the legacy dashboard window still exists")
        #expect(app.contains("DossierDashboardView(model: catalogModel,"), "legacy content unchanged")
        #expect(occurrences(of: ".keyboardShortcut(\"o\", modifiers: [.command, .shift])", in: app) == 1,
                "⇧⌘O declared exactly once")
        #expect(app.contains("Button(\"Analyze Dashboard (legacy)\")"))
        #expect(AnalyzeWindowOpener.sceneID != DossierWindowOpener.sceneID)
        #expect(AnalyzeWindowOpener.windowTitle != DossierWindowOpener.windowTitle)
        #expect(DossierWindowOpener.windowTitle == "Analyze Dashboard (legacy)")
    }

    @Test func chipOpensThePanel() throws {
        let chip = code(try source("DossierToolbarChip.swift"))
        #expect(chip.contains("AnalyzeWindowOpener.open(using: openWindow, source: \"chip\")"))
        #expect(!chip.contains("DossierWindowOpener.open("))
    }

    @Test func newControlsCarryIdentifiers() throws {
        let panel = code(try source("AnalyzePanelView.swift"))
        for id in ["analyze.panel", "analyze.row.\\(cycler.rawValue).runNow", "analyze.row.\\(cycler.rawValue).pause",
                   "analyze.row.\\(cycler.rawValue).schedule", "analyze.row.\\(cycler.rawValue).state",
                   "analyze.scope.includeAudio", "analyze.resumeOnLaunch", "analyze.correlate.clearAndRecorrelate"] {
            #expect(panel.contains("accessibilityIdentifier(\"\(id)\")"), "missing identifier \(id)")
        }
        let card = code(try source("StorageReclaimableCard.swift"))
        for id in ["storage.reclaimable", "storage.reclaimable.headline", "storage.reclaimable.knowledge",
                   "storage.reclaimable.workingCopies", "storage.reclaimable.rule"] {
            #expect(card.contains("accessibilityIdentifier(\"\(id)\")"), "missing identifier \(id)")
        }
    }

    @Test func legacyDuplicatesMenuFileIsRetiredButKeepsItsTypes() throws {
        let legacy = try source("CatalogDuplicatesMenu.swift")
        #expect(legacy.contains("RETIRED FROM THE TOOLBAR 2026-10-02"))
        #expect(legacy.contains("struct Volume: Equatable, Identifiable"), "the picker and the Storage card still use Volume")
    }
}
