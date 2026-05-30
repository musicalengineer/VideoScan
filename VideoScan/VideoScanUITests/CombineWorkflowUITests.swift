//
//  CombineWorkflowUITests.swift
//  VideoScanUITests
//
//  First end-to-end UI test for VideoScan. Drives the real app like Rick
//  would: launches it, switches to the Catalog tab, runs "Find A/V Pairs
//  Across Volumes", right-clicks a paired MXF row, and exercises the
//  per-pair Combine sheet through to ffmpeg producing an output file.
//
//  This test reads Rick's real catalog from
//  ~/Library/Application Support/VideoScan/ — it does NOT mock anything.
//  Output lands in /tmp/vs-uitest-output-<UUID>/ when the invoking shell
//  pre-creates that directory and exports TEST_RUNNER_VS_UI_TEST_OUTPUT_DIR
//  (xcodebuild auto-forwards TEST_RUNNER_* env vars into the sandboxed
//  runner). Without that var the test falls back to NSTemporaryDirectory()
//  — same effect, different path.
//
//  Performance note: with 12,010 catalog records the SwiftUI Table inflates
//  the accessibility tree enormously. Every XCUIElement query takes ~30s
//  on the M4 Max. We minimize queries by:
//    * matching on typed accessors (app.buttons[id], not descendants(.any))
//    * caching elements in locals and reusing
//    * waiting on the simplest possible predicate per step
//

import XCTest

final class CombineWorkflowUITests: XCTestCase {

    /// Output dir for the combined file. See setUpWithError() for path policy.
    private var outputDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let env = ProcessInfo.processInfo.environment
        let envDir = env["VS_UI_TEST_OUTPUT_DIR"]
            ?? env["TEST_RUNNER_VS_UI_TEST_OUTPUT_DIR"]
        if let envDir, !envDir.isEmpty {
            outputDir = URL(fileURLWithPath: envDir)
        } else {
            let uuid = UUID().uuidString.prefix(8)
            outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vs-uitest-output-\(uuid)")
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }
        print("[UI-TEST] Output dir: \(outputDir.path)")
    }

    // MARK: - The one test

    /// End-to-end: launch app → Catalog tab → Correlate menu → Find A/V
    /// Pairs Across Volumes → search "00000" (Avid MXF) → right-click first
    /// paired row → Combine This Pair… → Combine → wait for output file.
    @MainActor
    func testCombinePairFromRightClick() throws {
        let app = launchApp()

        // 1. Catalog tab. Tag 1 in ContentView's tabs list; identifier is
        //    "tab.Catalog" (string interp of tab.label).
        let catalogTab = app.buttons["tab.Catalog"]
        XCTAssertTrue(
            catalogTab.waitForExistence(timeout: 90),
            "Main window with tab strip never appeared. App may have crashed on launch — check ~/Library/Logs/VideoScan/videoscan.log."
        )
        catalogTab.click()

        // 2. Open the Correlate menu. Rendered by SwiftUI Menu as an AppKit
        //    MenuButton; matching on typed accessor `menuButtons[id]`
        //    avoids the very slow `descendants(matching: .any)` traversal
        //    against the 12k-row table.
        let correlateMenu = app.menuButtons["catalog.correlate.menu"]
        XCTAssertTrue(
            correlateMenu.waitForExistence(timeout: 120),
            "Correlate menu never appeared. Records may not have loaded — check the videoscan.log for catalog load errors."
        )
        correlateMenu.click()

        // 3. SwiftUI Menu items render as NSMenuItems. The subscript
        //    `[string]` matches against `identifier` (accessibilityIdentifier),
        //    NOT against `title` — and `accessibilityIdentifier()` set on a
        //    Button INSIDE a Menu does not propagate to the rendered
        //    NSMenuItem (Xcode 26.3 / macOS 26.5). So we match by title via
        //    NSPredicate.
        let findPairsPredicate = NSPredicate(format: "title == %@",
                                             "Find A/V Pairs Across Volumes")
        let findPairsItem = app.menuItems.matching(findPairsPredicate).firstMatch
        if !findPairsItem.waitForExistence(timeout: 10) {
            print("[UI-TEST] Could not find Find A/V Pairs Across Volumes menu item.")
            print("[UI-TEST] AX dump:")
            print(app.debugDescription)
            XCTFail("'Find A/V Pairs Across Volumes' menu item never appeared.")
            return
        }
        findPairsItem.click()

        // 4. Wait for correlation to finish — the Correlate menu button
        //    re-enables once `isCorrelating` flips back to false. Using
        //    `.isHittable` is the cheapest signal; ~one minute is normal
        //    for cross-volume correlation against the live catalog.
        let correlationDeadline = Date().addingTimeInterval(240)
        while Date() < correlationDeadline {
            if correlateMenu.isHittable { break }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(
            correlateMenu.isHittable,
            "Correlation never finished within 240s — `isCorrelating` may be stuck."
        )

        // 5. Find a paired MXF row in the table and right-click it. We DON'T
        //    pre-filter via the search field — empirically, XCUITest typeText
        //    into the SwiftUI TextField doesn't reliably register on macOS
        //    26.5 even after click-to-focus. Instead, scan the visible cells
        //    of the catalog table directly. With 177 correlated MXF pairs
        //    and SwiftUI Table's virtualization (~25 rows in AX at a time),
        //    we may need to scroll, but the iteration in
        //    findAndRightClickPairedRow handles up to 30 candidates.
        //
        // 6. The right-click context menu's "Combine This Pair…" item is
        //    only rendered when `rec.pairedWith != nil`. Match by title via
        //    NSPredicate (subscript[id] matches against identifier, which
        //    doesn't propagate from SwiftUI Menu Buttons to NSMenuItems).
        //    "Combine This Pair…" uses real U+2026 horizontal ellipsis.
        let combinePredicate = NSPredicate(format: "title == %@",
                                           "Combine This Pair\u{2026}")
        let combineMenuItem = app.menuItems.matching(combinePredicate).firstMatch
        let pickedRow = try findAndRightClickPairedRow(
            in: app,
            combineMenuItem: combineMenuItem
        )
        print("[UI-TEST] Picked paired row: \(pickedRow)")

        combineMenuItem.click()

        // 7. CombinePairSheet appears. Tap the final Combine button.
        let sheetTitle = app.staticTexts["combinePairSheet.title"]
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 15),
            "Combine Pair sheet never appeared after tapping 'Combine This Pair…'."
        )

        let combineButton = app.buttons["combinePairSheet.combineButton"]
        XCTAssertTrue(
            combineButton.waitForExistence(timeout: 10),
            "Combine button not found in CombinePairSheet."
        )
        // The Combine button gate: outputFolder != nil && videoOnline && audioOnline.
        // outputFolder is pre-set via launchArguments. If disabled here, either
        // the launch arg didn't take effect or one of the media files isn't
        // really reachable.
        XCTAssertTrue(
            combineButton.isEnabled,
            "Combine button disabled — outputFolder launch-arg may not have taken effect, or media is offline."
        )
        combineButton.click()

        // 8. Wait for ffmpeg to produce a file in the output dir. Up to 5min;
        //    stream-copy of one Avid MXF pair on local SSD typically < 30s.
        let outputFile = try waitForOutputFile(in: outputDir, timeout: 300)
        let attrs = try FileManager.default.attributesOfItem(atPath: outputFile.path)
        let size = (attrs[.size] as? Int64) ?? 0

        print("[UI-TEST] Output file: \(outputFile.path)")
        print("[UI-TEST] Output size: \(size) bytes")

        XCTAssertGreaterThan(
            size, 100_000,
            "Combine produced \(outputFile.lastPathComponent) but it's only \(size) bytes — expected > 100 KB."
        )
    }

    // MARK: - Helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()

        // Inject the output dir into UserDefaults so the file picker never
        // opens. CombineSheet/CombinePairSheet read the key on appear.
        // NSUserDefaults parses `-key value` argv pairs as transient defaults.
        app.launchArguments = [
            "-combineOutputFolder", outputDir.path,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment = ["VS_UI_TEST": "1"]

        app.launch()
        return app
    }

    /// Walk visible table cells (any cell whose label contains the literal
    /// string ".mxf"), right-click each in turn until "Combine This Pair…"
    /// appears in the resulting context menu. SwiftUI Table cells expose
    /// the column text via their `label` attribute — so a filename cell
    /// for `00000.V14D1BDB6A.mxf` has `label == "00000.V14D1BDB6A.mxf"`.
    /// Returns the matched cell label. Throws if no paired row surfaces.
    private func findAndRightClickPairedRow(
        in app: XCUIApplication,
        combineMenuItem: XCUIElement
    ) throws -> String {
        // Try both `cells` and `staticTexts` — different SwiftUI Table
        // implementations expose the filename either way depending on
        // version. We collate matches from both, dedupe by frame, and
        // attempt right-click on each.
        let predicate = NSPredicate(format: "label CONTAINS '.mxf'")
        let cellMatches = app.tables.cells.matching(predicate)
        let textMatches = app.tables.staticTexts.matching(predicate)
        let cellCount = cellMatches.count
        let textCount = textMatches.count
        print("[UI-TEST] cells matching .mxf: \(cellCount), staticTexts: \(textCount)")

        // Build candidate list — prefer cells (full row, right-click works
        // more cleanly) but fall back to static texts if no cells.
        var candidates: [XCUIElement] = []
        let cellTake = min(cellCount, 30)
        for i in 0..<cellTake {
            candidates.append(cellMatches.element(boundBy: i))
        }
        if candidates.isEmpty {
            let textTake = min(textCount, 30)
            for i in 0..<textTake {
                candidates.append(textMatches.element(boundBy: i))
            }
        }

        guard !candidates.isEmpty else {
            XCTFail("No table elements matching '.mxf' found. cells=\(cellCount), staticTexts=\(textCount). Catalog may not have loaded or table virtualization is hiding all MXFs.")
            throw NSError(domain: "CombineWorkflowUITests", code: 2)
        }

        for (i, cell) in candidates.enumerated() {
            guard cell.exists else { continue }
            let label = cell.label
            print("[UI-TEST]   candidate \(i): \(label)")
            cell.rightClick()
            if combineMenuItem.waitForExistence(timeout: 3) {
                return label
            }
            // Not paired — dismiss menu, try next.
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("Right-clicked \(candidates.count) MXF candidates but none showed 'Combine This Pair…' — correlation may not have populated pairedWith for visible rows.")
        throw NSError(domain: "CombineWorkflowUITests", code: 3)
    }

    /// Poll the output directory for a stable-size file from ffmpeg. We
    /// don't know the filename in advance (it's `<videoStem>_combined.mov`,
    /// derived inside CombinePairSheet), so we take the first file that
    /// grows past 50 KB and holds steady for 2 seconds.
    private func waitForOutputFile(in dir: URL, timeout: TimeInterval) throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 50_000 {
                    Thread.sleep(forTimeInterval: 2.0)
                    let size2 = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size2 == size && size2 > 100_000 {
                        return url
                    }
                }
            }
            Thread.sleep(forTimeInterval: 2.0)
        }
        XCTFail("No combined output file (≥ 100 KB, stable) appeared in \(dir.path) within \(Int(timeout))s.")
        throw NSError(domain: "CombineWorkflowUITests", code: 4)
    }
}
