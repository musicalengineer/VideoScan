//
//  CombineBulkWorkflowUITests.swift
//  VideoScanUITests
//
//  Second end-to-end UI test for VideoScan. Drives the bulk-combine path
//  the way Rick does for a real catalog cleanup: open the bulk Combine
//  sheet, "Select All Online", pick Re-encode → ProRes, click Combine,
//  and wait for ffmpeg to produce real .mov files in a /tmp output dir.
//
//  Scoped to 20 pairs via the `VS_COMBINE_LIMIT_N` launch env var so the
//  run is bounded and deterministic — without it the test would happily
//  combine every paired MXF in the catalog.
//
//  Reads the real catalog from ~/Library/Application Support/VideoScan/.
//  Output dir is created under /tmp and removed in tearDown, so disk
//  state is throwaway. SKIPPED in CI (xctestplan); intended for manual
//  on-Mac-Studio runs.
//

import XCTest

final class CombineBulkWorkflowUITests: XCTestCase {

    /// Output dir for the combined files. Cleaned up in tearDown unless
    /// VS_UI_TEST_KEEP_OUTPUT=1 is set in the runner environment.
    private var outputDir: URL!

    /// How many pairs the bulk run is capped to. Kept low so a full sweep
    /// completes in a few minutes even on a busy machine. The test verifies
    /// at least `expectedOutputs` .mov files appear in `outputDir`.
    private let pairCap = 20

    /// We don't insist on the exact pair count — some of the first 20
    /// correlated pairs may turn out blocked (offline media after
    /// substitution check) and get filtered. 12 of 20 succeeding is a
    /// healthy threshold for "the bulk path actually muxed real files."
    private let minExpectedOutputs = 12

    override func setUpWithError() throws {
        continueAfterFailure = false

        let uuid = UUID().uuidString.prefix(8)
        outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-uitest-bulk-\(uuid)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        print("[BULK-UI-TEST] Output dir: \(outputDir.path)")
    }

    override func tearDownWithError() throws {
        guard let outputDir else { return }
        if ProcessInfo.processInfo.environment["VS_UI_TEST_KEEP_OUTPUT"] != "1" {
            try? FileManager.default.removeItem(at: outputDir)
            print("[BULK-UI-TEST] Removed output dir: \(outputDir.path)")
        } else {
            print("[BULK-UI-TEST] Keeping output dir (VS_UI_TEST_KEEP_OUTPUT=1): \(outputDir.path)")
        }
    }

    @MainActor
    func testBulkCombineFromToolbar() throws {
        let app = launchApp()

        // 1. Catalog tab.
        let catalogTab = app.buttons["tab.Catalog"]
        XCTAssertTrue(
            catalogTab.waitForExistence(timeout: 90),
            "Main window with tab strip never appeared. App may have crashed on launch — check ~/Library/Logs/VideoScan/videoscan.log."
        )
        catalogTab.click()

        // 2. Open the Correlate menu and trigger Find A/V Pairs.
        let correlateMenu = app.menuButtons["catalog.correlate.menu"]
        XCTAssertTrue(
            correlateMenu.waitForExistence(timeout: 120),
            "Correlate menu never appeared. Catalog records may not have loaded."
        )
        correlateMenu.click()

        let findPairsPredicate = NSPredicate(format: "title == %@",
                                             "Find A/V Pairs Across Volumes")
        let findPairsItem = app.menuItems.matching(findPairsPredicate).firstMatch
        XCTAssertTrue(findPairsItem.waitForExistence(timeout: 10),
                      "Find A/V Pairs Across Volumes menu item never appeared.")
        findPairsItem.click()

        // 3. Wait for correlation to finish.
        let correlationDeadline = Date().addingTimeInterval(240)
        while Date() < correlationDeadline {
            if correlateMenu.isHittable { break }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(correlateMenu.isHittable,
                      "Correlation never finished within 240s.")

        // 4. Open the bulk Combine sheet via the toolbar.
        let openCombine = app.buttons["catalog.combine.openSheet"]
        XCTAssertTrue(openCombine.waitForExistence(timeout: 30),
                      "Catalog Combine toolbar button not found.")
        XCTAssertTrue(openCombine.isEnabled,
                      "Combine toolbar button is disabled — no correlated pairs?")
        openCombine.click()

        // 5. Inside the sheet: Select All Online, pick Re-encode → ProRes, Combine.
        let selectAll = app.buttons["combineSheet.selectAllOnline"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 15),
                      "Combine sheet 'Select All Online' button not found.")
        selectAll.click()

        // ProRes radio. Picker rendered as radioGroup; the radio button's
        // accessibility label matches the option text.
        let proResRadio = app.radioButtons.matching(
            NSPredicate(format: "label CONTAINS 'ProRes'")
        ).firstMatch
        XCTAssertTrue(proResRadio.waitForExistence(timeout: 5),
                      "Re-encode → ProRes radio button not found in sheet.")
        proResRadio.click()

        let combineButton = app.buttons["combineSheet.combineButton"]
        XCTAssertTrue(combineButton.waitForExistence(timeout: 10),
                      "Combine button not found in sheet.")
        XCTAssertTrue(combineButton.isEnabled,
                      "Combine button disabled — outputFolder launch arg may not have taken effect, or no pairs are selected.")
        combineButton.click()

        // 6. Wait for ffmpeg to produce at least minExpectedOutputs .mov files.
        //    Per-pair time on M4 Max with HW ProRes encoder + RAM-warm cache is
        //    ~10-30s; a cold HDD source pair can take much longer. Budget
        //    generously: 20 min total for 20 pairs.
        let count = try waitForOutputCount(in: outputDir, minimum: minExpectedOutputs, timeout: 1200)
        print("[BULK-UI-TEST] Produced \(count) combined files in \(outputDir.path)")

        // Spot-check the first output: > 100 KB and a valid extension.
        let combined = try FileManager.default
            .contentsOfDirectory(atPath: outputDir.path)
            .filter { $0.hasSuffix(".mov") }
            .sorted()
        let firstPath = outputDir.appendingPathComponent(combined.first!).path
        let attrs = try FileManager.default.attributesOfItem(atPath: firstPath)
        let size = (attrs[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 100_000,
                             "First combined file \(combined.first!) is only \(size) bytes.")
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-combineOutputFolder", outputDir.path,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        // Env: cap the bulk run + flag test mode.
        app.launchEnvironment = [
            "VS_UI_TEST": "1",
            "VS_COMBINE_LIMIT_N": String(pairCap)
        ]
        app.launch()
        return app
    }

    /// Polls `dir` until at least `minimum` .mov files exist, or timeout.
    /// Returns the final count.
    private func waitForOutputCount(in dir: URL, minimum: Int, timeout: TimeInterval) throws -> Int {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        while Date() < deadline {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let movs = names.filter { $0.hasSuffix(".mov") }
            if movs.count != lastCount {
                lastCount = movs.count
                print("[BULK-UI-TEST] \(lastCount) .mov files so far")
            }
            if movs.count >= minimum {
                return movs.count
            }
            Thread.sleep(forTimeInterval: 5.0)
        }
        XCTFail("Only \(lastCount) .mov files produced after \(Int(timeout))s; expected at least \(minimum).")
        return lastCount
    }
}
